import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @State private var showSettings = false
    /// 键鼠宏管理（录制 / 编辑 / 回放）。
    @State private var showMacros = false
    /// true = 全键盘，false = 触控板。只在已连接时生效，断开自动回到触控板。
    @State private var showKeyboard = false
    /// 连接日志「复制全部」后的短暂反馈。
    @State private var logsCopied = false

    /// 主机订阅了 Input Report（BLE），或 ESP32 硬件桥已连上，都算真正连上。
    private var connected: Bool { hid.isLinkActive }

    /// 跳到系统「设置」首页。私有蓝牙 scheme（App-Prefs:Bluetooth 等）在真机上
    /// 始终进不去蓝牙页，最可靠的是 public API 直接开系统设置首页，用户自己点蓝牙。
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// 把全部连接日志（内存里最多 80 行）复制到剪贴板，供用户粘贴发回排障。
    private func copyAllLogs() {
        let text = hid.logLines.joined(separator: "\n")
        UIPasteboard.general.string = text
        logsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.logsCopied = false
        }
    }

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
                        // 连接诊断常驻细条：连上后也能看到协议/订阅/发送状态，
                        // 便于「连上却动不了」时一眼定位卡点（可点按切换展开）。
                        DiagnosticStrip()
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
            .navigationTitle(connected ? "PT-Pad · \(hid.connectedDeviceName)" : "按键精灵")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button {
                            showMacros = true
                        } label: {
                            Image(systemName: hid.isRecording ? "record.circle.fill" : "record.circle")
                                .font(.footnote)
                                .foregroundStyle(hid.isRecording ? Color.red : Color.accentColor)
                        }
                        .controlSize(.mini)
                        .accessibilityLabel("键鼠宏")
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.footnote)
                        }
                        .controlSize(.mini)
                        .accessibilityLabel("设置")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if connected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        // 两行紧凑显示：状态 + 对端设备名。权限所限只能显示连接来源
                        // （iPad / Windows 电脑 / 桥接 IP），读不到对端蓝牙设备名。
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("已连接")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(hid.connectedDeviceName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // 「断开连接」从设置页移回主界面，占据原「断开」按钮位置。
                        // 只干净地断开（拆 GATT、停广播），不再自动重播，也不再拆链避让；
                        // 断开后右上角变成「开始广播」，用户明确点它才重建并广播。
                        Button("断开连接") {
                            hid.selectNewDevice()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("断开当前连接")
                    } else {
                        // 只保留「开始 / 连接」入口。断开与停止广播实测会被系统自动回连 /
                        // 自动恢复广播抵消，没有实际意义，故从工具栏移除。
                        if hid.bridgeMode {
                            Button { hid.startBridge() } label: {
                                Text("连接桥接").font(.caption2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        } else {
                            // 正在广播但未连上点时，点它可重启广播（不会停止）。
                            Button { hid.start() } label: {
                                Text("开始广播").font(.caption2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    // 蓝牙入口：黑色椭圆胶囊 + 蓝色「蓝牙」字，一键跳系统设置首页。
                    Button { openSystemSettings() } label: {
                        Text("蓝牙")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.blue)
                            .frame(width: 34, height: 22)
                            .background(Capsule().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开系统设置")
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showMacros) {
                NavigationStack {
                    MacroListView()
                }
                // 宏面板上移：占屏幕 90%，顶边盖住主界面的「触控区 / 全键盘」切换栏，
                // 便于录制/编辑时尽量少滚动；仍露出最顶部导航条，且可下拉关闭。
                .presentationDetents([.fraction(0.90)])
                .interactiveDismissDisabled(false)
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
                    if hid.bridgeMode {
                        Text("桥接模式：iPhone 只采集输入，经 WiFi 发给 ESP32 硬件桥。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("手机连上 ESP32 的 PT-Bridge 热点，地址填 192.168.4.1，点「连接桥接」；"
                         + "再到电脑 / 平板的系统蓝牙里配对 PT-Pad，电脑端无需安装任何软件。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("iPad 上打开 设置 > 蓝牙，在「其他设备」里选择你的 iPhone（可能显示为 PT-Pad）完成配对。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("用右上角的「开始广播」启动蓝牙；连接成功后会自动出现全屏触控区。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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

                // 连接日志：顶部放实时诊断行，方便一眼看出「连上却动不了」卡在哪。
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("连接日志 · 连接诊断")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { copyAllLogs() } label: {
                            Label(logsCopied ? "已复制" : "复制全部",
                                  systemImage: logsCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("复制全部连接日志")
                    }
                    Text(hid.diagnosticText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 6))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(hid.logLines.suffix(30), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
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
    @EnvironmentObject private var clicks: KeyClickPlayer
    @EnvironmentObject private var haptics: HapticPlayer

    /// 桥接端地址：初次进入时从 BridgeTransport 读回已保存的值。
    @State private var bridgeHost: String = ""
    @State private var bridgePort: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用桥接（WiFi 转发）", isOn: $hid.bridgeMode)

                VStack(alignment: .leading, spacing: 6) {
                    Text("桥接端地址")
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        TextField("192.168.1.100", text: $bridgeHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity)
                            .onSubmit { applyBridgeTarget() }
                        TextField("5000", text: $bridgePort)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 68)
                            .onSubmit { applyBridgeTarget() }
                    }
                    Button("保存地址", action: applyBridgeTarget)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                    Button {
                        hid.resendBridgeHello()
                    } label: {
                        Label("重新握手", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                LabeledRow(title: "当前状态", detail: hid.bridge.statusText)
                LabeledRow(title: "ESP32 热点", detail: "PT-Bridge（无密码）")
            } header: {
                Text("桥接（ESP32 硬件桥 · 电脑零安装）")
            } footer: {
                Text("iOS 的蓝牙外设无法设置 GAP Appearance，Windows 因此很难直接搜到本机虚拟键鼠。开启桥接后本机不再广播，改为把输入通过 WiFi 发给 ESP32，由 ESP32 以标准蓝牙键鼠身份连接电脑，电脑端不用装任何软件。\n\n【步骤】① ESP32 上电，手机连上它的 PT-Bridge 热点；② 上面地址保持默认 192.168.4.1，点「保存地址」再点右上角「连接桥接」；③ 电脑 / 平板打开系统蓝牙，搜索并配对 PT-Pad，配对一次以后自动连接。\n\n电脑端唯一的硬件要求是自带蓝牙；配对一次后，以后 ESP32 一上电就会自动连上。")
                    .font(.caption)
            }

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
                Text("默认：向上滑 = 滚轮下滑。打开自然滚动后方向整体反转（跟手）。两种滚动入口：触摸板右侧竖条滚轮（在竖条上上下滑动）、底部滚轮键。双指已改为拖拽（需滑动超过 8pt 才按下左键，轻点不会拖动图标）。设置会自动保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("按键音") {
                Toggle("启用按键音", isOn: $clicks.isEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("音量")
                        Spacer()
                        Text(clicks.levelText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $clicks.volume, in: 0...1, step: 0.05)
                }
                Button {
                    clicks.preview()
                } label: {
                    Label("试听", systemImage: "speaker.wave.2.fill")
                }
                Text("虚拟键盘每次按键都会响一声机械键盘音；底部左键 / 右键 / 滚轮键同样有反馈音。音量 0 即静音。键盘页工具条的喇叭按钮可在 静音 / 25% / 50% / 100% 之间快速切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("按键振动") {
                Toggle("启用振动反馈", isOn: $haptics.isEnabled)
                Picker("振动强弱", selection: $haptics.strength) {
                    ForEach(HapticPlayer.Strength.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!haptics.isEnabled)
                Button {
                    haptics.preview()
                } label: {
                    Label("试振", systemImage: "waveform")
                }
                Text("按键、底部鼠标键、触控区轻点 / 双击都会在 iPhone 本机产生振动反馈，强弱分弱 / 中 / 强三档。振动只在 iPhone 上反馈，不会传给被控制的 iPad / 电脑；iOS 需系统振动功能开启（静音键不影响振动）。")
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
                LabeledRow(title: "三指上滑", detail: "最小化 / 回桌面（Command + M）")
                LabeledRow(title: "三指左右滑", detail: "切换 App（Cmd+Tab / Cmd+Shift+Tab）")
                LabeledRow(title: "全键盘", detail: "两页键位 + 下方小触控区（可移动指针）")
                LabeledRow(title: "输入报告",
                           detail: hid.compositeDevice ? "12 字节（键盘 8 + 鼠标 4）" : "4 字节（纯鼠标）")
            } header: {
                Text("实验功能 · 全键盘与手势")
            } footer: {
                Text("开启后本设备同时声明为鼠标和键盘，全键盘、三指手势都依赖这个开关。三指上滑最小化当前程序 / 回桌面（Command+M，App 保留后台不关闭），三指左右滑切换 App（右滑 Cmd+Tab 下一个 / 左滑 Cmd+Shift+Tab 上一个）——iPadOS 原生多指手势只对妙控板 2 私有协议开放，本 App 是把三指手势转成键盘快捷键的模拟实现。切换开关会自动断开并移除 GATT 服务：请按「\(HIDSpec.ipadIgnorePath)」忽略，回到主页面点「开始广播」，再重新配对。若指针或点击失效，关掉本开关、同样忽略设备重新配对即可回到纯鼠标，不需要重装 App。Command 快捷键只对 iPadOS 有效。")
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
                Text("【为什么 iPad 蓝牙列表里找不到本设备？】本 App 让 iPhone 以「蓝牙 HID 键鼠」身份连接 iPad。iPadOS 把 HID 键鼠当系统输入设备，归到「辅助触控」框架管理，不列在「设置 → 蓝牙 → 我的设备」里——这是系统行为，不是没连上。能正常使用恰好证明连接是好的。\n\n【怎么断开 / 忽略？】① 最快：点主界面右上角「断开连接」——干净地拆掉当前连接并停广播，右上角随即变成「开始广播」，点它才重新广播；旁边的蓝牙图标可一键跳系统蓝牙设置。② 彻底忽略 / 换设备 / 刷新配对缓存：\(HIDSpec.ipadIgnorePath)。注意不在蓝牙列表里，那里找不到。③ 若还想清得更干净：最后再去做 iPad 设置 → 通用 → 传输或还原 iPad → 还原 → 还原网络设置（会同时清掉 WiFi 密码，需重输）。\n\n【为什么显示 iPhone 名而不是 PT-Pad？】iPad 读的是对端 GAP 整机名，App 无权改写；广播名 PT-Pad 只在搜索时短暂出现。要让它好认，可把 iPhone 名称改成「按键精灵」，再到「辅助触控 → 设备」里忽略旧配对重连一次。")
                    .font(.caption)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入设置页时把已保存的桥接端地址回填到输入框。
            if bridgeHost.isEmpty {
                bridgeHost = hid.bridge.currentHost
                bridgePort = String(hid.bridge.currentPort)
            }
        }
    }

    /// 把输入框里的地址写回桥接传输层（正在连接时会自动按新地址重连）。
    private func applyBridgeTarget() {
        hid.setBridgeTarget(host: bridgeHost, port: bridgePort)
        bridgeHost = hid.bridge.currentHost
        bridgePort = String(hid.bridge.currentPort)
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
            Text("触控区")
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

/// 连接诊断常驻细条：触摸区顶部一行小字显示协议 / 订阅 / 发送状态。
/// 「连上却动不了」时用它一眼区分是协议模式、订阅还是发送阻塞的问题。
private struct DiagnosticStrip: View {
    @EnvironmentObject private var hid: HIDPeripheral
    @State private var expanded = false

    private var hasProblem: Bool { hid.hasConnectionProblem }
    /// 复合报告在部分 iPadOS 上会被当键盘接管、忽略鼠标位移。给一键切纯鼠标入口。
    private var canOfferPlainMouse: Bool { hid.compositeDevice && !hid.bridgeMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(hasProblem ? Color.orange : Color.green)
                    Text(hid.diagnosticText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(hasProblem ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if canOfferPlainMouse {
                    Text("iPad 连上却完全没反应？复合 12 字节可能被当成键盘忽略鼠标。切到纯鼠标后再按「\(HIDSpec.ipadIgnorePath)」忽略并重新配对。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        hid.switchToPlainMouse()
                    } label: {
                        Text("一键切到纯鼠标模式")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Text("当前已是纯鼠标 / 其他模式，无需切换。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hasProblem ? Color.orange.opacity(0.10) : Color(.secondarySystemBackground))
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
    @EnvironmentObject private var clicks: KeyClickPlayer
    @EnvironmentObject private var haptics: HapticPlayer
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
                        clicks.play()
                        haptics.play()
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
    @EnvironmentObject private var clicks: KeyClickPlayer
    @EnvironmentObject private var haptics: HapticPlayer

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
                    // 默认上滑 = 滚轮下滑；倍率、方向和自然滚动开关只作用于这个滚轮键（双指已改为拖拽）。
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
            clicks.play()
            haptics.play()
        } else {
            lastTap = now
        }
    }
}

// MARK: - 主动断开（已并入顶部工具栏，见 ContentView.body 的 toolbar）

