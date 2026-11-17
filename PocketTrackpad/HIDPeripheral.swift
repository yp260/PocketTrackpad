import Foundation
import CoreBluetooth
import UIKit

/// 把 iPhone 变成一个 HID over GATT 的蓝牙鼠标（外设角色）。
///
/// 数据流：
///   触摸手势 -> 累积 dx/dy/wheel -> CADisplayLink 60Hz 合帧 -> BLE Notify (Report 0x2A4D)
///   -> iPadOS 蓝牙 HID 主机栈 -> 系统级指针 / 点击 / 滚动
final class HIDPeripheral: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    // MARK: - 界面状态
    @Published private(set) var statusText = "尚未启动"
    @Published private(set) var isAdvertising = false
    @Published private(set) var subscribers = 0
    @Published private(set) var logLines: [String] = []
    /// 全键盘界面是否真正能把按键送到主机：必须同时满足
    /// 键鼠复合模式开启、主机处于 Report Protocol、且已订阅 2A4D 输入报告。
    @Published private(set) var keyboardReady = false

    /// 桥接端是否已真正连上：以收到 welcome 回包为准。
    @Published private(set) var bridgeActive = false

    /// 连接诊断：把「连上却动不了」的关键状态直接暴露到界面，便于定位卡点。
    var diagnosticText: String {
        if bridgeMode {
            return "桥接模式 · 链路\(bridgeActive ? "已建立" : "未建立") · 目标 \(bridge.currentHost):\(bridge.currentPort)"
        }
        let proto = protocolMode == 0 ? "Boot" : "Report"
        let report = protocolMode == 0 && bootSubscribed ? "Boot 鼠标 3 字节"
                     : (compositeDevice ? "复合 12 字节" : "纯鼠标 4 字节")
        return "协议 \(proto) · 鼠标订阅\(inputSubscribed ? "✓" : "✗") · Boot订阅\(bootSubscribed ? "✓" : "✗") · 发送\(readyToUpdate ? "就绪" : "阻塞") · 已发\(sentFrames)帧 · 报告 \(report)"
    }

    /// 连接是否存在明显问题，供界面用红色/橙色高亮诊断条。
    var hasConnectionProblem: Bool {
        if bridgeMode { return !bridgeActive }
        return !inputSubscribed || !readyToUpdate
    }

    /// 等待配对时的状态文字。
    var pairingStatusText: String { "等待 iPad 配对" }

    /// 真正能收发数据才算「链路已建立」，界面据此切换全屏触控区。
    /// 不能用 subscribers>0：iPad 配对时会订阅 Report Map / HID Info 等只读特征，
    /// subscribers 会 >0，但这些数据特征并不能发送输入报告，导致「假连接」——
    /// 界面显示已连接，实际 inputSubscribed 为 false，一份报告都发不出去。
    /// 只有订阅了真正能发数据的报告特征才算连上。
    var isLinkActive: Bool {
        bridgeActive || inputSubscribed || bootSubscribed
    }

    /// 当前链路对端的可读名称，显示在界面「已连接」之后，让用户一眼看出连的是谁。
    ///
    /// 说明（系统限制）：iPhone 在本方案里是 BLE 外设，iPad / Windows 是主机。
    /// CoreBluetooth 在外设角色下只把对端的 `CBCentral.identifier`（UUID）交给 App，
    /// **不提供蓝牙设备名**（如「张三的 iPad」）。任何第三方 App 都无法读到该名字，
    /// 因此这里按连接来源给出可辨识的标识：
    ///   - 桥接模式：显示用户填写的真实目标地址（IP:端口），能精确定位到某一台电脑；
    ///   - 其余 BLE 连接：显示「iPad」。
    var connectedDeviceName: String {
        if bridgeMode {
            return "\(bridge.currentHost):\(bridge.currentPort)"
        }
        return "iPad"
    }

    /// 桥接传输层：把 12 字节复合 HID 报告通过 UDP 发给桥接端。
    /// 仅在「桥接模式」下参与输入上报；关闭时完全不触碰网络。
    lazy var bridge: BridgeTransport = {
        let b = BridgeTransport()
        b.onConnectionChange = { [weak self, weak b] in
            guard let self = self, let b = b else { return }
            self.bridgeActive = b.isConnected
            self.objectWillChange.send()
            self.refreshKeyboardReady()
        }
        return b
    }()

    /// iPad 蓝牙列表显示的是 iPhone 整机 GAP Device Name（0x1800 / 0x2A00），
    /// 不是广播包里的 CBAdvertisementDataLocalNameKey。iOS 不向 App 开放
    /// Device Name 特征，CoreBluetooth 也隐藏 Generic Access 服务，App 无法
    /// 改写这个名字。因此界面不再回显整机名，只在设置页给出改名步骤。

    // 设置页的三项参数做本地持久化，重开 App 不需重调。
    // v2 key：默认速度从 1.4× 调到 1.8×。老用户 UserDefaults 里存着旧 key 的 1.4，
    // 若继续读旧 key 则默认值改动对他们无效；换新 key 让所有人拿到新默认值。
    private static let sensKey = "PocketTrackpad.sensitivity.v2"
    private static let scrollKey = "PocketTrackpad.scrollSensitivity"
    // 方向默认值已反转（上滑 = 滚轮下滑）。换新 key，避免侧载覆盖安装后
    // 残留的旧 UserDefaults 值把方向带回旧行为。
    private static let naturalKey = "PocketTrackpad.naturalScrolling.v2"

    private static func savedDouble(_ key: String, fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }

    @Published var sensitivity: Double =
        HIDPeripheral.savedDouble(HIDPeripheral.sensKey, fallback: 1.8) {
            didSet { UserDefaults.standard.set(sensitivity, forKey: HIDPeripheral.sensKey) }
        }

    @Published var scrollSensitivity: Double =
        HIDPeripheral.savedDouble(HIDPeripheral.scrollKey, fallback: 1.0) {
            didSet { UserDefaults.standard.set(scrollSensitivity, forKey: HIDPeripheral.scrollKey) }
        }

    // 默认关：双指 / 滚轮键向上滑发出负 wheel（滚轮下滑），向下滑发出正 wheel。
    // 打开后整体取反，回到跟手方向。
    @Published var naturalScrolling: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.naturalKey) as? Bool) ?? false {
            didSet { UserDefaults.standard.set(naturalScrolling, forKey: HIDPeripheral.naturalKey) }
        }

    // MARK: - 键鼠复合模式（选项 B，实验性）
    //
    // 打开后 Report Map 里多一个 Keyboard Collection，三指上滑可发 Command+M（最小化 / 回桌面）。
    // 主机在配对时会缓存 Report Map，无法热更新：切换开关必须移除整个 GATT
    // 数据库、重新广播，并由用户在主机侧「忽略此设备」重新配对。
    // v2 key：默认开启键鼠复合模式。旧 key 里老用户被迁移逻辑写成了 false，
    // 继续读旧 key 会让「默认开启」对他们无效；换新 key 让所有人从 true 起步。
    private static let compositeKey = "PocketTrackpad.compositeDevice.v2"

    @Published var compositeDevice: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.compositeKey) as? Bool) ?? true {
            didSet {
                UserDefaults.standard.set(compositeDevice, forKey: HIDPeripheral.compositeKey)
                applyCompositeModeChange()
            }
        }

    // MARK: - 桥接模式（ESP32 硬件桥）
    //
    // 开启后，本 App 不再作为 BLE HID 外设广播，而是把采集到的输入通过 WiFi UDP
    // 发给 ESP32 硬件桥。原因：iOS 的 CoreBluetooth 外设无法设置 GAP Appearance，
    // 导致 Windows 搜不到 / 配对失败。ESP32 收到报告后以标准 BLE HID 键鼠身份
    // 连接电脑 / 平板，主机端无需安装任何软件，只需系统蓝牙配对 PT-Pad。
    private static let bridgeKey = "PocketTrackpad.bridgeMode.v1"

    @Published var bridgeMode: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.bridgeKey) as? Bool) ?? false {
            didSet {
                UserDefaults.standard.set(bridgeMode, forKey: HIDPeripheral.bridgeKey)
                if bridgeMode {
                    // 启用桥模式时先关掉本地 BLE 广播，避免两个发射源冲突、互相抢连接。
                    disconnect()
                    note("已启用桥接模式：iPhone 只采集输入，经 WiFi 发给 ESP32 硬件桥")
                    note("手机先连 ESP32 的 PT-Bridge 热点，地址保持默认 192.168.4.1")
                    note("再到电脑系统蓝牙配对 PT-Pad，电脑端无需安装任何软件")
                } else {
                    note("已关闭桥接模式：恢复本机直接广播（iPad 直连）")
                }
                refreshKeyboardReady()
            }
        }

    /// 键盘是否可用由状态共同决定，任何一处变化都刷新一次，供界面显示。
    private func refreshKeyboardReady() {
        if bridgeMode {
            // 桥模式下没有 protocolMode / inputSubscribed 概念，桥连上即代表键盘可用。
            keyboardReady = bridgeActive
        } else {
            keyboardReady = compositeDevice && protocolMode != 0 && inputSubscribed
        }
    }

    private func applyCompositeModeChange() {
        disconnect()
        if compositeDevice {
            statusText = "已启用键鼠复合，请重新广播并配对"
            note("已开启键鼠复合模式：输入报告 12 字节 = 键盘 8 + 鼠标 4（键盘字段在前）")
            note("本版描述符键盘 Collection 排最前，iPad 更可能按实体键盘对待（隐藏软键盘）")
            note("三指上滑会发送 Command+M（最小化 / 回桌面）；iPad 可能把本设备识别为键盘而弹出配对验证")
            note("若鼠标失效：关掉本开关 → 按「\(HIDSpec.ipadIgnorePath)」忽略 → 重新广播配对，即回到纯鼠标")
        } else {
            statusText = "已回退纯鼠标，请重新广播并配对"
            note("已回退为纯鼠标模式：输入报告恢复 4 字节，与 v0.0.7 完全一致")
            note("需按「\(HIDSpec.ipadIgnorePath)」忽略后重新配对，缓存的旧 Report Map 才会刷新")
        }
    }

    private static let stageKey = "PocketTrackpad.lastStage"
    /// 上次运行最后到达的阶段。App 若被异常杀掉，下次启动可直接看到卡在哪一步。
    @Published private(set) var lastStage: String? =
        UserDefaults.standard.string(forKey: HIDPeripheral.stageKey)

    // MARK: - CoreBluetooth
    private var manager: CBPeripheralManager?
    private var inputReport: CBMutableCharacteristic?      // 复合 / 纯鼠标：输入报告
    private var bootReport: CBMutableCharacteristic?
    private var servicesToAdd: [CBMutableService] = []
    private var databaseBuilt = false
    private var serviceFailed = false
    /// 某些 iOS 版本可能拒绝在广播中放 16 位 SIG UUID，此时自动回退到 128 位。
    private var advertisingFallbackUsed = false

    // MARK: - 报告状态
    private var buttonBits: UInt8 = 0
    private var protocolMode: UInt8 = 1     // 1 = Report Protocol, 0 = Boot Protocol
    private var inputSubscribed = false
    private var bootSubscribed = false
    private var pendingX = 0
    private var pendingY = 0
    private var pendingWheel = 0
    /// 键盘状态由 tick() 统一合进 60Hz 报告流：按下期间持续带键码，到期自动释放。
    /// 这样按下与释放走同一条链路，不会被 queuedPacket 覆盖导致按键卡住。
    /// modifier 不再写死 Command，全键盘可发任意 Ctrl / Shift / Option / Command 组合。
    private var pendingModifier: UInt8 = 0
    private var pendingKeycode: UInt8 = 0
    private var keyReleaseAt: Date?
    /// key-up 帧连发几帧，避免 BLE 拥塞时 queuedPacket 只剩按下帧导致按键卡住。
    private var emptyKeyFramesLeft = 0
    private var readyToUpdate = true
    private var queuedPacket: (Data, CBMutableCharacteristic)?
    /// readyToUpdate 卡在 false 的起始时间。超过阈值仍不恢复就强制复位（看门狗）。
    private var readyBlockedSince: Date?
    private var link: CADisplayLink?

    /// 发送帧计数：诊断「App 到底有没有把报告发出去」。
    /// 滑动触控区时若此数持续增长，说明 App 侧发送正常、问题在 iPadOS 解析；
    /// 若不增长，说明手势没进到发送链路，问题在 App 侧。
    @Published private(set) var sentFrames = 0
    /// 一次性迁移标记：彻底清除「避开上次设备」这个有害机制（iOS 无法拒绝指定
    /// central，「连上就拆」只会把用户想连回的 iPad 拒之门外，导致订阅永远为 0）。
    private static let avoidanceClearedKey = "PocketTrackpad.avoidanceCleared.v1"

    // MARK: - 宏录制 / 回放状态

    /// 是否正在录制。录制期间所有输入事件连同时间戳写入 recordingEvents。
    @Published private(set) var isRecording = false
    /// 是否正在回放。回放期间输入走的是注入路径，不再二次录制。
    @Published private(set) var isPlaying = false
    /// 当前回放的宏名（界面显示）。
    @Published private(set) var playingMacroName = ""
    /// 剩余播放次数（无限循环为 -1），给界面显示进度。
    @Published private(set) var playbackRemaining = 0

    private var recordingEvents: [MacroEvent] = []
    private var recordingStart: Date?
    private var playbackMacro: Macro?
    private var playbackEvents: [MacroEvent] = []
    private var playbackMode: PlayMode = .once
    private var playbackIndex = 0
    private var playbackLoopsDone = 0
    private var playbackLoopStart: Date?
    /// 回放注入时置 true，让 recordEvent 跳过，避免回放事件被再次录进去。
    private var isReplaying = false

    // 「统一起点」归位：录制开始前、回放每一轮开始前，先把光标推到屏幕左下角。
    // HID 是相对位移，App 读不到主机光标绝对坐标；但连续发最大负位移会让光标
    // 一路饱和到物理原点，与起始位置、屏幕分辨率、指针加速都无关，是最可靠的锚点。
    /// 归位剩余帧数（每帧 X=-127 向左、Y=+127 向下，饱和到左下角）。>0 时 tick() 强制发归位位移，不走 enqueue 故不会进录制。
    private var homingFramesLeft = 0
    /// 归位到位后的静默帧数：连续发空位移帧，让主机侧「指针加速」从归位时的
    /// 高速状态衰减到静止。录制与回放都经过这段静默，两者的加速起点才一致——
    /// 否则录制时人手有反应停顿（已衰减）、回放归位完立刻注入（仍高速），
    /// 同一串位移在两种加速状态下屏幕落点不同，表现为开头段落偏移。
    private var settleFramesLeft = 0
    /// 归位完成后要执行的闭包（真正开始录制 / 开始一轮回放）。
    private var afterHoming: (() -> Void)?
    /// 归位中标志，给 UI 显示状态用。
    @Published private(set) var isHoming = false

    // 「选择新设备」模式：iOS 外设无法清除主机侧配对、也无 API 拒绝某个 central，
    // 已配对主机（如 iPad）会自动抢连。开启本模式后，App 记住「上次连接的设备」，
    // 一旦它在广播后又自动连上，立刻拆链重播，给新设备留出连接窗口。
    // 注意：这是尽力而为，无法 100% 阻止系统栈的自动回连；根治须在旧设备忽略本设备。
    private static let lastCentralKey = "PocketTrackpad.lastCentral.v1"
    private static let selectNewModeKey = "PocketTrackpad.selectNewDeviceMode.v1"

    /// 是否开启「选择新设备」模式（设置页开关，持久化）。
    @Published var selectNewDeviceMode: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.selectNewModeKey) as? Bool) ?? false {
        didSet { UserDefaults.standard.set(selectNewDeviceMode, forKey: Self.selectNewModeKey) }
    }

    /// 上一条连上来的 central identifier（UUID 字符串），持久化。
    /// 注意：iOS 只给外设这张「身份 UUID」，不是设备名。
    private var lastCentralID: String? = UserDefaults.standard.string(forKey: HIDPeripheral.lastCentralKey) {
        didSet {
            if let v = lastCentralID {
                UserDefaults.standard.set(v, forKey: Self.lastCentralKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastCentralKey)
            }
        }
    }
    // MARK: - 生命周期

    /// 升级后一次性迁移。
    /// 注意：早期版本曾在这里把复合模式强制切回纯鼠标（规避部分 iPadOS 把设备当键盘
    /// 接管、忽略鼠标位移的问题）。现按用户要求恢复「键鼠复合模式默认开启」，故移除该迁移。
    /// 复合模式已换 v2 key 默认 true，老用户升级后即为开启；如需纯鼠标可在设置里手动关。
    func applyStartupMigration() {
        // 历史版本曾有「避开上次设备 / 连上就拆」机制：iOS 无 API 拒绝指定 central，
        // 该机制只把设备永久拒之门外（订阅永远 0、连不上），v0.0.61 起彻底移除。
        // 一次性把残留的持久化开关关掉即可，不再有任何避开 / 拆链逻辑。
        let avoidanceCleared = UserDefaults.standard.bool(forKey: Self.avoidanceClearedKey)
        if !avoidanceCleared {
            UserDefaults.standard.set(true, forKey: Self.avoidanceClearedKey)
            selectNewDeviceMode = false
            note("连接修复：已移除「避开上次设备」——断开后重新广播，任何设备都能正常连接")
        }
    }

    func start() {
        mark("1 调用 start()")
        // 复位可能卡死的发送状态：BLE 拥塞时 readyToUpdate 会变 false，
        // 若 peripheralManagerIsReady 回调因系统原因没来，之后所有报告都会
        // 堆在 queuedPacket 发不出，表现就是「已连接但完全动不了」。
        readyToUpdate = true
        queuedPacket = nil
        if manager == nil {
            // 所有 delegate 回调都落在主线程，避免 UI 状态跨线程写入。
            manager = CBPeripheralManager(
                delegate: self,
                queue: .main,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
            )
            mark("2 已创建 CBPeripheralManager")
            note("已创建 CBPeripheralManager")
        }
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        guard let manager = manager else { return }
        switch manager.state {
        case .poweredOn:
            if databaseBuilt { advertise() } else { buildDatabaseIfNeeded() }
        case .unknown, .resetting:
            statusText = "等待蓝牙就绪"
        default:
            break
        }
    }

    /// 桥接模式下的「开始」：不创建 BLE 外设，只连接 UDP 并把采集到的输入发给桥接端。
    func startBridge() {
        mark("1 调用 startBridge()")
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        statusText = "正在连接 ESP32 硬件桥"
        note("桥接模式：iPhone 采集输入 → WiFi UDP → ESP32 → 电脑 / 平板蓝牙键鼠")
        note("当前桥接端地址：\(bridge.currentHost):\(bridge.currentPort)")
        note("手机需先连 ESP32 的 PT-Bridge 热点，再到电脑系统蓝牙配对 PT-Pad")
        bridge.connect()
    }

    /// 设置 ESP32 硬件桥的地址（默认 192.168.4.1:5000）。
    func setBridgeTarget(host: String, port: String) {
        let p = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 5000
        bridge.updateTarget(host: host, port: p)
        note("桥接端地址设为 \(bridge.currentHost):\(bridge.currentPort)")
    }

    /// 重新发送握手包：ESP32 若在 App 之后才上电，用它立刻建立链路。
    func resendBridgeHello() {
        bridge.resendHello()
        note("已重新发送握手包；若 ESP32 已连上同一热点，应立刻显示「已连接」")
    }

    /// 一键切到「纯鼠标 4 字节」模式：历史上 iPad 上最稳定、验证过能用的配置。
    /// 复合 12 字节（键盘在前）在部分 iPadOS 版本上会被当键盘接管、忽略鼠标位移，
    /// 表现为「显示已连接、订阅正常，但 iPad 完全无反应」。此入口关复合 + 拆链 +
    /// 按纯鼠标拓扑重建 GATT + 自动重播。注意主机缓存了旧 Report Map，需在 iPad
    /// 「辅助触控 → 设备」里忽略后重新配对才会真正刷新（不在蓝牙列表里）。
    func switchToPlainMouse() {
        if compositeDevice { compositeDevice = false }   // didSet 内已 disconnect()
        disconnect()
        start()
        note("已切到纯鼠标模式（4 字节，与 v0.0.7 一致）：GATT 已重建并重播")
        note("重要：请按「\(HIDSpec.ipadIgnorePath)」忽略后重新配对，旧 Report Map 缓存才会刷新")
        statusText = "纯鼠标模式 · 请忽略设备重配"
    }

    /// 主动断开当前主机，让 Windows / Mac 等其他主机可以重新发现本设备。
    ///
    /// CBPeripheralManager 没有公开的 disconnect(central:) 接口：stopAdvertising()
    /// 只是不再被新主机发现，已经建立的 BLE 连接仍然存在。这里先移除全部已发布
    /// 服务，再释放 manager 实例，由系统拆掉当前链路；下次调用 start() 会重新创建
    /// manager、重建 GATT 数据库并重新广播。
    func disconnect() {
        bridge.disconnect()
        note("主动断开：停止广播并移除 GATT 服务")
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil

        isAdvertising = false
        subscribers = 0
        inputSubscribed = false
        bootSubscribed = false
        inputReport = nil
        bootReport = nil
        servicesToAdd.removeAll()
        databaseBuilt = false
        serviceFailed = false
        advertisingFallbackUsed = false
        buttonBits = 0
        pendingX = 0
        pendingY = 0
        pendingWheel = 0
        pendingModifier = 0
        pendingKeycode = 0
        keyReleaseAt = nil
        emptyKeyFramesLeft = 0
        queuedPacket = nil
        readyToUpdate = true
        refreshKeyboardReady()
        statusText = "已断开连接"
        note("已断开；点「开始广播」重建服务后，iPad 等主机即可发现")
        note("若 iPad 仍在附近且保留配对，可能自动重连；必要时按「\(HIDSpec.ipadIgnorePath)」忽略")
        mark("7 运行中（已主动断开）")
    }

    /// 拆掉 GATT 数据库并释放 manager。iOS 没有公开的 disconnect(central:) 接口，
    /// 这是让当前主机真正掉线的唯一办法；随后 start() 会重建服务并重新广播。
    private func tearDownGATT() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil

        isAdvertising = false
        subscribers = 0
        inputSubscribed = false
        bootSubscribed = false
        inputReport = nil
        bootReport = nil
        servicesToAdd.removeAll()
        databaseBuilt = false
        serviceFailed = false
        advertisingFallbackUsed = false
        buttonBits = 0
        pendingX = 0
        pendingY = 0
        pendingWheel = 0
        pendingModifier = 0
        pendingKeycode = 0
        keyReleaseAt = nil
        emptyKeyFramesLeft = 0
        queuedPacket = nil
        readyToUpdate = true
        cancelHoming()
        refreshKeyboardReady()
    }

    /// 「断开连接」（主界面右上角按钮）：干净地断掉当前链路。
    ///
    /// 历史教训：v0.0.60 曾在这里拆链后立刻自动重播，并叠加「8 秒避开上次设备」窗口，
    /// 旧 iPad 一回连就拆 GATT 重播，导致界面闪一下又断开、谁都连不上。v0.0.61 起：
    /// - 按钮只做断开（tearDownGATT），**不自动重新广播**；
    /// - 断开后右上角恢复成「开始广播」，用户明确点它才调用 start() 重建并广播；
    /// - 不再有任何避开 / 拒绝逻辑，任何设备连上都正常接受。
    ///
    /// 桥接模式则断开 UDP，用户点「连接桥接」再重连。
    func selectNewDevice() {
        bridge.disconnect()
        if bridgeMode {
            statusText = "桥接已断开"
            note("已断开 ESP32 硬件桥；点右上角「连接桥接」可重连")
            mark("7 运行中（桥接已断开）")
            return
        }
        tearDownGATT()
        statusText = "已断开连接"
        note("已断开：GATT 服务已移除、广播已停止")
        note("点右上角「开始广播」即可重新广播，任何设备都能连接")
        note("换设备根治仍须在旧 iPad「\(HIDSpec.ipadIgnorePath)」忽略本设备")
        mark("7 运行中（已主动断开）")
    }

    // MARK: - GATT 数据库

    /// value 必须是 nil。
    ///
    /// CoreBluetooth 规定：初始化时带缓存值（cached value）的特征只能设为只读。
    /// 若同时声明 .notify / .write，manager.add(service) 会抛
    /// NSInternalInconsistencyException:
    ///   "Characteristics with cached values must be read-only"
    /// Swift 捕获不到 Objective-C 异常，表现就是 App 一打开立刻闪退。
    /// 因此所有特征值改由 peripheralManager(_:didReceiveRead:) 动态提供。
    private func makeChar(_ uuid: CBUUID,
                          properties: CBCharacteristicProperties,
                          permissions: CBAttributePermissions,
                          descriptors: [CBMutableDescriptor]? = nil) -> CBMutableCharacteristic {
        let c = CBMutableCharacteristic(type: uuid,
                                        properties: properties,
                                        value: nil,
                                        permissions: permissions)
        if let descriptors = descriptors { c.descriptors = descriptors }
        return c
    }

    private func makeServices() -> [CBMutableService] {
        let encRead: CBAttributePermissions = [.readable, .readEncryptionRequired]
        let encRW: CBAttributePermissions = [.readable, .writeable,
                                             .readEncryptionRequired, .writeEncryptionRequired]
        let plainRead: CBAttributePermissions = [.readable]

        // ---- HID Service 0x1812 ----
        let info = makeChar(HIDSpec.hidInformation, properties: [.read],
                            permissions: encRead)
        let control = makeChar(HIDSpec.hidControlPoint,
                               properties: [.write, .writeWithoutResponse],
                               permissions: [.writeable, .writeEncryptionRequired])
        let map = makeChar(HIDSpec.reportMap, properties: [.read],
                           permissions: encRead)
        let mode = makeChar(HIDSpec.protocolMode, properties: [.read, .write],
                            permissions: encRW)

        // Boot Mouse Input Report：iOS 在 Boot Protocol 下会走这个特征，必须提供。
        let boot = makeChar(HIDSpec.bootMouseInputReport, properties: [.read, .notify],
                            permissions: encRead)
        bootReport = boot

        // Boot Keyboard Input / Output Report：Apple DTS 论坛确认 iPadOS 只完整
        // 接管匹配「Keyboard」配置的设备；实体键盘都带这两个特征（v0.0.18 补齐）。
        // Report Protocol 下键盘输入仍走上面的 2A4D，这两个特征只用于让 iPadOS
        // 把本设备归类为键盘（隐藏软键盘、候选词带数字）。
        let bootKbdIn = makeChar(HIDSpec.bootKeyboardInput,
                                 properties: [.read, .notify],
                                 permissions: encRead)
        let bootKbdOut = makeChar(HIDSpec.bootKeyboardOutput,
                                  properties: [.read, .write],
                                  permissions: encRW)

        let hid = CBMutableService(type: HIDSpec.hidService, primary: true)
        // Descriptor 是静态元数据，允许带值；Characteristic 不允许。
        let reportRef = CBMutableDescriptor(type: HIDSpec.reportReference,
                                            value: HIDSpec.reportReferenceValue)
        let report = makeChar(HIDSpec.report, properties: [.read, .notify],
                              permissions: encRead, descriptors: [reportRef])
        inputReport = report

        if compositeDevice {
            hid.characteristics = [info, control, map, mode, report, boot, bootKbdIn, bootKbdOut]
        } else {
            // 纯鼠标：只挂鼠标特征、不挂 Boot Keyboard。配合 Appearance=Mouse，
            // 让 iPadOS 干净地把它当鼠标接管（早期 v0.0.7 验证可用的配置）。
            // 挂 Boot Keyboard + 声明 Keyboard 会让 iPadOS 按键盘接管并忽略鼠标位移。
            hid.characteristics = [info, control, map, mode, report, boot]
        }

        // ---- Device Information 0x180A ----
        let dis = CBMutableService(type: HIDSpec.deviceInformation, primary: true)
        dis.characteristics = [
            makeChar(HIDSpec.manufacturerName, properties: [.read], permissions: plainRead),
            makeChar(HIDSpec.modelNumber, properties: [.read], permissions: plainRead),
            makeChar(HIDSpec.firmwareRevision, properties: [.read], permissions: plainRead),
            makeChar(HIDSpec.pnpID, properties: [.read], permissions: plainRead)
        ]

        // ---- Battery Service 0x180F ----
        // 不少 HID 主机（含 iOS）会把电池服务作为「合规 HID 外设」的判定条件之一。
        let bas = CBMutableService(type: HIDSpec.batteryService, primary: true)
        bas.characteristics = [
            makeChar(HIDSpec.batteryLevel, properties: [.read, .notify],
                     permissions: plainRead)
        ]

        // ---- Generic Access 0x1800（v0.0.18：补 Appearance = Keyboard）----
        // iOS 不允许 App 在广播包里放 Appearance AD Type，但 0x1800 服务可用
        // 128 位形式注册。主机绑定阶段会读 2A01，读到 Keyboard (0x03C1) 后
        // 更可能把本设备当实体键盘对待。若当前 iOS 版本拒绝注册 0x1800，
        // 只在日志报错，不影响 HID 主链路（didAdd 对失败服务逐个放行）。
        let gap = CBMutableService(type: HIDSpec.genericAccess, primary: false)
        gap.characteristics = [
            makeChar(HIDSpec.appearance, properties: [.read], permissions: plainRead)
        ]

        return [hid, dis, bas, gap]
    }

    private func buildDatabaseIfNeeded() {
        guard !databaseBuilt, let manager = manager, manager.state == .poweredOn else { return }
        databaseBuilt = true
        serviceFailed = false
        mark("3 蓝牙 poweredOn，构建 GATT 数据库")
        servicesToAdd = makeServices()
        mark("4 已构造 4 个 CBMutableService（HID / Device Info / Battery / Generic Access）")
        note("开始注册 GATT 服务（HID / Device Info / Battery / Generic Access）")
        note(compositeDevice
             ? "当前模式：键鼠复合（输入报告 12 字节，三指上滑 = Command+M 最小化）"
             : "当前模式：纯鼠标（输入报告 4 字节，与 v0.0.7 相同）")
        addNextService()
    }

    /// 逐个 add，等 didAdd 回调后再 add 下一个，避免并发注册导致状态错乱。
    private func addNextService() {
        if servicesToAdd.isEmpty {
            if serviceFailed {
                note("有服务注册失败，仍继续广播；若 iPad 无法识别请查看本日志")
            }
            advertise()
            return
        }
        let s = servicesToAdd.removeFirst()
        mark("5 调用 add() 注册服务 \(HIDSpec.short(s.uuid))")
        manager?.add(s)
    }

    private func advertise() {
        guard let manager = manager, manager.state == .poweredOn else { return }
        // isAdvertising 只是 App 本地记录：iOS 在主机会话建立后由系统层面停止广播，
        // 却不回调 App，该标志会卡在 true。若据此 return，start() 后再也不会真正广播，
        // 表现就是 iPad 搜不到设备。这里不因它而 return，先停再播，保证主机一定能搜到。
        if isAdvertising {
            manager.stopAdvertising()
            isAdvertising = false
        }
        mark("6 全部服务注册完成，准备广播")
        // 广播包里必须放 16 位 SIG UUID，不能放 128 位完整形式。两个独立原因：
        //
        // 1) iPadOS / Windows 的「设置 > 蓝牙」发现列表按 16 位服务 UUID 过滤设备类别。
        //    128 位完整形式 00001812-... 会被当成「自定义未知服务」直接屏蔽，
        //    设备根本不会出现在列表里（Nordic 官方论坛实测：换成任意 128 位 UUID 即不可见）。
        // 2) 一个 128 位 UUID 在空中占 18 字节，加设备名很容易挤进 overflow 区域。
        //    Apple 文档明确：overflow 里的服务 UUID「只有显式扫描该服务的 iOS 设备」能发现，
        //    系统蓝牙设置和非 iOS 主机一律看不到。
        //
        // 注意区分：GATT 数据库里的服务仍必须用 128 位注册，
        // 因为 CBPeripheralManager.add() 禁止 16 位 SIG UUID（CBError Code 8）。
        // 广播数据与 GATT 数据库是两回事，这里只在广播里用短 UUID。
        startAdvertising(with: HIDSpec.advertisedServiceUUIDs, fallback: false)
        statusText = "正在广播"
    }

    private func startAdvertising(with uuids: [CBUUID], fallback: Bool) {
        advertisingFallbackUsed = fallback
        manager?.startAdvertising([
            CBAdvertisementDataLocalNameKey: "PT-Pad",
            CBAdvertisementDataServiceUUIDsKey: uuids
        ])
        note(fallback
             ? "广播回退模式：128 位完整 UUID（主机可能不显示）"
             : "广播 16 位 SIG UUID：1812 / 180F / 180A")
        note("广播 Local Name = PT-Pad；iPad 列表显示的是 iPhone 整机名（App 无法改写）")
        note("要显示 PT-Pad：改 iPhone 名称后按「\(HIDSpec.ipadIgnorePath)」忽略并重新配对")
    }

    /// 主机断开后只更新界面状态，绝不自动重新广播。
    ///
    /// v0.0.63 关键修复：旧版在这里做 stopAdvertising → 0.6s 后 startAdvertising 的
    /// 「自动恢复广播」，本意是 iPad 忽略设备后能重新搜到。但实测它正是「断联 / 重播
    /// 不断」的元凶：iPad 作为 HID 主机会频繁发生「连接 → 订阅 → 瞬断 → 重连」抖动，
    /// 每次 subscribers 归零都触发一轮 stop→start，界面在「已连接 / 等待配对」之间反复
    /// 闪跳；并且延时闭包会和手动点「开始广播」打架，造成「点了闪一下就无效」。
    ///
    /// 现在：断开就是断开，广播停就停着；要重新连接由用户显式点右上角「开始广播」。
    /// 这样状态完全由用户掌控，不再有自动重播循环。系统层面已配对的主机仍可能主动
    /// 回连（iOS 无法拒绝），那是系统行为；根治只能在主机侧忽略本设备。
    private func handleHostDisconnected() {
        guard !bridgeMode else { return }
        statusText = "已断开 · 点「开始广播」重连"
        note("主机已断开；广播不会被自动重启，需要重连请点右上角「开始广播」")
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            statusText = "蓝牙就绪"
            note("蓝牙 poweredOn")
            buildDatabaseIfNeeded()
        case .poweredOff:   statusText = "蓝牙已关闭"
        case .unauthorized: statusText = "未授权蓝牙权限"
        case .unsupported:  statusText = "本机不支持 BLE 外设模式"
        case .resetting:    statusText = "蓝牙重置中"
        case .unknown:      statusText = "蓝牙状态未知"
        @unknown default:   statusText = "未知蓝牙状态"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        let id = HIDSpec.short(service.uuid)
        if let error = error {
            serviceFailed = true
            note("服务 \(id) 注册失败: \(error.localizedDescription)")
            if id == "1812" {
                statusText = "HID 服务被系统拒绝"
                note("当前 iOS 版本可能已封堵 128 位 UUID 绕过，请改用「桥接（ESP32 硬件桥）」模式")
            }
        } else {
            note("服务 \(id) 注册成功")
        }
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                              error: Error?) {
        if let error = error {
            if !advertisingFallbackUsed {
                // 16 位 SIG UUID 被系统拒绝时，退回 128 位，至少保证广播不中断。
                note("16 位 UUID 广播被拒: \(error.localizedDescription)")
                note("自动回退到 128 位完整 UUID")
                startAdvertising(with: [HIDSpec.hidService], fallback: true)
                return
            }
            statusText = "广播失败"
            note("广播失败: \(error.localizedDescription)")
        } else {
            isAdvertising = true
            statusText = advertisingFallbackUsed ? "广播中（兼容模式）" : pairingStatusText
            mark("7 运行中（广播正常）")
            if advertisingFallbackUsed {
                note("当前 iOS 版本禁止广播 16 位 SIG UUID，主机大概率不会显示本设备")
                note("这是系统限制，请改用「桥接（ESP32 硬件桥）」模式")
            } else {
                note("请在 iPad：设置 > 蓝牙 > 其他设备 > 选择 PT-Pad")
                note("若仍不显示，请用 nRF Connect 扫描 PT-Pad 确认广播内容")
            }
        }
    }

    /// 必须正确处理 offset：Report Map 有 50 字节，超过默认 ATT_MTU，
    /// 主机会分多次带 offset 读取。若忽略 offset，iPad 会拿到错乱的描述符并拒绝接管。
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        let full = readValue(for: request.characteristic.uuid)
        guard let full = full else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let offset = max(0, request.offset)
        if offset >= full.count {
            request.value = Data()
        } else {
            request.value = full.subdata(in: offset..<full.count)
        }
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let id = HIDSpec.short(r.characteristic.uuid)
            switch id {
            case "2A4E":   // Protocol Mode
                if let v = r.value?.first {
                    protocolMode = (v == 0x00) ? 0 : 1
                    note("主机切换协议模式: \(protocolMode == 0 ? "Boot" : "Report")")
                    if protocolMode == 0 {
                        note("Boot Protocol 下报告固定 3 字节，滚轮、全键盘与三指上滑均不可用")
                    }
                    refreshKeyboardReady()
                }
            case "2A4C":   // HID Control Point (Suspend / Exit Suspend)
                note("主机写入 HID Control Point")
            default:
                break
            }
        }
        // 只有要求响应的 write 才能 respond，writeWithoutResponse 不能回。
        if let first = requests.first,
           first.characteristic.properties.contains(.write) {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        let id = HIDSpec.short(characteristic.uuid)
        let thisID = central.identifier.uuidString

        // v0.0.61：彻底移除「避开上次设备」机制。iOS 无 API 拒绝指定 central，
        // 旧版靠订阅时拆链重播来避让，结果每次回连都触发 GATT 重建，界面闪一下
        // 又断开，反而谁都连不上。现在任何设备订阅都正常接受、正常提供服务。
        if characteristic === inputReport { inputSubscribed = true }
        if characteristic === bootReport { bootSubscribed = true }
        subscribers += 1
        refreshKeyboardReady()

        // 记住这次连上来的主机身份（仅用于展示设备名，绝不用于拒绝连接）。
        lastCentralID = thisID

        statusText = "已连接 · 可以移动指针"
        note("主机订阅 \(id)（配对完成）")
        if keyboardReady {
            note("全键盘可用：点触控区顶部「⌨ 全键盘」切换")
        } else {
            note("全键盘暂不可用：需键鼠复合模式 + Report Protocol + 2A4D 订阅")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = HIDSpec.short(characteristic.uuid)
        if characteristic === inputReport { inputSubscribed = false }
        if characteristic === bootReport { bootSubscribed = false }
        subscribers = max(0, subscribers - 1)
        refreshKeyboardReady()
        statusText = isAdvertising ? pairingStatusText : "广播已停止"
        note("主机取消订阅 \(id)")
        // v0.0.63：只更新状态，绝不自动重播（自动 stop→start 正是断联重播不断的元凶）。
        if subscribers == 0 { handleHostDisconnected() }
    }

    /// 中央设备彻底断开连接（iOS 13+）。覆盖「连上但没订阅就断开」的情况，
    /// 同样要在无订阅时恢复广播，避免 iPad 忽略设备后永久搜不到。
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didDisconnect central: CBCentral) {
        note("主机已断开连接")
        // 有时 didUnsubscribeFrom 不会在断连前到达，subscribers 会残留非 0，
        // 令恢复逻辑永不触发。彻底断连即代表没有任何订阅，直接清零。
        inputSubscribed = false
        bootSubscribed = false
        subscribers = 0
        refreshKeyboardReady()
        handleHostDisconnected()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        readyToUpdate = true
        if let q = queuedPacket {
            queuedPacket = nil
            send(q.0, on: q.1)
        }
    }

    // MARK: - 读取请求的数据

    private func readValue(for uuid: CBUUID) -> Data? {
        switch HIDSpec.short(uuid) {
        case "2A4A": return HIDSpec.hidInformationValue
        case "2A4B": return HIDSpec.reportMap(composite: compositeDevice)
        case "2A4E": return Data([protocolMode])
        case "2A4D": return HIDSpec.emptyReport(composite: compositeDevice)
        case "2A33": return Data([0x00, 0x00, 0x00])
        case "2A29": return Data("PocketTrackpad".utf8)
        case "2A24": return Data("PT-01".utf8)
        case "2A26": return Data("1.0.0".utf8)
        case "2A50": return HIDSpec.pnpIDValue
        case "2A19": return Data([100])
        case "2A01":
            // 纯鼠标声明 Mouse，复合模式声明 Keyboard（needs 全键盘/选词）。
            // 纯鼠标若声明 Keyboard，iPadOS 会按键盘接管并忽略鼠标位移 → 指针不动。
            return compositeDevice ? HIDSpec.appearanceValue : HIDSpec.appearanceMouse
        case "2A22": return Data(repeating: 0, count: 8)  // Boot Keyboard Input
        case "2A23": return Data([0])                     // Boot Keyboard Output (LED)
        default:     return nil
        }
    }

    // MARK: - 输入上报

    /// 手势层调用：累积位移，等待下一次屏幕刷新统一发出。
    func enqueue(dx: Int = 0, dy: Int = 0, wheel: Int = 0) {
        pendingX += dx
        pendingY += dy
        pendingWheel += wheel
        // 录制位移不在 enqueue 记，改到 flush() 里记「本帧真正发出的位移」。
        // 原因：iPadOS / Windows 对 HID 相对位移有非线性指针加速——同样总位移，
        // 拆成 N 个小帧发出与合成 1 个大帧发出，屏幕实际移动距离不同。宏必须逐帧
        // 复现录制时发给主机的帧序列，才能让点击落点一致。手势层的 enqueue 增量
        // 会被合并/分帧，不能直接当宏事件记录。
    }

    @objc private func tick() {
        // 归位阶段：每帧强制发左下角方向的饱和位移，直接写 pending（不经 enqueue，
        // 因此不会被 recordEvent 录进宏），保证回放起点与录制起点是同一物理角落。
        var homingCompleted = false
        var didHome = false
        if homingFramesLeft > 0 {
            homingFramesLeft -= 1
            pendingX = -127   // 向左饱和
            pendingY = 127    // 向下饱和，两轴合力把光标锁定到左下角物理原点（避开角落锁屏热区）
            didHome = true
        }

        // 静默阶段：归位到位后连发空位移帧，让主机侧指针加速衰减到静止。
        // 录制时人手有自然停顿、回放时归位完立刻注入——不强制对齐这段，两者
        // 的加速起点就不同，开头位移会被放大导致落点偏移。空帧直接写 pending
        // 为 0（不经 enqueue），不进录制；force 让空报告也真正发出去。
        // !didHome 保证归位最后一帧不被同帧的静默覆盖位移。
        var settling = false
        if !didHome, homingFramesLeft == 0, settleFramesLeft > 0 {
            settleFramesLeft -= 1
            pendingX = 0
            pendingY = 0
            settling = true
            if settleFramesLeft == 0 { homingCompleted = true }
        }

        // 回放注入与发送共用同一个 CADisplayLink（本 tick）：注入一帧位移立刻
        // flush 一帧，逐帧复现录制时的帧序列。此前回放用独立 playbackLink，与
        // 本 tick 相位不定，同一位移每次被拆成的帧序列都不同，叠加 iPadOS 的
        // 非线性指针加速，表现就是「点击落点偏移且每次偏移量不一样」。
        pumpPlayback()

        var modifier: UInt8 = 0
        var keycodes: [UInt8] = []
        var keyReleased = false
        if pendingKeycode != 0 {
            if let t = keyReleaseAt, Date() < t {
                modifier = pendingModifier
                keycodes = [pendingKeycode]
            } else {
                pendingModifier = 0
                pendingKeycode = 0
                keyReleaseAt = nil
                emptyKeyFramesLeft = 3
                keyReleased = true
            }
        } else if emptyKeyFramesLeft > 0 {
            // 连续补发空键盘帧：BLE 拥塞时 queuedPacket 只保留最后一包，
            // 这样无论丢多少帧，主机最终收到的都是「已松开」。
            emptyKeyFramesLeft -= 1
            keyReleased = true
        }
        // settling 强制发空位移帧（x=y=0），让主机把指针加速状态归零；
        // 空帧不会进录制（flush 内 recordEvent 仅在位移非 0 时调用）。
        flush(force: settling, modifier: modifier, keycodes: keycodes,
              keyReleased: keyReleased)

        // 看门狗：若 readyToUpdate 卡在 false 超过 1 秒（订阅中、非桥接），
        // 说明系统的 peripheralManagerIsReady 回调迟迟不来，强制复位并补发队列，
        // 否则会出现「已连接但指针/键盘完全不动」。
        if !bridgeMode && subscribers > 0 {
            if !readyToUpdate {
                if readyBlockedSince == nil { readyBlockedSince = Date() }
                else if let since = readyBlockedSince,
                        Date().timeIntervalSince(since) > 1.0 {
                    note("发送通道阻塞超时，已强制复位（看门狗）")
                    readyToUpdate = true
                    readyBlockedSince = nil
                    if let q = queuedPacket {
                        queuedPacket = nil
                        send(q.0, on: q.1)
                    }
                }
            } else {
                readyBlockedSince = nil
            }
        } else {
            readyBlockedSince = nil
        }

        // 归位帧全部发出后再执行闭包（开始录制 / 开始一轮回放）。
        if homingCompleted {
            isHoming = false
            let done = afterHoming
            afterHoming = nil
            done?()
        }
    }

    /// 开始归位：连续若干帧把光标推向左下角物理原点，再静默若干帧让加速归零，
    /// 完成后执行 action。归位 90 帧 + 静默 30 帧（60Hz 约 2 秒）。
    /// 归位帧数足以让任意屏幕尺寸 + 指针加速下的光标饱和到角落；静默帧让录制
    /// 与回放从相同的「静止加速」状态起步，消除开头段落的落点偏移。
    private func beginHoming(then action: @escaping () -> Void) {
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        afterHoming = action
        homingFramesLeft = 90
        settleFramesLeft = 30
        isHoming = true
        note("正在归位光标到屏幕左下角（统一起点），约 2 秒…")
    }

    /// 取消归位：停止录制 / 停止回放时调用，避免残留闭包稍后误触发。
    private func cancelHoming() {
        homingFramesLeft = 0
        settleFramesLeft = 0
        afterHoming = nil
        isHoming = false
    }

    /// 三指上滑：发一次 Command + M，最小化当前程序 / 返回桌面（App 保留后台，不关闭）。
    /// 走与全键盘相同的 sendKey 链路，按下和释放由 tick() 统一管理。
    func goHome() {
        note("三指上滑 → 发送 Command + M（最小化当前程序 / 回桌面）")
        sendKey(HIDSpec.homeKeycode,
                modifiers: HIDSpec.commandModifier,
                label: "三指上滑 · Command + M",
                reason: "三指上滑未生效")
    }

    /// 三指左右滑：切换 App。iPadOS 外接键盘支持 Command + Tab（下一个）与
    /// Command + Shift + Tab（上一个）切换应用。iPadOS 原生多指手势只对 Magic
    /// Trackpad 2 私有协议开放，第三方 BLE 拿不到，因此 App 侧识别手势后转成
    /// 这两个快捷键发出（属于模拟手势），需保持「键鼠复合模式」开启。
    /// - Parameter forward: true=下一个(Cmd+Tab)，false=上一个(Cmd+Shift+Tab)
    func switchApp(forward: Bool) {
        let mods = HIDSpec.commandModifier | (forward ? 0 : HIDSpec.modLeftShift)
        note(forward ? "三指右滑 → Command + Tab（下一个 App）"
                     : "三指左滑 → Command + Shift + Tab（上一个 App）")
        sendKey(HIDSpec.tabKeycode,
                modifiers: mods,
                label: forward ? "三指切换 · Command + Tab" : "三指切换 · Command + Shift + Tab",
                reason: "切换 App 未生效（需开启键鼠复合模式）")
    }

    // MARK: - 全键盘输入

    /// 发送一次「按下 → 约 0.06 秒后自动松开」的按键，供虚拟键盘界面调用。
    ///
    /// - Parameters:
    ///   - keycode: USB HID Keyboard/Keypad Page 键码，必须在 0x00...0x65 内
    ///              （Report Map 声明的 Usage Maximum 是 101）。
    ///   - modifiers: 修饰键位图，可组合 Ctrl / Shift / Option / Command。
    ///   - label: 日志里显示的按键名。
    ///   - reason: 校验失败时日志前缀，用来区分三指上滑与全键盘两种来源。
    ///
    /// 连续按同一个键时，会先强制发一帧「全松开」报告；否则主机看不到
    /// key-up，会把第二次按下当成一直按住，表现为漏字。
    func sendKey(_ keycode: UInt8, modifiers: UInt8 = 0,
                 label: String = "按键", reason: String = "按键未发送") {
        guard compositeDevice || bridgeMode else {
            note("\(reason)：当前是纯鼠标模式，请到设置里开启「键鼠复合模式」或桥接模式")
            return
        }
        guard bridgeMode || protocolMode != 0 else {
            note("\(reason)：主机处于 Boot Protocol，键盘报告不可用")
            return
        }
        guard bridgeMode || inputSubscribed else {
            note("\(reason)：主机尚未订阅 2A4D 输入报告")
            return
        }
        guard keycode <= HIDSpec.maxKeyboardKeycode else {
            note("\(reason)：键码 0x\(String(keycode, radix: 16)) 超出描述符范围")
            return
        }

        if pendingKeycode != 0 {
            // 上一个键还没松开：先补一帧空键盘报告。
            flush(force: true, modifier: 0, keycodes: [], keyReleased: true)
        }
        pendingModifier = modifiers
        pendingKeycode = keycode
        // 按住时长 120ms：iPad 中文输入法在拼音组合态下对选词按键（数字 / 空格）
        // 的采样更挑剔，过短的按下时间可能让 IME 漏掉该次击键，导致选词无反应。
        // 120ms 比 90ms 更稳，又不至于触发系统按键重复（iOS 重复阈值约 500ms）。
        keyReleaseAt = Date().addingTimeInterval(0.12)
        emptyKeyFramesLeft = 0
        let modHex = String(modifiers, radix: 16, uppercase: true)
        let keyHex = String(keycode, radix: 16, uppercase: true)
        note("键盘 → \(label)（keycode 0x\(keyHex)，modifier 0x\(modHex)）")
        recordEvent(kind: .key, keycode: keycode, modifiers: modifiers, label: label)
    }

    /// 按住 / 松开某个按键。mask: 1=左键, 2=右键, 4=中键
    func setButton(_ mask: UInt8, pressed: Bool) {
        if pressed { buttonBits |= mask } else { buttonBits &= ~mask }
        flush(force: true)
        recordEvent(kind: pressed ? .buttonDown : .buttonUp, mask: mask)
    }

    /// 短按点击；count = 2 时为双击。
    func click(_ mask: UInt8, count: Int = 1) {
        buttonBits |= mask
        flush(force: true)
        // 连击的后续次由下方 asyncAfter 递归触发，递归里也会各记一次 click；
        // 因此这里只记第一下，递归调用 click(count-1) 时再各记一次，语义完整。
        recordEvent(kind: .click, mask: mask, count: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self = self else { return }
            self.buttonBits &= ~mask
            self.flush(force: true)
            if count > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.070) { [weak self] in
                    self?.click(mask, count: count - 1)
                }
            }
        }
    }

    // MARK: - 宏录制 / 回放引擎

    /// 记录一个输入事件。回放注入期间（isReplaying）跳过，避免二次录制。
    /// 位移（move / wheel）不再在这里按时间合并——改为在 flush() 里记录每帧
    /// 真正发给主机的位移值，逐帧复现才能对齐 iPadOS 的非线性指针加速曲线。
    private func recordEvent(kind: MacroEvent.Kind,
                             dx: Int = 0, dy: Int = 0, wheel: Int = 0,
                             keycode: UInt8 = 0, modifiers: UInt8 = 0,
                             mask: UInt8 = 0, count: Int = 1,
                             label: String = "") {
        guard isRecording, !isReplaying, let start = recordingStart else { return }
        let t = Date().timeIntervalSince(start)

        recordingEvents.append(MacroEvent(
            kind: kind, t: t, dx: dx, dy: dy, wheel: wheel,
            keycode: keycode, modifiers: modifiers, mask: mask,
            count: count, label: label
        ))
    }

    /// 开始录制。先把光标归位到左下角物理原点，再开始计时——这样录下的位移
    /// 以固定角落为起点，回放前同样归位即可保证轨迹落点一致。
    func startRecording() {
        guard !isRecording, !isHoming else { return }
        if isPlaying { stopPlayback() }
        recordingEvents = []
        note("准备录制：先把光标归位到左下角作为统一起点")
        beginHoming { [weak self] in
            guard let self = self else { return }
            self.recordingEvents = []
            self.recordingStart = Date()
            self.isRecording = true
            self.note("起点已归位，开始录制：现在操作触控板 / 键盘，所有键鼠动作会按时间轴记录")
        }
    }

    /// 停止录制并返回生成的宏（不含 id，由调用方存入 MacroStore）。
    @discardableResult
    func stopRecording(name: String) -> Macro? {
        guard isRecording else { return nil }
        isRecording = false
        cancelHoming()
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil
        let macro = Macro(name: name, duration: duration, events: recordingEvents)
        recordingEvents = []
        note("录制结束：共 \(macro.events.count) 个动作，时长 \(String(format: "%.1f", duration)) 秒")
        return macro
    }

    /// 播放指定宏。mode 控制循环次数；播放期间产生的输入都来自注入，不会二次录制。
    func play(macro: Macro, mode: PlayMode) {
        if isRecording { _ = stopRecording(name: macro.name) }
        stopPlayback()
        playbackMacro = macro
        playbackEvents = macro.events
        playbackMode = mode
        playbackIndex = 0
        playbackLoopsDone = 0
        playingMacroName = macro.name
        updatePlaybackRemaining()

        isPlaying = true
        note("开始回放「\(macro.name)」：\(mode.label)")
        // 每轮开始前归位到左下角，保证与录制起点一致。归位期间 playbackLoopStart
        // 保持 nil，pumpPlayback 会跳过注入；归位完成后再开始本轮计时。
        startNextLoopWithHoming(first: true)
    }

    /// 归位后开始新的一轮回放（回放起点与录制起点都对齐到左下角物理原点）。
    private func startNextLoopWithHoming(first: Bool) {
        playbackIndex = 0
        playbackLoopStart = nil
        beginHoming { [weak self] in
            guard let self = self, self.isPlaying else { return }
            self.playbackLoopStart = Date()
            if !first { self.note("回放第 \(self.playbackLoopsDone + 1) 轮（已归位）") }
        }
    }

    /// 停止回放并复位计数。
    func stopPlayback() {
        guard isPlaying else { return }
        isPlaying = false
        isReplaying = false
        cancelHoming()
        playbackMacro = nil
        playbackEvents = []
        playbackIndex = 0
        playbackLoopsDone = 0
        playbackLoopStart = nil
        playingMacroName = ""
        playbackRemaining = 0
        // 回放可能在按键按下 / 鼠标按下的中途被停掉，补发全松开避免主机卡键。
        pendingModifier = 0
        pendingKeycode = 0
        keyReleaseAt = nil
        emptyKeyFramesLeft = 3
        buttonBits = 0
        flush(force: true, modifier: 0, keycodes: [], keyReleased: true)
        note("回放已停止")
    }

    /// 用编辑后的事件列表替换当前正在播放的宏内容（编辑页即时生效用）。
    func replacePlayingEvents(_ events: [MacroEvent]) {
        guard isPlaying else { return }
        playbackEvents = events
        playbackIndex = min(playbackIndex, events.count)
    }

    private func updatePlaybackRemaining() {
        switch playbackMode {
        case .once: playbackRemaining = 1
        case .times(let n): playbackRemaining = max(0, n - playbackLoopsDone)
        case .infinite: playbackRemaining = -1
        }
    }

    /// 由 tick() 每一帧调用。事件按各自时间戳到期注入，但位移每帧最多注入一条：
    /// 录制时是逐帧发出位移的，回放必须同样逐帧摊开，不能一帧塞多条让它们累加后
    /// 合成一个大帧——否则 iPadOS 的非线性指针加速会让落点偏移，且因帧相位漂移
    /// 每次偏移都不同。非位移事件（按键/点击/滚轮）可同帧全部注入。
    private func pumpPlayback() {
        guard isPlaying, let macro = playbackMacro, let loopStart = playbackLoopStart else { return }
        let elapsed = Date().timeIntervalSince(loopStart)
        let loopDuration = max(macro.playbackDuration, playbackEvents.last?.t ?? 0) + 0.05

        // 计时到点才注入；位移类每帧只放一条，其余事件当帧补齐。
        // 用「到期事件里是否已有位移」作为本帧闸门，保证位移严格逐帧。
        var movedThisFrame = false
        var scan = playbackIndex
        while scan < playbackEvents.count,
              playbackEvents[scan].t <= elapsed {
            let ev = playbackEvents[scan]
            let isMove = (ev.kind == .move || ev.kind == .wheel)
            if isMove && movedThisFrame { break }
            inject(ev)
            scan += 1
            if isMove { movedThisFrame = true }
        }
        playbackIndex = scan

        // 一轮结束：按播放模式决定重播还是停止。
        if elapsed >= loopDuration {
            playbackLoopsDone += 1
            switch playbackMode {
            case .once:
                stopPlayback()
                return
            case .times(let n):
                if playbackLoopsDone >= n {
                    stopPlayback()
                    return
                }
            case .infinite:
                break
            }
            // 下一轮：先归位到左下角再开始，保证循环每一轮的轨迹落点都一致。
            updatePlaybackRemaining()
            startNextLoopWithHoming(first: false)
        }
    }

    /// 把一个事件注入回正常输入链路。isReplaying 保证不会被 recordEvent 再录一次。
    private func inject(_ event: MacroEvent) {
        isReplaying = true
        switch event.kind {
        case .move:
            enqueue(dx: event.dx, dy: event.dy)
        case .wheel:
            enqueue(wheel: event.wheel)
        case .key:
            sendKey(event.keycode, modifiers: event.modifiers, label: event.label)
        case .buttonDown:
            setButton(event.mask, pressed: true)
        case .buttonUp:
            setButton(event.mask, pressed: false)
        case .click:
            click(event.mask)
        }
        isReplaying = false
    }

    private var activeReport: CBMutableCharacteristic? {
        if protocolMode == 0 && bootSubscribed { return bootReport }
        if inputSubscribed { return inputReport }
        if bootSubscribed { return bootReport }
        return nil
    }

    private func flush(force: Bool, modifier: UInt8 = 0, keycodes: [UInt8] = [],
                       keyReleased: Bool = false) {
        guard bridgeMode || manager?.state == .poweredOn else { return }
        let x = Int8(clamping: pendingX)
        let y = Int8(clamping: pendingY)
        let w = Int8(clamping: pendingWheel)
        // 单帧报告每轴只有 1 字节，范围 -127...127。超出部分不能直接丢弃：
        // 录制时位移是逐帧小增量（各自不超限），但 30ms 合并后宏里存的是累加的大位移，
        // 回放时一次性 enqueue 进来会超过 127，若在此清零就会把溢出部分永久丢掉，
        // 导致回放轨迹逐段缩短、点击落点整体偏移。改为「发多少减多少」，余数留到
        // 下一帧继续发，保证录制/回放走完全相同的位移总量。
        pendingX -= Int(x)
        pendingY -= Int(y)
        pendingWheel -= Int(w)

        var mod = modifier
        var keys = keycodes
        // 鼠标按住 / 点击会强制插一帧报告。若此时虚拟键盘某个键正处于按下期间，
        // 插进来的这帧必须继续带该键，否则主机会误判成提前松键。
        if mod == 0 && keys.isEmpty && !keyReleased,
           pendingKeycode != 0,
           let t = keyReleaseAt, Date() < t {
            mod = pendingModifier
            keys = [pendingKeycode]
        }

        // 键盘按下 / 释放这两帧即使没有鼠标位移也必须发报告，
        // 否则按键会被当成一直按住（或一直没按）。
        let keyboardPending = mod != 0 || !keys.isEmpty || keyReleased
        guard force || x != 0 || y != 0 || w != 0 || keyboardPending else { return }

        // 录制：记下「本帧真正发出的位移」而非手势层的原始增量。回放时每帧注入
        // 一条、逐帧复现这个序列，iPadOS 的非线性指针加速才会得出同样的落点。
        // recordEvent 内部已用 isRecording && !isReplaying 过滤，回放不会二次录制。
        if x != 0 || y != 0 { recordEvent(kind: .move, dx: Int(x), dy: Int(y)) }
        if w != 0 { recordEvent(kind: .wheel, wheel: Int(w)) }

        // 桥接模式：把 12 字节复合报告发给 ESP32 硬件桥，由它转成蓝牙 HID。
        // 布局与 HIDSpec.compositeReportMap 逐字节对应，App 这侧的手势 / 键盘逻辑完全不变。
        if bridgeMode {
            let packet = HIDSpec.makeReport(buttons: buttonBits, x: x, y: y, wheel: w,
                                            composite: true, modifier: mod, keycodes: keys)
            bridge.send(packet)
            return
        }

        guard let characteristic = activeReport else { return }

        let packet: Data
        if characteristic === bootReport {
            // Boot Mouse 报告固定 3 字节，没有滚轮，也没有键盘字段。
            packet = Data([buttonBits, UInt8(bitPattern: x), UInt8(bitPattern: y)])
        } else {
            packet = HIDSpec.makeReport(buttons: buttonBits, x: x, y: y, wheel: w,
                                        composite: compositeDevice,
                                        modifier: mod, keycodes: keys)
        }
        send(packet, on: characteristic)
    }

    private func send(_ data: Data, on characteristic: CBMutableCharacteristic?) {
        guard let characteristic = characteristic else { return }
        guard let manager = manager, manager.state == .poweredOn else { return }
        // 按特征自身是否已订阅来决定能否发送：Boot 报告要求 bootReport 被订阅，
        // 其余报告要求 inputReport 或 Boot 报告被订阅。
        let subscribed: Bool
        if let br = bootReport, characteristic === br { subscribed = bootSubscribed }
        else { subscribed = inputSubscribed || bootSubscribed }
        guard subscribed else { return }
        guard readyToUpdate else {
            queuedPacket = (data, characteristic)
            return
        }
        readyToUpdate = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        if readyToUpdate { sentFrames += 1 }
        if !readyToUpdate {
            queuedPacket = (data, characteristic)
        }
    }

    // MARK: - 日志

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 每次推进都落盘，异常杀进程后下次启动能回看最后停在哪个阶段。
    private func mark(_ stage: String) {
        UserDefaults.standard.set(stage, forKey: HIDPeripheral.stageKey)
        lastStage = stage
    }

    private func note(_ text: String) {
        let line = "\(timeFormatter.string(from: Date()))  \(text)"
        logLines.append(line)
        if logLines.count > 80 { logLines.removeFirst(logLines.count - 80) }
    }
}
