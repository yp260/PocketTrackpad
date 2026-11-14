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

    /// 键盘是否可用由三处状态共同决定，任何一处变化都刷新一次，供界面显示。
    private func refreshKeyboardReady() {
        keyboardReady = compositeDevice && protocolMode != 0 && inputSubscribed
    }

    private func applyCompositeModeChange() {
        disconnect()
        if compositeDevice {
            statusText = "已启用键鼠复合，请重新广播并配对"
            note("已开启键鼠复合模式：输入报告 12 字节 = 鼠标 4 + 键盘 8")
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
    private var inputReport: CBMutableCharacteristic?
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
    private var link: CADisplayLink?

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
            if databaseBuilt { advertise() } else { buildDatabaseIfNeeded() }
        case .unknown, .resetting:
            statusText = "等待蓝牙就绪"
        default:
            break
        }
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

        // Descriptor 是静态元数据，允许带值；Characteristic 不允许。
        let reportRef = CBMutableDescriptor(type: HIDSpec.reportReference,
                                            value: HIDSpec.reportReferenceValue)
        let report = makeChar(HIDSpec.report, properties: [.read, .notify],
                              permissions: encRead,
                              descriptors: [reportRef])
        inputReport = report

        // Boot Mouse Input Report：iOS 在 Boot Protocol 下会走这个特征，必须提供。
        let boot = makeChar(HIDSpec.bootMouseInputReport, properties: [.read, .notify],
                            permissions: encRead)
        bootReport = boot

        let hid = CBMutableService(type: HIDSpec.hidService, primary: true)
        hid.characteristics = [info, control, map, mode, report, boot]

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

        return [hid, dis, bas]
    }

    private func buildDatabaseIfNeeded() {
        guard !databaseBuilt, let manager = manager, manager.state == .poweredOn else { return }
        databaseBuilt = true
        serviceFailed = false
        mark("3 蓝牙 poweredOn，构建 GATT 数据库")
        servicesToAdd = makeServices()
        mark("4 已构造 3 个 CBMutableService")
        note("开始注册 GATT 服务（HID / Device Info / Battery）")
        note(compositeDevice
             ? "当前模式：键鼠复合（输入报告 12 字节，三指上滑 = Command+H）"
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
                note("当前 iOS 版本可能已封堵 128 位 UUID 绕过，请改用 ESP32 硬件桥方案")
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
                note("这是系统限制，需要改用 ESP32 硬件桥方案")
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
        guard let full = readValue(for: request.characteristic.uuid) else {
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
        if id == "2A4D" { inputSubscribed = true }
        if id == "2A33" { bootSubscribed = true }
        subscribers += 1
        refreshKeyboardReady()
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
        if id == "2A4D" { inputSubscribed = false }
        if id == "2A33" { bootSubscribed = false }
        subscribers = max(0, subscribers - 1)
        refreshKeyboardReady()
        statusText = isAdvertising ? "等待 iPad 配对" : "广播已停止"
        note("主机取消订阅 \(id)")
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
        default:     return nil
        }
    }

    // MARK: - 输入上报

    /// 手势层调用：累积位移，等待下一次屏幕刷新统一发出。
    func enqueue(dx: Int = 0, dy: Int = 0, wheel: Int = 0) {
        pendingX += dx
        pendingY += dy
        pendingWheel += wheel
    }

    @objc private func tick() {
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
        guard compositeDevice else {
            note("\(reason)：当前是纯鼠标模式，请到设置里开启「键鼠复合模式」")
            return
        }
        guard protocolMode != 0 else {
            note("\(reason)：主机处于 Boot Protocol，键盘报告不可用")
            return
        }
        guard inputSubscribed else {
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
        // 延长按住到 90ms：iPad 中文输入法在拼音组合态下对选词按键（数字 / 空格）
        // 的采样更挑剔，过短的按下时间可能让 IME 漏掉该次击键，导致选词无反应。
        keyReleaseAt = Date().addingTimeInterval(0.09)
        emptyKeyFramesLeft = 0
        let modHex = String(modifiers, radix: 16, uppercase: true)
        let keyHex = String(keycode, radix: 16, uppercase: true)
        note("键盘 → \(label)（keycode 0x\(keyHex)，modifier 0x\(modHex)）")
    }

    /// 按住 / 松开某个按键。mask: 1=左键, 2=右键, 4=中键
    func setButton(_ mask: UInt8, pressed: Bool) {
        if pressed { buttonBits |= mask } else { buttonBits &= ~mask }
        flush(force: true)
    }

    /// 短按点击；count = 2 时为双击。
    func click(_ mask: UInt8, count: Int = 1) {
        buttonBits |= mask
        flush(force: true)
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

    private var activeReport: CBMutableCharacteristic? {
        if protocolMode == 0 && bootSubscribed { return bootReport }
        if inputSubscribed { return inputReport }
        if bootSubscribed { return bootReport }
        return nil
    }

    private func flush(force: Bool, modifier: UInt8 = 0, keycodes: [UInt8] = [],
                       keyReleased: Bool = false) {
        guard manager?.state == .poweredOn else { return }
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

    private func send(_ data: Data, on characteristic: CBMutableCharacteristic) {
        guard let manager = manager, manager.state == .poweredOn else { return }
        guard inputSubscribed || bootSubscribed else { return }
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
