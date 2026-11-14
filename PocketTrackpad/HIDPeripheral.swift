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

    /// iPad 蓝牙列表显示的是 iPhone 整机 GAP Device Name（0x1800 / 0x2A00），
    /// 不是广播包里的 CBAdvertisementDataLocalNameKey。iOS 不向 App 开放
    /// Device Name 特征，CoreBluetooth 也隐藏 Generic Access 服务，App 无法
    /// 改写这个名字。因此界面不再回显整机名，只在设置页给出改名步骤。

    // 设置页的三项参数做本地持久化，重开 App 不需重调。
    private static let sensKey = "PocketTrackpad.sensitivity"
    private static let scrollKey = "PocketTrackpad.scrollSensitivity"
    private static let naturalKey = "PocketTrackpad.naturalScrolling"

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

    @Published var naturalScrolling: Bool =
        (UserDefaults.standard.object(forKey: HIDPeripheral.naturalKey) as? Bool) ?? true {
            didSet { UserDefaults.standard.set(naturalScrolling, forKey: HIDPeripheral.naturalKey) }
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
        statusText = "已连接 · 可以移动指针"
        note("主机订阅 \(id)（配对完成）")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = HIDSpec.short(characteristic.uuid)
        if id == "2A4D" { inputSubscribed = false }
        if id == "2A33" { bootSubscribed = false }
        subscribers = max(0, subscribers - 1)
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
        case "2A4B": return HIDSpec.activeReportMap
        case "2A4E": return Data([protocolMode])
        case "2A4D": return HIDSpec.emptyReport()
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
        flush(force: false)
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

    private func flush(force: Bool) {
        guard manager?.state == .poweredOn else { return }
        let x = Int8(clamping: pendingX)
        let y = Int8(clamping: pendingY)
        let w = Int8(clamping: pendingWheel)
        pendingX = 0
        pendingY = 0
        pendingWheel = 0

        guard force || x != 0 || y != 0 || w != 0 else { return }
        guard let characteristic = activeReport else { return }

        let packet: Data
        if characteristic === bootReport {
            // Boot Mouse 报告固定 3 字节，没有滚轮。
            packet = Data([buttonBits, UInt8(bitPattern: x), UInt8(bitPattern: y)])
        } else {
            packet = HIDSpec.makeReport(buttons: buttonBits, x: x, y: y, wheel: w)
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
