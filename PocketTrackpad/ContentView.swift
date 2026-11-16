import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @State private var showSettings = false
    /// 键鼠宏管理（录制 / 编辑 / 回放）。
    @State private var showMacros = false
    /// true = 全键盘，false = 触控板。只在已连接时生效，断开自动回到触控板。
    @State private var showKeyboard = false
    /// 断开后弹出「切换设备」指引（配对信息在主机侧，iPad 会自动回连）。
    @State private var showSwitchHelp = false

    /// 主机订阅了 Input Report（BLE），或桥接端已连上（ESP32 / Windows 电脑接收器），都算真正连上。
    private var connected: Bool { hid.isLinkActive }

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
                        Button("断开") {
                            if hid.bridgeMode {
                                hid.disconnectBridge()
                            } else {
                                hid.disconnect()
                                showSwitchHelp = true
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("断开当前连接")
                    }
                    Button {
                        if hid.bridgeMode {
                            if hid.bridgeActive { hid.disconnectBridge() } else { hid.startBridge() }
                        } else {
                            if hid.isAdvertising {
                                hid.stopAdvertising()
                            } else if hid.selectNewDeviceMode {
                                hid.selectNewDevice()
                            } else {
                                hid.start()
                            }
                        }
                    } label: {
                        if hid.bridgeMode {
                            Text(hid.bridgeActive ? "断开桥接" : "连接桥接")
                                .font(.caption2)
                        } else {
                            Text(hid.isAdvertising ? "停止广播" : "开始广播")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showMacros) {
                NavigationStack {
                    MacroListView()
                }
            }
            .alert("已断开 · 连接哪台设备？", isPresented: $showSwitchHelp) {
                Button("选择新设备（跳过上次）") {
                    hid.selectNewDevice()
                }
                Button("普通开始广播") {
                    hid.start()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「选择新设备」会跳过上次连接的设备：若它自动回连，App 会立刻断开让位，给你用新设备（Windows / Android / 另一台 iPad）连接的机会。\n\n但 iOS 系统限制：App 无法清除主机侧的配对，已配对设备由系统自动回连，App 只能「连上就拆」最多 3 次。要彻底不再被它抢连，必须在旧设备蓝牙设置里「忽略此设备」。注意：在 iPad 蓝牙列表里找的不是 PT-Pad，而是你 iPhone 的名字（设置 > 通用 > 关于本机 > 名称），点它旁边的 ⓘ 就能断开或忽略。\n\nWindows（推荐 · 零安装）：设置里开「Windows 直连」，打开 Windows 的 设置 → 蓝牙 → 添加设备 → 其他设备 窗口，再点「选择新设备」，列表出现 iPhone 后配对。搜不到就在 Windows 蓝牙高级设置把发现改为「高级」或点「显示所有设备」。若仍不兼容，改用「桥接（WiFi 转发）」+ 电脑端 windows\\pt_receiver.ps1（零安装）。")
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
                        Text("桥接模式：iPhone 只采集输入，经 WiFi 发给桥接端。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("连 Windows：电脑上用系统自带 PowerShell 运行 windows\\pt_receiver.ps1（零安装），"
                         + "再到设置里把地址填成电脑的局域网 IP；"
                         + "连 Android / 无线方案：手机连 ESP32 的 PT-Bridge 热点，地址用 192.168.4.1。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if hid.windowsMode {
                        // 醒目提醒：Windows 直连用双报告拓扑，iPad 连不上。给一键切回入口。
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("当前是 Windows 直连模式，iPad 会连不上")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.orange)
                            Text("Windows 模式用专用双报告格式，iPad 读不懂、订阅为 0。要连 iPad 请先切回，本按钮会自动重建 GATT 并重新广播。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                hid.switchToiPadMode()
                            } label: {
                                Text("一键切回 iPad 模式")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                        Text("Windows 打开 设置 → 蓝牙和其他设备 → 添加设备 → 其他设备，保持窗口开着。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("本 App 点「开始广播」后，Windows 列表会出现你的 iPhone，点它直接配对，电脑端零安装。")
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
                    Text("连接日志 · 连接诊断")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                LabeledRow(title: "三指上滑", detail: "回桌面（Command + H）")
                LabeledRow(title: "全键盘", detail: "两页键位 + 下方小触控区（可移动指针）")
                LabeledRow(title: "输入报告",
                           detail: hid.compositeDevice ? "12 字节（键盘 8 + 鼠标 4）" : "4 字节（纯鼠标）")
            } header: {
                Text("实验功能 · 全键盘与回桌面")
            } footer: {
                Text("开启后本设备同时声明为鼠标和键盘，全键盘与三指上滑都依赖这个开关。iPad 可能弹出键盘配对验证，也可能拒绝接管整个设备导致鼠标失效。切换开关会自动断开并移除 GATT 服务：请在 iPad 蓝牙里「忽略此设备」，回到主页面点「开始广播」，再重新配对。若指针或点击失效，关掉本开关、同样忽略设备重新配对即可回到纯鼠标，不需要重装 App。Command + H 只对 iPadOS 有效；Windows 显示桌面是 Win + D，macOS 是 F11。")
                    .font(.caption)
            }

            Section {
                Toggle("Windows 直连（电脑零安装）", isOn: $hid.windowsMode)
                LabeledRow(title: "电脑端要求", detail: "不装任何软件")
                LabeledRow(title: "设备显示", detail: "iPhone 整机名")
                LabeledRow(title: "当前状态", detail: hid.windowsMode ? "广播中（等 Windows 添加）" : "未启用")
            } header: {
                Text("连接 Windows（推荐 · 零安装）")
            } footer: {
                Text("开启后 iPhone 以标准 BLE 键鼠组合设备身份广播，Windows 在 设置 → 蓝牙和其他设备 → 添加设备 → 其他设备 里直接配对，电脑端不装任何驱动或程序。\n\n步骤：① 本 App 先断开 iPad（iOS 外设被连接后会停止广播，Windows 搜不到）；② 在 Windows 打开添加设备窗口并保持；③ 本 App 点「开始广播」，过几秒 Windows 列表出现你的 iPhone，点它配对。\n\n注意：Windows 11 24H2 的发现列表会按设备类别（Appearance）过滤，iOS 无法在广播里设置该字段。若列表不显示，先在 Windows 蓝牙高级设置里打开「蓝牙设备发现：高级」，或在添加设备页点击「显示所有设备」。配对成功后在 Windows 里即可用 iPhone 当触控板 + 键盘。若仍连不上，关掉本开关改用下方「桥接」方案。")
                    .font(.caption)
            }

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
                LabeledRow(title: "电脑端程序", detail: "windows/pt_receiver.ps1")
                LabeledRow(title: "ESP32 热点", detail: "PT-Bridge（无密码）")
            } header: {
                Text("桥接（连 Windows / Android）")
            } footer: {
                Text("iOS 的蓝牙外设无法设置 GAP Appearance，Windows 因此搜不到本机虚拟键鼠。开启桥接后本机不再广播，改为把输入通过 WiFi 发给「桥接端」。\n\n【连 Windows，零安装】用系统自带 PowerShell 运行 windows\\pt_receiver.ps1（双击 start_receiver.bat 即可），把上面地址填成电脑的局域网 IP（Windows 用 ipconfig 查看，格式如 192.168.1.100），点「保存地址」再点右上角「连接桥接」。\n\n【连 Android / 也想无线】用 ESP32：手机先连 PT-Bridge 热点，地址填默认的 192.168.4.1。\n\n手机与电脑必须连同一个 WiFi。Windows 防火墙首次会询问是否允许访问网络，选「允许」。\n\n提示：若你的 Windows 版本能直接搜到 iPhone，请优先用「Windows 直连（电脑零安装）」开关，连软件都不用开。")
                    .font(.caption)
            }

            Section {
                Button {
                    hid.selectNewDevice()
                } label: {
                    Label("选择新设备（跳过上次设备）", systemImage: "arrow.triangle.2.circlepath")
                }
                Toggle("开始广播时避开上次设备", isOn: $hid.selectNewDeviceMode)
            } header: {
                Text("切换设备")
            } footer: {
                Text("「选择新设备」会断开当前连接并重新广播，本轮跳过上次连过的设备：若它自动回连，App 会立刻拆链让位（最多 3 次），给你连接新设备的机会。开关打开后，每次点「开始广播」都自动跳过上次设备。\n\n【系统限制】蓝牙 HID 的配对信息存在主机侧，iOS 外设无法远程解除、也无法拒绝指定设备连接——已配对设备由系统自动回连，App 只能「连上就拆」。要彻底不被旧设备抢连，必须在旧设备蓝牙设置里「忽略此设备」。\n\nWindows（推荐 · 零安装）：打开「Windows 直连」，保持 Windows 的 设置 → 蓝牙 → 添加设备 → 其他设备 窗口，再点「选择新设备」，列表出现 iPhone 后配对。Windows 11（24H2）发现列表按类别过滤、iOS 无法设置该字段，若列表不显示，开「蓝牙设备发现：高级」或点「显示所有设备」。仍不兼容就改用「桥接（WiFi 转发）」+ 电脑端 windows\\pt_receiver.ps1（零安装）。")
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
                Text("【为什么 iPad 蓝牙列表里找不到本设备？】本 App 让 iPhone 以「蓝牙 HID 键鼠」身份连接 iPad。iPadOS 把 HID 键鼠当系统输入设备，配对后大部分版本不会像耳机那样列在「我的设备」里供你点 ⓘ 断开/忽略——这是系统行为，不是没连上。能正常使用恰好证明连接是好的。\n\n【怎么断开 / 忽略？】① 最快：直接点本 App 顶部「断开」即可断开，无需去 iPad。② 若 iPad 列表里以「iPhone 的名字」出现（设置 → 通用 → 关于本机 → 名称，不是 PT-Pad），点它旁边 ⓘ → 忽略此设备。③ 完全找不到、且想彻底清掉配对：iPad 设置 → 通用 → 传输或还原 iPad → 还原 → 还原网络设置（会同时清掉 WiFi 密码，需重输）。\n\n【为什么显示 iPhone 名而不是 PT-Pad？】iPad 列表读的是对端 GAP 整机名，App 无权改写；广播名 PT-Pad 只在「其他设备」搜索列表里短暂出现。要让它好认，可把 iPhone 名称改成「按键精灵」，再到 iPad 忽略旧配对重连一次。")
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

/// 连接诊断常驻细条：触摸区顶部一行小字显示协议 / 订阅 / 发送状态。
/// 「连上却动不了」时用它一眼区分是协议模式、订阅还是发送阻塞的问题。
private struct DiagnosticStrip: View {
    @EnvironmentObject private var hid: HIDPeripheral

    private var hasProblem: Bool { hid.hasConnectionProblem }

    var body: some View {
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
            clicks.play()
            haptics.play()
        } else {
            lastTap = now
        }
    }
}

// MARK: - 主动断开（已并入顶部工具栏，见 ContentView.body 的 toolbar）

