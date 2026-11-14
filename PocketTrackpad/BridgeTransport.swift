import Foundation
import Network

/// 桥接传输层：iPhone 把 12 字节复合 HID 报告通过 UDP 发给「桥接端」，
/// 桥接端可以是两种东西，协议完全一致：
///
///   1. ESP32（esp32/ 固件）：收到后以标准 BLE HID（带正确 GAP Appearance =
///      0x03C1 HID Keyboard）转发给 Windows / Android。
///   2. Windows 电脑上的软件接收器（windows/pt_receiver.py）：收到后直接用
///      Win32 SendInput 注入鼠标键盘，不需要任何额外硬件。
///
/// 为什么需要这一层：iOS 的 CoreBluetooth 外设无法设置 GAP Appearance，
/// 导致 Windows 等主机搜不到 / 配对失败（详见 README「Windows 直连」一节）。
/// 把「被主机发现」这一步交给桥接端，iPhone 只负责采集输入。
///
/// 协议（见 ESP32 端 `main.cpp` 与 PC 端 `pt_receiver.py`）：
///   - iPhone 周期发送 2 字节 hello 包 [0x50,0x54]("PT")，桥接端回 [0x54,0x50]("TP")。
///   - iPhone 把 12 字节复合 HID 报告原样发给桥接端，由它转发 / 注入给主机。
///     12 字节布局与 App 内 `HIDSpec.compositeReportMap` 逐字节对应。
final class BridgeTransport: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "桥接端未连接"

    /// 连接状态变化回调，由 HIDPeripheral 注入，用来刷新界面的已连接标志。
    var onConnectionChange: (() -> Void)?

    private var host: NWEndpoint.Host
    private var port: NWEndpoint.Port
    private var connection: NWConnection?

    private let helloMagic: [UInt8] = [0x50, 0x54]   // "PT"

    /// 目标地址存 UserDefaults：不同电脑 / 不同网络下 IP 会变，
    /// 侧载覆盖安装后仍需沿用，所以必须持久化。
    private static let hostKey = "PocketTrackpad.bridgeHost.v1"
    private static let portKey = "PocketTrackpad.bridgePort.v1"

    /// 默认指向 ESP32 热点（ESP32 开着 softAP 时的地址）。
    /// 走 Windows 电脑时改成电脑的局域网 IP（设置页可填）。
    static let defaultHost = "192.168.4.1"

    init(host: String = BridgeTransport.savedHost,
         port: UInt16 = BridgeTransport.savedPort) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(5000)
    }

    private static var savedHost: String {
        let v = UserDefaults.standard.string(forKey: hostKey) ?? defaultHost
        return v.isEmpty ? defaultHost : v
    }

    private static var savedPort: UInt16 {
        let v = UserDefaults.standard.integer(forKey: portKey)
        return v > 0 && v < 65536 ? UInt16(v) : 5000
    }

    /// 当前桥接端地址（供设置页显示）。
    var currentHost: String { "\(host)" }
    var currentPort: Int { Int(port.rawValue) }

    /// 修改桥接端地址。若正在连接，会断开并用新地址重连。
    func updateTarget(host newHost: String, port newPort: UInt16) {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? BridgeTransport.defaultHost : trimmed
        guard effective != "\(host)" || newPort != port.rawValue else { return }
        let wasConnected = isConnected
        if connection != nil {
            // 代次自增，使旧连接的异步回调全部失效（否则会误停新连接的心跳）。
            connectionGeneration += 1
            connection?.cancel()
            connection = nil
            if isConnected {
                isConnected = false
                // 地址变了，链路已断：通知外部刷新界面状态。
                onConnectionChange?()
            }
        }
        host = NWEndpoint.Host(effective)
        port = NWEndpoint.Port(rawValue: newPort) ?? NWEndpoint.Port(5000)
        UserDefaults.standard.set(effective, forKey: BridgeTransport.hostKey)
        UserDefaults.standard.set(Int(newPort), forKey: BridgeTransport.portKey)
        statusText = "桥接端地址已改为 \(effective):\(newPort)"
        if wasConnected {
            connect()
        }
    }

    func connect() {
        guard connection == nil else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self, self.connectionGeneration == generation else { return }
                self.handleState(state)
            }
        }
        connection = conn
        conn.start(queue: .main)
        statusText = "正在连接桥接端 \(host):\(port.rawValue)"
        startReceive()
        startHeartbeat()
    }

    func disconnect() {
        stopHeartbeat()
        // 代次自增，使旧连接的异步回调全部失效。
        connectionGeneration += 1
        connection?.cancel()
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionChange?()
        }
        statusText = "桥接端已断开"
    }

    /// 发送一条 12 字节复合 HID 报告（与 ESP32 / PC 接收器描述符逐字节对应）。
    func send(_ report: Data) {
        guard let conn = connection, conn.state == .ready else { return }
        conn.send(content: report,
                  contentContext: .defaultMessage,
                  isComplete: true,
                  completion: .contentProcessed({ _ in }))
    }

    /// 重新发送 hello 包。
    ///
    /// 场景：iPhone 先连上 WiFi 并开始发报告，PC 上的接收器是之后才启动的。
    /// 此时最初的 hello 已经发出去没人应答，iPhone 会一直停在「等待应答」。
    /// 补发一次 hello 让对端立刻回 welcome，链路状态随即同步。
    func resendHello() {
        guard let conn = connection, conn.state == .ready else { return }
        conn.send(content: Data(helloMagic),
                  contentContext: .defaultMessage,
                  isComplete: true,
                  completion: .contentProcessed({ _ in }))
    }

    // MARK: - 内部

    /// 心跳定时器：未连通时定期重发 hello，连通后定期保活。
    private var heartbeatTimer: Timer?

    /// 连接代次：每次新建连接自增。
    ///
    /// 旧连接的 `.cancelled` 回调是异步派发的，可能在新连接建好之后才到达。
    /// 若不区分代次，旧回调会误停掉新连接的心跳。用代次号把回调与连接绑定。
    private var connectionGeneration = 0

    /// 启动心跳。
    ///
    /// UDP 是无连接的：如果电脑上的接收器比 App 晚启动，最初那个 hello 没人应答，
    /// App 会一直停在「等待应答」。有了心跳，对端一上线就能自动握手成功，
    /// 不需要用户手动点「重新握手」。
    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: isConnected ? 5.0 : 2.0,
                                         repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.resendHello()
        }
        // 允许在主线程 RunLoop 之外的模式下也触发，避免界面滚动时心跳被拖慢。
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // ready 仅代表本地 UDP 套接字已就绪，不代表桥接端已应答；
            // 真正的「已连接」以收到 welcome 回包为准（见 startReceive）。
            statusText = "已连上网络，等待桥接端应答…"
            // 立刻发一次 hello，触发对端回包。
            connection?.send(content: Data(helloMagic),
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed({ _ in }))
        case .failed(let err):
            // UDP 对端不存在时会收到 ICMP 端口不可达，NWConnection 报 .failed。
            // 这不代表配置错误——电脑上的接收器可能只是还没启动。
            // 因此不放弃重连：重建连接，由心跳继续尝试握手。
            statusText = "桥接端未应答（\(err.localizedDescription)），正在重试…"
            connection = nil
            if isConnected { isConnected = false; onConnectionChange?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.connection == nil else { return }
                self.connect()
            }
        case .cancelled:
            connection = nil
            stopHeartbeat()
        default:
            break
        }
    }

    /// 持续接收桥接端的回包；收到任意回包即判定为「已连接」。
    private func startReceive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, !self.isConnected {
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.statusText = "已连接桥接端 \(self.host):\(self.port.rawValue)"
                    self.onConnectionChange?()
                    // 连上后心跳放慢，只做保活。
                    self.startHeartbeat()
                }
            }
            if error == nil { self.startReceive() }
        }
    }
}
