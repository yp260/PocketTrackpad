import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @State private var showSettings = false
    /// true = 全键盘，false = 触控板。只在已连接时生效，断开自动回到触控板。
    @State private var showKeyboard = false
    /// 断开后弹出「切换设备」指引（配对信息在主机侧，iPad 会自动回连）。
    @State private var showSwitchHelp = false

    /// 主机订阅了 Input Report 才算真正连上；仅广播中不算连接。
    private var connected: Bool { hid.subscribers > 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if connected {
                    if showKeyboard {
                        KeyboardPanel(showKeyboard: $showKeyboard)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // 触控区顶部常驻一条切换栏：一键切到全键盘。
                        TrackpadTopBar(showKeyboard: $showKeyboard)
                        TrackpadSurface(edgeToEdge: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.container, edges: .horizontal)
                    }
                } else {
                    setupBody
                }
                ButtonBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: hid.subscribers) { newValue in
                // 断开后不要停留在键盘界面，下次连上仍从触控板开始。
                if newValue == 0 { showKeyboard = false }
            }
            .navigationTitle(connected ? "PT-Pad" : "口袋触控板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.footnote)
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("设置")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if connected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("已连接")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        DisconnectButton(onDisconnected: { showSwitchHelp = true })
                    }
                    Button {
                        if hid.isAdvertising { hid.stopAdvertising() } else { hid.start() }
                    } label: {
                        Text(hid.isAdvertising ? "停止广播" : "开始广播")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("已断开", isPresented: $showSwitchHelp) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("要连接到其他设备（Windows / Android）：\n\n1. 在刚断开的设备（如 iPad）蓝牙设置里「忽略此设备」，否则它会因已配对而自动抢连。\n2. 打开目标设备蓝牙，搜索并配对 PT-Pad。\n3. 回到本 App 点右上角「开始广播」。\n\n提示：三指上滑（Command + H）只对 iPadOS 有效；Windows 回桌面用 Win + D，macOS 用 F11。")
            }
        }
    }

    // MARK: - 未连接时的引导页

    private var setupBody: some View {
        ScrollView {
            VStack(spacing: 14) {

                // 诊断卡片：异常闪退时显示上次运行最后到达的阶段
                if let stage = hid.lastStage, !stage.hasPrefix("7") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("上次运行记录")
                            .font(.caption.weight(.semibold))
                        Text(stage)
                            .font(.system(size: 11, design: .monospaced))
                        Text("若每次都停在同一步，把这段文字发回即可定位。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12))
                }

                // 状态卡片
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle()
                            .fill(hid.isAdvertising ? Color.orange : Color.gray)
                            .frame(width: 9, height: 9)
                        Text(hid.statusText)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("订阅 \(hid.subscribers)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("iPad 上打开 设置 > 蓝牙，在「其他设备」里选择 PT-Pad 完成配对。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("用右上角的「开始广播」启动蓝牙；连接成功后会自动出现全屏触控区。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // 显式撑满：VStack 默认按最宽子视图定宽，内容短时会缩成窄卡片并居中。
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                // 指针与滚动：连接前在主页面直接调。
                // 连接后本页会被全屏触控区替换，届时从设置子页面调整。
                VStack(alignment: .leading, spacing: 10) {
                    Text("指针与滚动")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("指针速度")
                            Spacer()
                            Text(String(format: "%.1f×", hid.sensitivity))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $hid.sensitivity, in: 0.4...3.5, step: 0.1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("滚动速度")
                            Spacer()
                            Text(String(format: "%.1f×", hid.scrollSensitivity))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $hid.scrollSensitivity, in: 0.3...3.0, step: 0.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                // 连接日志：初始只有一行短日志，若不限宽会明显比其他卡片窄。
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(hid.logLines.suffix(10), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 108)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                Text("请保持本 App 在前台、屏幕常亮。锁屏或切到后台后 iOS 会停止 BLE 广播。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 设置子页面

struct SettingsView: View {

    @EnvironmentObject private var hid: HIDPeripheral

    var body: some View {
        Form {
            Section("指针") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("指针速度")
                        Spacer()
                        Text(String(format: "%.1f×", hid.sensitivity))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $hid.sensitivity, in: 0.4...3.5, step: 0.1)
                }
                Text("单指拖动换算成指针位移的倍率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("滚动") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("滚动速度")
                        Spacer()
                        Text(String(format: "%.1f×", hid.scrollSensitivity))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $hid.scrollSensitivity, in: 0.3...3.0, step: 0.1)
                }
                Toggle("自然滚动", isOn: $hid.naturalScrolling)
                Text("默认：双指或滚轮键向上滑 = 滚轮下滑。打开自然滚动后方向整体反转（跟手）。同时作用于双指滚动和底部滚轮键，设置会自动保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("按键") {
                LabeledRow(title: "左键 / 右键", detail: "按住 = 按下，松手 = 抬起")
                LabeledRow(title: "滚轮", detail: "上下拖动 = 滚动，双击 = 按下滚轮键")
                LabeledRow(title: "触控区", detail: "轻点左键 · 双击左键 · 长按右键")
                LabeledRow(title: "全键盘", detail: "触控区顶部「全键盘」一键切换")
                LabeledRow(title: "组合键", detail: "Ctrl / Opt / Cmd / ⇧ 为一次性粘滞键")
            }

            Section {
                Toggle("键鼠复合模式", isOn: $hid.compositeDevice)
                LabeledRow(title: "三指上滑", detail: "回桌面（Command + H）")
                LabeledRow(title: "全键盘", detail: "两页键位 + 下方小触控区（可移动指针）")
                LabeledRow(title: "输入报告",
                           detail: hid.compositeDevice ? "12 字节（鼠标 4 + 键盘 8）" : "4 字节（纯鼠标）")
            } header: {
                Text("实验功能 · 全键盘与回桌面")
            } footer: {
                Text("开启后本设备同时声明为鼠标和键盘，全键盘与三指上滑都依赖这个开关。iPad 可能弹出键盘配对验证，也可能拒绝接管整个设备导致鼠标失效。切换开关会自动断开并移除 GATT 服务：请在 iPad 蓝牙里「忽略此设备」，回到主页面点「开始广播」，再重新配对。若指针或点击失效，关掉本开关、同样忽略设备重新配对即可回到纯鼠标，不需要重装 App。Command + H 只对 iPadOS 有效；Windows 显示桌面是 Win + D，macOS 是 F11。")
                    .font(.caption)
            }

            Section {
                LabeledRow(title: "iPad 自动重连", detail: "已配对会主动回连")
                LabeledRow(title: "切到 Windows", detail: "iPad 忽略本设备 → 配对 PT-Pad")
                LabeledRow(title: "切到 Android", detail: "同样先忽略本设备再配对")
                LabeledRow(title: "本 App", detail: "断开后点「开始广播」")
            } header: {
                Text("切换设备")
            } footer: {
                Text("蓝牙 HID 的配对信息存在主机侧：本 App 作为外设无法远程解除 iPad 的配对。要连 Windows / Android，请先在 iPad 蓝牙里「忽略此设备」，否则它会因已配对自动抢连。Android 对 BLE HID 的支持因机型而异，部分旧机型可能无法识别；Windows 回桌面是 Win + D，本 App 的三指上滑（Command + H）只对 iPadOS 有效。")
                    .font(.caption)
            }

            Section {
                LabeledRow(title: "广播名称", detail: "PT-Pad")
                LabeledRow(title: "iPad 显示名称", detail: "跟随 iPhone 整机名")
                LabeledRow(title: "连接方式", detail: "蓝牙 HID over GATT")
                LabeledRow(title: "前台要求", detail: "锁屏后 iOS 会停止广播")
            } header: {
                Text("关于")
            } footer: {
                Text("iPad 蓝牙列表优先显示 iPhone 整机名（GAP Device Name），不是广播名称，App 无权改写。要显示 PT-Pad：① 在 iPad 设置 → 蓝牙 → 已连接设备旁的更多信息按钮 → 名称，改成 PT-Pad（改完不要再忽略此设备）；或 ② 把 iPhone 设置 → 通用 → 关于本机 → 名称 改成 PT-Pad，再到 iPad 蓝牙里「忽略此设备」后重新配对。两条路径都不需要重装 App。")
                    .font(.caption)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabeledRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 触控区顶部的全键盘切换栏

/// 只在已连接的触控板界面出现。按钮刻意做成蓝色实心主操作，
/// 避免在全屏触控区里找不到入口；切成全键盘后由键盘页顶部提供返回按钮。
private struct TrackpadTopBar: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @Binding var showKeyboard: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("触控板模式")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !hid.keyboardReady {
                Text("键盘未就绪")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            }
            Button {
                showKeyboard = true
            } label: {
                Label("全键盘", systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("切换到全键盘")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 底部按键条

/// 固定在屏幕最底部，不随引导页滚动，也不随连接状态切换。
/// 三键宽度按 左键 : 滚轮 : 右键 = 3 : 2 : 3 分配：滚轮键只需要上下拖动，
/// 收窄后把宽度让给更常用的左右键。
private struct ButtonBar: View {
    private static let spacing: CGFloat = 10
    private static let leftWeight: CGFloat = 3
    private static let wheelWeight: CGFloat = 2
    private static let rightWeight: CGFloat = 3

    private func keyWidths(for total: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let sum = ButtonBar.leftWeight + ButtonBar.wheelWeight + ButtonBar.rightWeight
        let usable = max(0, total - ButtonBar.spacing * 2)
        return (usable * ButtonBar.leftWeight / sum,
                usable * ButtonBar.wheelWeight / sum,
                usable * ButtonBar.rightWeight / sum)
    }

    private func keys(width: CGFloat) -> some View {
        let w = keyWidths(for: width)
        // width 属于 frame(width:height:) 重载，maxHeight 属于
        // frame(minWidth:...:maxHeight:) 重载，两者不能混用（编译报 extra argument 'width'）。
        // 这里全部用第二个重载，把宽度钉死、高度撑满 HStack。
        return HStack(spacing: ButtonBar.spacing) {
            HoldButton(title: "左键", mask: 0x01)
                .frame(minWidth: w.0, idealWidth: w.0, maxWidth: w.0, maxHeight: .infinity)
            WheelButton()
                .frame(minWidth: w.1, idealWidth: w.1, maxWidth: w.1, maxHeight: .infinity)
            HoldButton(title: "右键", mask: 0x02)
                .frame(minWidth: w.2, idealWidth: w.2, maxWidth: w.2, maxHeight: .infinity)
        }
    }

    var body: some View {
        GeometryReader { geo in
            keys(width: geo.size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 76)   // 从 116pt 降低，把高度让给键盘页的小触控区
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background {
            Color(.secondarySystemBackground)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) { Divider() }
    }
}

/// 按住 = 按键按下，松手 = 按键抬起。
private struct HoldButton: View {

    @EnvironmentObject private var hid: HIDPeripheral
    let title: String
    let mask: UInt8
    @State private var isDown = false

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDown ? Color.accentColor.opacity(0.85) : Color(.tertiarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(isDown ? Color.white : Color.primary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDown else { return }
                        isDown = true
                        hid.setButton(mask, pressed: true)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        isDown = false
                        hid.setButton(mask, pressed: false)
                    }
            )
    }
}

/// 滚轮键：上下拖动发送 wheel，双击发送中键（按下滚轮键）。
/// 单击刻意不产生按键，避免在滚动时误触中键。
private struct WheelButton: View {

    @EnvironmentObject private var hid: HIDPeripheral

    @State private var isDragging = false
    @State private var lastY: CGFloat = 0
    @State private var residual: CGFloat = 0
    @State private var moved = false
    @State private var lastTap: Date = .distantPast

    private let tapThreshold: CGFloat = 8
    private let doubleTapInterval: TimeInterval = 0.32

    var body: some View {
        VStack(spacing: 2) {
            Text("滚轮")
                .font(.subheadline.weight(.medium))
            // 滚轮键只有 2/8 宽度，副标题改成两行，避免被压成看不清的小字。
            Text("拖动滚动\n双击按下")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDragging ? Color.accentColor.opacity(0.85)
                               : Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(isDragging ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        lastY = 0
                        residual = 0
                        moved = false
                    }
                    let step = value.translation.height - lastY
                    lastY = value.translation.height
                    if abs(value.translation.height) > tapThreshold ||
                        abs(value.translation.width) > tapThreshold {
                        moved = true
                    }
                    // 默认上滑 = 滚轮下滑；与触控区双指滚动共用倍率、方向和自然滚动开关。
                    let scale = CGFloat(hid.scrollSensitivity) / 4.0
                    let direction: CGFloat = hid.naturalScrolling ? -1 : 1
                    let raw = step * scale * direction + residual
                    let delta = Int(raw.rounded(.toNearestOrAwayFromZero))
                    residual = raw - CGFloat(delta)
                    if delta != 0 { hid.enqueue(wheel: delta) }
                }
                .onEnded { _ in
                    isDragging = false
                    lastY = 0
                    residual = 0
                    if !moved { registerTap() }
                }
        )
    }

    private func registerTap() {
        let now = Date()
        if now.timeIntervalSince(lastTap) < doubleTapInterval {
            lastTap = .distantPast
            hid.click(0x04)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            lastTap = now
        }
    }
}

// MARK: - 主动断开

/// 仅在已连接时出现在顶部工具栏。断开后保持停止广播，让用户决定何时重新广播，
/// 避免 iPad 立刻自动重连；点「开始广播」即可让 Windows / Mac 等其他主机发现。
/// onDisconnected 由父视图传入，用来弹出「切换设备」指引（alert 必须挂在常驻视图上，
/// 因为本按钮在断开后随 toolbar 一起被移除）。
private struct DisconnectButton: View {

    @EnvironmentObject private var hid: HIDPeripheral
    var onDisconnected: () -> Void

    var body: some View {
        Button("断开") {
            hid.disconnect()
            onDisconnected()
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .accessibilityLabel("断开当前连接")
    }
}
