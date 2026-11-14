import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @State private var showSettings = false

    /// 主机订阅了 Input Report 才算真正连上；仅广播中不算连接。
    private var connected: Bool { hid.subscribers > 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if connected {
                    // 已连接：触控区吃掉顶部栏与底部按键条之间的全部空间。
                    TrackpadSurface(edgeToEdge: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .horizontal)
                } else {
                    setupBody
                }
                ButtonBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .padding(14)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                // 连接日志
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
                    }
                    .frame(height: 108)
                }
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
                Text("同时作用于双指滚动和底部滚轮键。设置会自动保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("按键") {
                LabeledRow(title: "左键 / 右键", detail: "按住 = 按下，松手 = 抬起")
                LabeledRow(title: "滚轮", detail: "上下拖动 = 滚动，双击 = 按下滚轮键")
                LabeledRow(title: "触控区", detail: "轻点左键 · 双击左键 · 长按右键")
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

// MARK: - 底部按键条

/// 固定在屏幕最底部，不随引导页滚动，也不随连接状态切换。
private struct ButtonBar: View {
    var body: some View {
        HStack(spacing: 10) {
            HoldButton(title: "左键", mask: 0x01)
            WheelButton()
            HoldButton(title: "右键", mask: 0x02)
        }
        .frame(height: 58)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
            Text("拖动滚动 · 双击按下")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
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
                    // 与触控区双指滚动使用同一套倍率和方向定义。
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
