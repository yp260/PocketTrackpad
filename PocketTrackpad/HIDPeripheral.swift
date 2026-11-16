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

    /// BLE 已订阅，或桥接端已连上，都算「链路已建立」，界面据此切换全屏触控区。
    var isLinkActive: Bool { subscribers > 0 || bridgeActive }

    /// 当前链路对端的可读名称，显示在界面「已连接」之后，让用户一眼看出连的是谁。
    ///
    /// 说明（系统限制）：iPhone 在本方案里是 BLE 外设，iPad / Windows 是主机。
    /// CoreBluetooth 在外设角色下只把对端的 `CBCentral.identifier`（UUID）交给 App，
    /// **不提供蓝牙设备名**（如「张三的 iPad」）。任何第三方 App 都无法读到该名字，
    /// 因此这里按连接来源给出可辨识的标识：
    ///   - 桥接模式：显示用户填写的真实目标地址（IP:端口），能精确定位到某一台电脑；
    ///   - Windows 原生直连：显示「Windows 电脑」；
    ///   - 其余 BLE 连接：显示「iPad」。
    var connectedDeviceName: String {
        if bridgeMode {
            return "\(bridge.currentHost):\(bridge.currentPort)"
        }
        if windowsMode {
            return "Windows 电脑"
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
    private static let sensKey = "PocketTrackpad.sensitivity"
    private static let scrollKey = "PocketTrackpad.scrollSensitivity"
    // 方向默认值已反转（上滑 = 滚轮下滑）。换新 key，避免侧载覆盖安装后
    // 残留的旧 UserDefaults 值把方向带回旧行为。
    private static let naturalKey = "PocketTrackpad.naturalScrolling.v2"

    private static func savedDouble(_ key: String, fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }

    @Published var sensitivity: Double =
        HIDPeripheral.savedDouble(HIDPeripheral.sensKey, fallback: 1.4) {
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
    // 打开后 Report Map 里多一个 Keyboard Collection，三指上滑可发 Command+H。
    // 主机在配对时会缓存 Report Map，无法热更新：切换开关必须移除整个 GATT
    // 数据库、重新广播，并由用户在主机侧「忽略此设备」重新配对。
    private static let compositeKey = "PocketTrackpad.compositeDevice.v1"

    @Published var compositeDevice: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.compositeKey) as? Bool) ?? true {
            didSet {
                UserDefaults.standard.set(compositeDevice, forKey: HIDPeripheral.compositeKey)
                applyCompositeModeChange()
            }
        }

    // MARK: - 桥接模式（ESP32 或 Windows 电脑软件接收器）
    //
    // 开启后，本 App 不再作为 BLE HID 外设广播，而是把采集到的输入通过 WiFi UDP
    // 发给「桥接端」。原因：iOS 的 CoreBluetooth 外设无法设置 GAP Appearance，
    // 导致 Windows 搜不到 / 配对失败。
    //
    // 桥接端有两种，UDP 协议完全一致：
    //   - ESP32：把报告以标准 BLE HID 转发给 Windows / Android（需要硬件）。
    //   - Windows 电脑：直接用 SendInput 注入鼠标键盘（零硬件，见 windows/ 目录）。
    private static let bridgeKey = "PocketTrackpad.bridgeMode.v1"

    @Published var bridgeMode: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.bridgeKey) as? Bool) ?? false {
            didSet {
                UserDefaults.standard.set(bridgeMode, forKey: HIDPeripheral.bridgeKey)
                if bridgeMode {
                    // 启用桥模式时先关掉本地 BLE 广播，避免两个发射源冲突、互相抢连接。
                    windowsMode = false
                    disconnect()
                    note("已启用桥接模式：iPhone 只采集输入，经 WiFi 发给桥接端")
                    note("Windows 电脑：用系统自带 PowerShell 运行 windows/pt_receiver.ps1（零安装），无需任何硬件")
                    note("ESP32：手机先连 PT-Bridge 热点，再用默认地址 192.168.4.1")
                } else {
                    note("已关闭桥接模式：恢复本机直接广播（iPad 直连）")
                }
                refreshKeyboardReady()
            }
        }

    /// 键盘是否可用由三处状态共同决定，任何一处变化都刷新一次，供界面显示。
    // MARK: - Windows 原生直连模式（电脑端零安装）
    //
    // 开启后，iPhone 以标准 BLE HID 组合设备（鼠标 + 键盘）身份广播，Windows 在
    // 设置 → 蓝牙 → 添加设备 → 其他设备 里直接配对，电脑端不装任何软件。
    //
    // 与 iPad 复合模式 / 桥接模式的区别：
    //   - iPad 复合：单条 0x2A4D 报告承载键盘 + 鼠标（无 Report ID）。
    //   - 桥接：iPhone 不发 BLE，改为 WiFi UDP 把报告发给电脑/ESP32 接收器。
    //   - Windows 直连：两条 0x2A4D 报告，分别带 Report ID 1（鼠标）/ 2（键盘）。
    //     Windows 的 HID over GATT 客户端对「无 Report ID 的复合设备」只会解析
    //     第一个顶层 Collection，鼠标或键盘必有一个失效；用 Report ID 拆开后两者都可用。
    // 与桥接模式互斥：二者同时只会有一个为 true。
    private static let windowsKey = "PocketTrackpad.windowsMode.v1"

    @Published var windowsMode: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.windowsKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(windowsMode, forKey: HIDPeripheral.windowsKey)
            if windowsMode {
                bridgeMode = false
                // 切换 GATT 拓扑必须彻底重建：移除服务、释放 manager、重新广播。
                disconnect()
                note("已启用 Windows 直连模式：iPhone 以 BLE HID 键鼠组合设备身份广播")
                note("Windows 端零安装：设置 → 蓝牙 → 添加设备 → 其他设备 → 选择 iPhone")
                note("若 Windows 列表不显示：先在高级设置打开「蓝牙设备发现：高级」或点「显示所有设备」")
                note("iPhone 当前若连着 iPad，会先断开广播，Windows 才能发现（iOS 外设被连接后停止广播）")
            } else {
                note("已关闭 Windows 直连模式：恢复 iPad 直连 / 桥接路径")
            }
            refreshKeyboardReady()
        }
    }

    private func refreshKeyboardReady() {
        if bridgeMode {
            // 桥模式下没有 protocolMode / inputSubscribed 概念，桥连上即代表键盘可用。
            keyboardReady = bridgeActive
        } else if windowsMode {
            // 鼠标报告订阅即代表链接已建立；键盘可用要求键盘报告也被订阅。
            keyboardReady = inputSubscribed && inputReport2 != nil
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
            note("三指上滑会发送 Command+H；iPad 可能把本设备识别为键盘而弹出配对验证")
            note("若鼠标失效：关掉本开关 → iPad 忽略此设备 → 重新广播配对，即回到纯鼠标")
        } else {
            statusText = "已回退纯鼠标，请重新广播并配对"
            note("已回退为纯鼠标模式：输入报告恢复 4 字节，与 v0.0.7 完全一致")
            note("需在 iPad 蓝牙里忽略此设备再重新配对，缓存的旧 Report Map 才会刷新")
        }
    }

    private static let stageKey = "PocketTrackpad.lastStage"
    /// 上次运行最后到达的阶段。App 若被异常杀掉，下次启动可直接看到卡在哪一步。
    @Published private(set) var lastStage: String? =
        UserDefaults.standard.string(forKey: HIDPeripheral.stageKey)

    // MARK: - CoreBluetooth
    private var manager: CBPeripheralManager?
    private var inputReport: CBMutableCharacteristic?      // iPad/复合：复合报告 / Windows 模式：鼠标报告(ID 1)
    private var inputReport2: CBMutableCharacteristic?     // Windows 模式：键盘报告(ID 2)
    private var bootReport: CBMutableCharacteristic?
    private var servicesToAdd: [CBMutableService] = []
    private var databaseBuilt = false
    /// 构建当前 GATT 数据库时的 windowsMode 快照。模式切换后若拓扑与此不符，
    /// start() 会自动拆除重建——否则 iPad 直连会用着 Windows 的双 Report ID 拓扑，
    /// 主机读到的 Report Map 与预期不符，表现为「搜不到 / 连上不能用」。
    private var databaseWindowsMode: Bool?
    /// 防止「订阅断开」和「连接断开」两个回调重复触发广播恢复。
    private var advertisingResumeScheduled = false
    private var serviceFailed = false
    /// 某些 iOS 版本可能拒绝在广播中放 16 位 SIG UUID，此时自动回退到 128 位。
    private var advertisingFallbackUsed = false

    // MARK: - 报告状态
    private var buttonBits: UInt8 = 0
    private var protocolMode: UInt8 = 1     // 1 = Report Protocol, 0 = Boot Protocol
    private var inputSubscribed = false
    private var keyboardSubscribed = false   // Windows 模式：键盘报告(ID 2)是否已订阅
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
    private var link: CADisplayLink?

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
    private var playbackLink: CADisplayLink?
    /// 回放注入时置 true，让 recordEvent 跳过，避免回放事件被再次录进去。
    private var isReplaying = false

    // 「统一起点」归位：录制开始前、回放每一轮开始前，先把光标推到屏幕左上角。
    // HID 是相对位移，App 读不到主机光标绝对坐标；但连续发最大负位移会让光标
    // 一路饱和到物理原点，与起始位置、屏幕分辨率、指针加速都无关，是最可靠的锚点。
    /// 归位剩余帧数（每帧 -127）。>0 时 tick() 强制发归位位移，不走 enqueue 故不会进录制。
    private var homingFramesLeft = 0
    /// 归位完成后要执行的闭包（真正开始录制 / 开始一轮回放）。
    private var afterHoming: (() -> Void)?
    /// 归位中标志，给 UI 显示状态用。
    @Published private(set) var isHoming = false

    // MARK: - 生命周期

    func start() {
        mark("1 调用 start()")
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
            // 关键修复：GATT 拓扑必须和当前模式一致。用户从 Windows 直连切回 iPad 时，
            // 关闭开关只写了 UserDefaults、没重建数据库；此时 databaseBuilt 仍为 true，
            // 若直接 advertise()，iPad 读到的还是双 Report ID 的 Windows Report Map，
            // 导致搜不到 / 配对失败。检测到快照不符就彻底拆除重建。
            if databaseBuilt, databaseWindowsMode != windowsMode {
                note("检测到 GATT 拓扑与当前模式不符，自动重建（旧模式 Windows=\(String(describing: databaseWindowsMode))，当前 Windows=\(windowsMode)）")
                disconnect()
                // disconnect() 释放了 manager，需重新创建后再构建，否则永远等不到广播。
                // 注意用 self.manager：上面的 `guard let manager` 是局部 let 常量。
                self.manager = CBPeripheralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
                )
                note("已重建 CBPeripheralManager，正在按当前模式注册服务")
                buildDatabaseIfNeeded()
                return
            }
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
        statusText = "正在连接桥接端"
        note("桥接模式：iPhone 采集输入 → WiFi UDP → 桥接端 → Windows 鼠标键盘")
        note("当前桥接端地址：\(bridge.currentHost):\(bridge.currentPort)")
        note("Windows 电脑请先运行 windows/pt_receiver.ps1（零安装），并把地址设成电脑的局域网 IP")
        bridge.connect()
    }

    /// 断开桥接端 UDP 连接；不影响本机 BLE 路径（关掉桥模式后用「开始广播」即可直连 iPad）。
    func disconnectBridge() {
        bridge.disconnect()
        subscribers = 0
        statusText = "桥接端已断开"
        note("已断开桥接端；回到 iPad 直连请关掉「桥接」开关，或点「连接桥接端」重试")
        mark("7 运行中（已断开桥接端）")
        refreshKeyboardReady()
    }

    /// 设置桥接端地址（Windows 电脑 IP / ESP32 IP）。
    func setBridgeTarget(host: String, port: String) {
        let p = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 5000
        bridge.updateTarget(host: host, port: p)
        note("桥接端地址设为 \(bridge.currentHost):\(bridge.currentPort)")
    }

    /// 重新发送握手包：PC 上的接收器若在 App 之后才启动，用它立刻建立链路。
    func resendBridgeHello() {
        bridge.resendHello()
        note("已重新发送握手包；若电脑端接收器正在运行，应立刻显示「已连接」")
    }

    func stopAdvertising() {
        manager?.stopAdvertising()
        isAdvertising = false
        statusText = "广播已停止"
        note("停止广播")
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
        keyboardSubscribed = false
        bootSubscribed = false
        inputReport = nil
        inputReport2 = nil
        bootReport = nil
        servicesToAdd.removeAll()
        databaseBuilt = false
        databaseWindowsMode = nil
        advertisingResumeScheduled = false
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
        note("已断开；点「开始广播」重建服务后，Windows / Mac 等主机即可发现")
        note("若 iPad 仍在附近且保留配对，可能自动重连；必要时先在 iPad 蓝牙里忽略此设备")
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

        // Windows 直连模式：把鼠标 / 键盘拆成两条带 Report ID 的独立输入报告，
        // 否则 Windows 的 HID over GATT 客户端只会解析 Report Map 里的第一个顶层
        // Collection，指针或键盘其中一项失效。两条报告各占一个 0x2A4D 特征，
        // 分别挂 Report Reference 描述符标注 Report ID 1（鼠标）/ 2（键盘）。
        let hid = CBMutableService(type: HIDSpec.hidService, primary: true)
        if windowsMode {
            let mouseRef = CBMutableDescriptor(type: HIDSpec.reportReference,
                                               value: HIDSpec.winMouseReportRef)
            let mouseReport = makeChar(HIDSpec.report, properties: [.read, .notify],
                                       permissions: encRead, descriptors: [mouseRef])
            inputReport = mouseReport

            let kbdRef = CBMutableDescriptor(type: HIDSpec.reportReference,
                                             value: HIDSpec.winKeyboardReportRef)
            let kbdReport = makeChar(HIDSpec.report, properties: [.read, .notify],
                                     permissions: encRead, descriptors: [kbdRef])
            inputReport2 = kbdReport

            hid.characteristics = [info, control, map, mode,
                                   mouseReport, kbdReport, boot, bootKbdIn, bootKbdOut]
        } else {
            // Descriptor 是静态元数据，允许带值；Characteristic 不允许。
            let reportRef = CBMutableDescriptor(type: HIDSpec.reportReference,
                                                value: HIDSpec.reportReferenceValue)
            let report = makeChar(HIDSpec.report, properties: [.read, .notify],
                                  permissions: encRead, descriptors: [reportRef])
            inputReport = report
            inputReport2 = nil

            hid.characteristics = [info, control, map, mode, report, boot, bootKbdIn, bootKbdOut]
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
        databaseWindowsMode = windowsMode
        serviceFailed = false
        mark("3 蓝牙 poweredOn，构建 GATT 数据库")
        servicesToAdd = makeServices()
        mark("4 已构造 4 个 CBMutableService（HID / Device Info / Battery / Generic Access）")
        note("开始注册 GATT 服务（HID / Device Info / Battery / Generic Access）")
        if windowsMode {
            note("当前模式：Windows 直连（鼠标 Report ID 1 + 键盘 Report ID 2，两条独立报告）")
        } else {
            note(compositeDevice
                 ? "当前模式：键鼠复合（输入报告 12 字节，三指上滑 = Command+H）"
                 : "当前模式：纯鼠标（输入报告 4 字节，与 v0.0.7 相同）")
        }
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
        guard let manager = manager, manager.state == .poweredOn, !isAdvertising else { return }
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
        note("要显示 PT-Pad：iPad 蓝牙里重命名，或改 iPhone 名称后忽略此设备重新配对")
    }

    /// 主机断开后自动恢复广播。
    ///
    /// iOS 有一个坑：外设被中央设备（iPad）连接后，系统会停止广播，但**不会**
    /// 通过任何 delegate 回调告知 App，导致 isAdvertising 一直是 true、界面按钮
    /// 停在「停止广播」。用户若在 iPad 上「忽略此设备」，iPhone 这边不会自己
    /// 重新广播，iPad 就再也搜不到了——这正是「又搜不到」的高频原因。
    /// 因此在确认订阅清零后强制 stop→start 重新发起广播。
    private func ensureAdvertisingAfterDisconnect() {
        // 桥接模式下本来就不广播；manager 已被 disconnect 释放时也不处理。
        guard !bridgeMode,
              !advertisingResumeScheduled,
              let manager = manager,
              manager.state == .poweredOn,
              databaseBuilt,
              subscribers == 0 else { return }
        advertisingResumeScheduled = true
        manager.stopAdvertising()
        isAdvertising = false
        // 稍等，确保系统已彻底释放旧连接，否则 startAdvertising 会被拒。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.advertisingResumeScheduled = false
            guard !self.bridgeMode,
                  self.subscribers == 0,
                  self.manager?.state == .poweredOn,
                  !self.isAdvertising else { return }
            self.startAdvertising(with: HIDSpec.advertisedServiceUUIDs, fallback: false)
            self.statusText = "等待 iPad 配对"
            self.note("检测到主机断开，已自动恢复广播；iPad 现在可重新搜索 PT-Pad")
        }
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
                note("当前 iOS 版本可能已封堵 128 位 UUID 绕过，请改用桥接模式（Windows 电脑接收器 / ESP32）")
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
            statusText = advertisingFallbackUsed ? "广播中（兼容模式）" : "等待 iPad 配对"
            mark("7 运行中（广播正常）")
            if advertisingFallbackUsed {
                note("当前 iOS 版本禁止广播 16 位 SIG UUID，主机大概率不会显示本设备")
                note("这是系统限制，请改用桥接模式（Windows 电脑接收器 / ESP32）")
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
        // Windows 直连模式下两条输入报告共用 0x2A4D UUID，必须用特征对象本身
        // （而非 UUID）来区分鼠标 / 键盘，返回各自带 Report ID 的空报告。
        let full: Data?
        if windowsMode, request.characteristic === inputReport2 {
            full = HIDSpec.winKeyboardReport(modifier: 0, keycodes: [])
        } else if windowsMode, request.characteristic === inputReport {
            full = HIDSpec.winMouseReport(buttons: 0, x: 0, y: 0, wheel: 0)
        } else {
            full = readValue(for: request.characteristic.uuid)
        }
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
        // 两条输入报告共用 0x2A4D UUID，必须用特征对象（而非 UUID）区分订阅来源。
        if characteristic === inputReport { inputSubscribed = true }
        if characteristic === inputReport2 { keyboardSubscribed = true }
        if characteristic === bootReport { bootSubscribed = true }
        subscribers += 1
        refreshKeyboardReady()
        statusText = "已连接 · 可以移动指针"
        let which = characteristic === inputReport2 ? "键盘报告(ID 2)"
                    : (characteristic === inputReport ? "鼠标报告(ID 1)" : id)
        note("主机订阅 \(which)（配对完成）")
        if windowsMode {
            note(keyboardReady
                 ? "Windows 键鼠均就绪：可移动指针并输入"
                 : "鼠标已连接，等待 Windows 订阅键盘报告")
        } else if keyboardReady {
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
        if characteristic === inputReport2 { keyboardSubscribed = false }
        if characteristic === bootReport { bootSubscribed = false }
        subscribers = max(0, subscribers - 1)
        refreshKeyboardReady()
        statusText = isAdvertising ? "等待 iPad 配对" : "广播已停止"
        let which = characteristic === inputReport2 ? "键盘报告(ID 2)"
                    : (characteristic === inputReport ? "鼠标报告(ID 1)" : id)
        note("主机取消订阅 \(which)")
        // 最后一个订阅也断开：自动恢复广播，保证 iPad 忽略设备后能重新搜到。
        if subscribers == 0 { ensureAdvertisingAfterDisconnect() }
    }

    /// 中央设备彻底断开连接（iOS 13+）。覆盖「连上但没订阅就断开」的情况，
    /// 同样要在无订阅时恢复广播，避免 iPad 忽略设备后永久搜不到。
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didDisconnect central: CBCentral) {
        note("主机已断开连接")
        // 有时 didUnsubscribeFrom 不会在断连前到达，subscribers 会残留非 0，
        // 令恢复逻辑永不触发。彻底断连即代表没有任何订阅，直接清零。
        inputSubscribed = false
        keyboardSubscribed = false
        bootSubscribed = false
        subscribers = 0
        refreshKeyboardReady()
        ensureAdvertisingAfterDisconnect()
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
        case "2A4B": return windowsMode
            ? HIDSpec.winReportMap
            : HIDSpec.reportMap(composite: compositeDevice)
        case "2A4E": return Data([protocolMode])
        case "2A4D": return HIDSpec.emptyReport(composite: compositeDevice)
        case "2A33": return Data([0x00, 0x00, 0x00])
        case "2A29": return Data("PocketTrackpad".utf8)
        case "2A24": return Data("PT-01".utf8)
        case "2A26": return Data("1.0.0".utf8)
        case "2A50": return HIDSpec.pnpIDValue
        case "2A19": return Data([100])
        case "2A01": return windowsMode ? HIDSpec.appearanceCombo : HIDSpec.appearanceValue
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
        // 录制：位移与滚轮分开成两个事件（滚轮是独立语义，回放时要能单独编辑）。
        if dx != 0 || dy != 0 { recordEvent(kind: .move, dx: dx, dy: dy) }
        if wheel != 0 { recordEvent(kind: .wheel, wheel: wheel) }
    }

    @objc private func tick() {
        // 归位阶段：每帧强制发左上角方向的饱和位移，直接写 pending（不经 enqueue，
        // 因此不会被 recordEvent 录进宏），保证回放起点与录制起点是同一物理角落。
        var homingCompleted = false
        if homingFramesLeft > 0 {
            homingFramesLeft -= 1
            pendingX = -127
            pendingY = -127
            if homingFramesLeft == 0 { homingCompleted = true }
        }

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
        flush(force: false, modifier: modifier, keycodes: keycodes,
              keyReleased: keyReleased)

        // 归位帧全部发出后再执行闭包（开始录制 / 开始一轮回放）。
        if homingCompleted {
            isHoming = false
            let done = afterHoming
            afterHoming = nil
            done?()
        }
    }

    /// 开始归位：连续若干帧把光标推向左上角物理原点。完成后执行 action。
    /// 帧数取 90（60Hz 约 1.5 秒），足以让任意屏幕尺寸 + 指针加速下的光标饱和到角落。
    private func beginHoming(then action: @escaping () -> Void) {
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        afterHoming = action
        homingFramesLeft = 90
        isHoming = true
        note("正在归位光标到屏幕左上角（统一起点），约 1.5 秒…")
    }

    /// 取消归位：停止录制 / 停止回放时调用，避免残留闭包稍后误触发。
    private func cancelHoming() {
        homingFramesLeft = 0
        afterHoming = nil
        isHoming = false
    }

    /// 三指上滑：发一次 Command + H，让 iPadOS 回主屏幕。
    /// 走与全键盘相同的 sendKey 链路，按下和释放由 tick() 统一管理。
    func goHome() {
        note("三指上滑 → 发送 Command + H（回主屏幕）")
        sendKey(HIDSpec.homeKeycode,
                modifiers: HIDSpec.commandModifier,
                label: "三指上滑 · Command + H",
                reason: "三指上滑未生效")
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
        guard compositeDevice || bridgeMode || windowsMode else {
            note("\(reason)：当前是纯鼠标模式，请到设置里开启「键鼠复合模式」/「Windows 直连」或桥接模式")
            return
        }
        guard bridgeMode || windowsMode || protocolMode != 0 else {
            note("\(reason)：主机处于 Boot Protocol，键盘报告不可用")
            return
        }
        guard bridgeMode || windowsMode || inputSubscribed else {
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

    /// 记录一个输入事件。回放注入期间（isReplaying）跳过，避免二次录制；
    /// move / wheel 这类高频事件按 30ms 合并到上一条同类事件，控制数据量。
    private func recordEvent(kind: MacroEvent.Kind,
                             dx: Int = 0, dy: Int = 0, wheel: Int = 0,
                             keycode: UInt8 = 0, modifiers: UInt8 = 0,
                             mask: UInt8 = 0, count: Int = 1,
                             label: String = "") {
        guard isRecording, !isReplaying, let start = recordingStart else { return }
        let t = Date().timeIntervalSince(start)

        // 高频位移合并：同一类且间隔 < 30ms 的连续事件累加，避免一秒数百条。
        if kind == .move || kind == .wheel,
           let last = recordingEvents.indices.last,
           recordingEvents[last].kind == kind,
           t - recordingEvents[last].t < 0.03 {
            recordingEvents[last].dx += dx
            recordingEvents[last].dy += dy
            recordingEvents[last].wheel += wheel
            return
        }

        recordingEvents.append(MacroEvent(
            kind: kind, t: t, dx: dx, dy: dy, wheel: wheel,
            keycode: keycode, modifiers: modifiers, mask: mask,
            count: count, label: label
        ))
    }

    /// 开始录制。先把光标归位到左上角物理原点，再开始计时——这样录下的位移
    /// 以固定角落为起点，回放前同样归位即可保证轨迹落点一致。
    func startRecording() {
        guard !isRecording, !isHoming else { return }
        if isPlaying { stopPlayback() }
        recordingEvents = []
        note("准备录制：先把光标归位到左上角作为统一起点")
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

        if playbackLink == nil {
            let l = CADisplayLink(target: self, selector: #selector(playbackTick))
            l.add(to: .main, forMode: .common)
            playbackLink = l
        }
        isPlaying = true
        note("开始回放「\(macro.name)」：\(mode.label)")
        // 每轮开始前归位到左上角，保证与录制起点一致。归位期间 playbackLoopStart
        // 保持 nil，playbackTick 会跳过注入；归位完成后再开始本轮计时。
        startNextLoopWithHoming(first: true)
    }

    /// 归位后开始新的一轮回放（回放起点与录制起点都对齐到左上角物理原点）。
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
        guard isPlaying || playbackLink != nil else { return }
        playbackLink?.invalidate()
        playbackLink = nil
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

    @objc private func playbackTick() {
        guard isPlaying, let macro = playbackMacro, let loopStart = playbackLoopStart else { return }
        let elapsed = Date().timeIntervalSince(loopStart)
        let loopDuration = max(macro.playbackDuration, playbackEvents.last?.t ?? 0) + 0.05

        // 时间到了就注入所有到期事件；即使某一帧卡顿漏过多个事件也不会丢。
        while playbackIndex < playbackEvents.count,
              playbackEvents[playbackIndex].t <= elapsed {
            inject(playbackEvents[playbackIndex])
            playbackIndex += 1
        }

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
            // 下一轮：先归位到左上角再开始，保证循环每一轮的轨迹落点都一致。
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
        pendingX = 0
        pendingY = 0
        pendingWheel = 0

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

        // 桥接模式：直接把 12 字节复合报告发给桥接端（ESP32 或 Windows 电脑接收器）。
        // 布局与 HIDSpec.compositeReportMap 逐字节对应，App 这侧的手势 / 键盘逻辑完全不变。
        if bridgeMode {
            let packet = HIDSpec.makeReport(buttons: buttonBits, x: x, y: y, wheel: w,
                                            composite: true, modifier: mod, keycodes: keys)
            bridge.send(packet)
            return
        }

        // Windows 直连：鼠标 / 键盘是两条独立报告，分别发到各自特征（各带 Report ID）。
        if windowsMode {
            let mouseReport = HIDSpec.winMouseReport(buttons: buttonBits, x: x, y: y, wheel: w)
            send(mouseReport, on: inputReport)
            if mod != 0 || !keys.isEmpty || keyReleased {
                let kbdReport = HIDSpec.winKeyboardReport(modifier: mod, keycodes: keys)
                send(kbdReport, on: inputReport2)
            }
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
        // 按特征自身是否已订阅来决定能否发送：Windows 模式下鼠标 / 键盘是两条独立
        // 特征，键盘报告仅在键盘特征被订阅后才能发。
        let subscribed: Bool
        if let i2 = inputReport2, characteristic === i2 { subscribed = keyboardSubscribed }
        else if let br = bootReport, characteristic === br { subscribed = bootSubscribed }
        else { subscribed = inputSubscribed || bootSubscribed }
        guard subscribed else { return }
        guard readyToUpdate else {
            queuedPacket = (data, characteristic)
            return
        }
        readyToUpdate = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
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
