import Foundation
import Network

/// 硬件桥传输层：iPhone 把 12 字节复合 HID 报告通过 UDP 发给 ESP32，
/// 由 ESP32 以标准 BLE HID（带正确 GAP Appearance = 0x03C1 HID Keyboard）转发给 Windows / Android。
///
/// 为什么需要这一层：iOS 的 CoreBluetooth 外设无法设置 GAP Appearance，
/// 导致 Windows 等主机搜不到 / 配对失败（详见 README「硬件桥（ESP32）」一节）。
/// ESP32 能在广播里设置 Appearance，因此 iPhone 只负责采集输入，
/// ESP32 负责「像鼠标一样被主机发现」。
///
/// 协议（见 ESP32 端 `main.cpp`）：
///   - iPhone 周期发送 2 字节 hello 包 [0x50,0x54]（"PT"），ESP32 收到后回 [0x54,0x50]（"TP"）。
///   - iPhone 把 12 字节复合 HID 报告原样发给 ESP32，ESP32 直接 notify 给主机。
///     12 字节布局与 App 内 `HIDSpec.compositeReportMap` 逐字节对应。
final class BridgeTransport: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "硬件桥未连接"

    /// 连接状态变化回调，由 HIDPeripheral 注入，用来刷新界面的已连接标志。
    var onConnectionChange: (() -> Void)?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?

    private let helloMagic: [UInt8] = [0x50, 0x54]   // "PT"

    init(host: String = "192.168.4.1", port: UInt16 = 5000) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(5000)
    }

    func connect() {
        guard connection == nil else { return }
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.handleState(state) }
        }
        connection = conn
        conn.start(queue: .main)
        statusText = "正在连接硬件桥 \(host)"
        startReceive()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionChange?()
        }
        statusText = "硬件桥已断开"
    }

    /// 发送一条 12 字节复合 HID 报告（与 ESP32 端描述符逐字节对应）。
    func send(_ report: Data) {
        guard let conn = connection, conn.state == .ready else { return }
        conn.send(content: report,
                  contentContext: .defaultMessage,
                  isComplete: true,
                  completion: .contentProcessed({ _ in }))
    }

    // MARK: - 内部

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // ready 仅代表本地 UDP 套接字已就绪，不代表 ESP32 已应答；
            // 真正的「已连接」以收到 ESP32 的 welcome 回包为准（见 startReceive）。
            statusText = "已连上网络，等待硬件桥应答…"
            // 立刻发一次 hello，触发 ESP32 回包。
            connection?.send(content: Data(helloMagic),
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed({ _ in }))
        case .failed(let err):
            statusText = "硬件桥连接失败：\(err.localizedDescription)"
            connection = nil
            if isConnected { isConnected = false; onConnectionChange?() }
        case .cancelled:
            connection = nil
        default:
            break
        }
    }

    /// 持续接收 ESP32 的回包；收到任意回包即判定为「已连接」。
    private func startReceive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, !self.isConnected {
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.statusText = "已连接硬件桥 PT-Bridge"
                    self.onConnectionChange?()
                }
            }
            if error == nil { self.startReceive() }
        }
    }
}
