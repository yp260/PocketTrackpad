import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var hid: HIDPeripheral

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {

                    // 状态卡片
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill(hid.subscribers > 0 ? Color.green
                                      : (hid.isAdvertising ? Color.orange : Color.gray))
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

                        HStack(spacing: 10) {
                            Button {
                                hid.isAdvertising ? hid.stopAdvertising() : hid.start()
                            } label: {
                                Text(hid.isAdvertising ? "停止广播" : "开始广播")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("重新广播") {
                                hid.stopAdvertising()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    hid.start()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // 触控区
                    TrackpadSurface()
                        .frame(height: 300)
                        .overlay(alignment: .topLeading) {
                            Text("触控区")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(10)
                        }

                    // 实体按键
                    HStack(spacing: 10) {
                        HoldButton(title: "左键", mask: 0x01)
                        HoldButton(title: "中键", mask: 0x04)
                        HoldButton(title: "右键", mask: 0x02)
                    }
                    .frame(height: 52)

                    // 参数
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("指针速度")
                                Spacer()
                                Text(String(format: "%.1f×", hid.sensitivity))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $hid.sensitivity, in: 0.4...3.5, step: 0.1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("滚动速度")
                                Spacer()
                                Text(String(format: "%.1f×", hid.scrollSensitivity))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $hid.scrollSensitivity, in: 0.3...3.0, step: 0.1)
                        }
                        Toggle("自然滚动", isOn: $hid.naturalScrolling)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    // 日志
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
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    Text("请保持本 App 在前台、屏幕常亮。锁屏或切到后台后 iOS 会停止 BLE 广播。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .navigationTitle("口袋触控板")
            .navigationBarTitleDisplayMode(.inline)
        }
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
