import SwiftUI
import UIKit

// MARK: - HID 键码解析
//
// 虚拟键盘发送的永远是 USB HID Keyboard/Keypad Page (0x07) 的键码，
// 不是字符本身。大小写、上档符号由 modifier 字节里的 Left Shift 位决定，
// 所以「A」= 0x04 + Shift，「!」= 0x1E + Shift。
// 所有键码都必须落在 Report Map 声明的 Usage Maximum = 101 (0x65) 内。

enum HIDKeycode {

    static let shift: UInt8 = HIDSpec.modLeftShift

    /// 功能键标签 -> HID 键码。
    static let named: [String: UInt8] = [
        "Esc": 0x29, "⌫": 0x2A, "Tab": 0x2B, "Space": 0x2C, "⏎": 0x28,
        "Caps": 0x39, "Ins": 0x49, "Home": 0x4A, "PgUp": 0x4B, "Del": 0x4C,
        "End": 0x4D, "PgDn": 0x4E, "Menu": 0x65,
        "←": 0x50, "→": 0x4F, "↑": 0x52, "↓": 0x51,
        "PrtSc": 0x46, "ScrLk": 0x47, "Pause": 0x48,
        "F1": 0x3A, "F2": 0x3B, "F3": 0x3C, "F4": 0x3D,
        "F5": 0x3E, "F6": 0x3F, "F7": 0x40, "F8": 0x41,
        "F9": 0x42, "F10": 0x43, "F11": 0x44, "F12": 0x45
    ]

    /// US ANSI 布局：把一个可打印字符解析成 (键码, 自带修饰键)。
    static func resolve(_ label: String) -> (keycode: UInt8, modifier: UInt8)? {
        if let code = named[label] { return (code, 0) }
        guard label.count == 1,
              let scalar = label.first?.unicodeScalars.first?.value,
              scalar < 128 else { return nil }
        let c = UInt8(scalar)
        if c >= 97 && c <= 122 { return (c - 97 + 0x04, 0) }        // a...z
        if c >= 65 && c <= 90  { return (c - 65 + 0x04, shift) }     // A...Z
        if c >= 49 && c <= 57  { return (c - 49 + 0x1E, 0) }         // 1...9
        if c == 48             { return (0x27, 0) }                   // 0
        switch c {
        case 32: return (0x2C, 0)          // 空格
        case 33: return (0x1E, shift)      // !
        case 34: return (0x34, shift)      // "
        case 35: return (0x20, shift)      // #
        case 36: return (0x21, shift)      // $
        case 37: return (0x22, shift)      // %
        case 38: return (0x24, shift)      // &
        case 39: return (0x34, 0)          // '
        case 40: return (0x26, shift)      // (
        case 41: return (0x27, shift)      // )
        case 42: return (0x25, shift)      // *
        case 43: return (0x2E, shift)      // +
        case 44: return (0x36, 0)          // ,
        case 45: return (0x2D, 0)          // -
        case 46: return (0x37, 0)          // .
        case 47: return (0x38, 0)          // /
        case 58: return (0x33, shift)      // :
        case 59: return (0x33, 0)          // ;
        case 60: return (0x36, shift)      // <
        case 61: return (0x2E, 0)          // =
        case 62: return (0x37, shift)      // >
        case 63: return (0x38, shift)      // ?
        case 64: return (0x1F, shift)      // @
        case 91: return (0x2F, 0)          // [
        case 92: return (0x31, 0)          // 反斜杠
        case 93: return (0x30, 0)          // ]
        case 94: return (0x23, shift)      // ^
        case 95: return (0x2D, shift)      // _
        case 96: return (0x35, 0)          // `
        case 123: return (0x2F, shift)     // {
        case 124: return (0x31, shift)     // |
        case 125: return (0x30, shift)     // }
        case 126: return (0x35, shift)     // ~
        default: return nil
        }
    }
}

// MARK: - 键盘页与布局

/// 两页布局：F1~F12、方向键与常用导航键已并入主键位，不再单独占用「功能」页。
/// 低频功能键收纳到符号页最后一行，所有键码一个不丢。
enum KeyboardPage: String, CaseIterable, Identifiable {
    case letters = "主键位"
    case symbols = "符号"
    var id: String { rawValue }
}

struct KeyDef: Equatable {
    enum Role: Equatable {
        case key(keycode: UInt8, modifier: UInt8)
        case sticky(mask: UInt8)
        case clear
        case spacer
    }

    let label: String
    let role: Role
    let weight: CGFloat
    let prominent: Bool

    static func key(_ label: String, weight: CGFloat = 1,
                    prominent: Bool = false) -> KeyDef? {
        guard let r = HIDKeycode.resolve(label) else { return nil }
        return KeyDef(label: label,
                      role: .key(keycode: r.keycode, modifier: r.modifier),
                      weight: weight, prominent: prominent)
    }

    static func function(_ label: String, weight: CGFloat = 1) -> KeyDef? {
        key(label, weight: weight, prominent: true)
    }

    static func sticky(_ label: String, mask: UInt8,
                       weight: CGFloat = 1) -> KeyDef {
        KeyDef(label: label, role: .sticky(mask: mask),
               weight: weight, prominent: true)
    }

    static func clear(_ label: String = "清除", weight: CGFloat = 1) -> KeyDef {
        KeyDef(label: label, role: .clear, weight: weight, prominent: true)
    }

    static func spacer(_ weight: CGFloat) -> KeyDef {
        KeyDef(label: "", role: .spacer, weight: weight, prominent: false)
    }
}

enum KeyboardLayout {

    private static func line(_ chars: String) -> [KeyDef] {
        chars.compactMap { KeyDef.key(String($0)) }
    }

    /// 字母行：键帽显示大写（与 iOS 键盘一致），但发送小写键码。
    /// 需要大写字母时由粘滞 Shift 提供 modifier，和真实键盘行为一致；
    /// 若直接用大写字符解析，每个字母都会自带 Shift，打出来全是大写。
    private static func letters(_ chars: String) -> [KeyDef] {
        chars.compactMap { ch -> KeyDef? in
            guard let def = KeyDef.key(String(ch).lowercased()) else { return nil }
            return KeyDef(label: String(ch).uppercased(), role: def.role,
                          weight: def.weight, prominent: def.prominent)
        }
    }

    private static func functionLine(_ labels: [String]) -> [KeyDef] {
        labels.compactMap { KeyDef.function($0) }
    }

    /// 常驻控制行：四个粘滞修饰键 + 空格 + 退格 + 回车。
    private static var controlRow: [KeyDef] {
        var row: [KeyDef] = [
            .sticky("Ctrl", mask: HIDSpec.modLeftControl),
            .sticky("Opt", mask: HIDSpec.modLeftAlt),
            .sticky("Cmd", mask: HIDSpec.modLeftGUI),
            .sticky("⇧", mask: HIDSpec.modLeftShift)
        ]
        if let space = KeyDef.key("Space", weight: 2.6) { row.append(space) }
        if let back = KeyDef.function("⌫", weight: 1.2) { row.append(back) }
        if let enter = KeyDef.function("⏎", weight: 1.2) { row.append(enter) }
        return row
    }

    /// 主键位 7 行：顶部一整行 F1~F12，字母区下方一行导航键与四向方向键。
    /// 两页统一 42pt 键帽，7 行主键位靠收紧行距容纳 F1~F12。
    static func rows(for page: KeyboardPage) -> [[KeyDef]] {
        switch page {
        case .letters:
            return [
                functionLine(["F1", "F2", "F3", "F4", "F5", "F6",
                              "F7", "F8", "F9", "F10", "F11", "F12"]),
                line("1234567890"),
                letters("QWERTYUIOP"),
                [.spacer(0.5)] + letters("ASDFGHJKL") + [.spacer(0.5)],
                // Esc / ↑ 顶掉原来的左右空白，分别贴住键区左右边缘。
                functionLine(["Esc"]) + letters("ZXCVBNM") + functionLine(["↑"]),
                functionLine(["Tab", "Caps", "Del", "Home", "End",
                              "←", "↓", "→"]),
                controlRow
            ]
        case .symbols:
            return [
                line("!@#$%^&*()"),
                line("`-=[]\\;',./"),
                line("~_+{}|:\"<>?"),
                functionLine(["Ins", "PrtSc", "ScrLk", "Pause",
                              "PgUp", "PgDn", "Menu"]),
                controlRow
            ]
        }
    }
}

// MARK: - 全键盘面板

/// 由触控区顶部的「全键盘」按钮切换进来。顶部工具条负责返回触控板与切换键盘页，
/// 底部三键（左键 / 滚轮 / 右键）由 ContentView 常驻保留，打字时仍可点按。
struct KeyboardPanel: View {

    @EnvironmentObject private var hid: HIDPeripheral
    @EnvironmentObject private var clicks: KeyClickPlayer
    @EnvironmentObject private var haptics: HapticPlayer
    @Binding var showKeyboard: Bool

    @State private var page: KeyboardPage = .letters
    /// 一次性粘滞修饰键位图：点一下亮起，随下一次普通键一起发出后自动清零。
    @State private var sticky: UInt8 = 0

    var body: some View {
        let rows = KeyboardLayout.rows(for: page)
        // 主键位合并后 7 行、符号页 5 行，两页统一 42pt：既放得下 7 行，
        // 又接近系统建议的 44pt 触控高度，切页时键帽不会忽大忽小。
        let rowHeight: CGFloat = 42
        return VStack(spacing: 0) {
            toolbar
            if !hid.keyboardReady { warning }
            // 工具条下方不再单独留一行空状态条：粘滞状态并入工具条右侧的短徽标，
            // 键区直接顶到工具条下沿，省下的高度全部交给下方小触控区。
            VStack(spacing: 6) {
                // 用整数索引而不是 enumerated() 元组：后者配 id: \.offset
                // 在部分 Swift 版本会报「key path 不能指向元组元素」。
                ForEach(0..<rows.count, id: \.self) { i in
                    KeyRow(keys: rows[i], sticky: sticky, height: rowHeight, tap: handle)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            imeHint
            miniTrackpad
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 键盘下方的小范围触控区：吃掉键区以下的全部空间，紧贴键区。
    /// 复用 TrackpadSurface，手势与全屏触控板完全一致；compact 下不显示任何提示文字。
    private var miniTrackpad: some View {
        TrackpadSurface(compact: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
    }

    /// 选词提示（v0.0.18 改写）：本版把键盘 Collection 排到描述符最前、补齐
    /// Boot Keyboard 特征与 Appearance，目标是让 iPad 把本设备当实体键盘——
    /// 屏幕软键盘隐藏、候选词带数字，1-9 / 空格直接选词。
    /// 若 iPad 仍显示软键盘（未识别为键盘），退回小触控区点顶部候选条。
    /// 提示只一行、次级色，不打断键区布局。
    private var imeHint: some View {
        Text("选词：iPad 隐藏屏幕键盘后，按 1-9 / 空格即可选词；若仍显示软键盘，用小触控区点顶部候选条")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 2)
    }

    // MARK: 顶部工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                showKeyboard = false
            } label: {
                Label("触控板", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("返回触控板")

            Picker("键盘页", selection: $page) {
                ForEach(KeyboardPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 粘滞状态不再单独占一行：只在生效时于工具条右侧出现一个极短徽标，
            // 点一下即清除。默认状态键区紧贴工具条，没有任何空白与说明文字。
            if sticky != 0 {
                Button {
                    sticky = 0
                } label: {
                    Text(stickyBadge)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel("清除粘滞修饰键：" + stickyNames)
            }

            // 音量快捷键：点击在 静音 / 25% / 50% / 100% 之间循环，
            // 不占用额外一行高度，图标随档位变化。
            Button {
                clicks.cycleVolume()
            } label: {
                Image(systemName: clicks.iconName)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("按键音音量：" + clicks.levelText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: 粘滞修饰键状态

    /// 工具条里的极短徽标：⌃ ⇧ ⌥ ⌘ 只占一个字符，不会挤压分页控件。
    private var stickyBadge: String {
        var marks = ""
        if sticky & HIDSpec.modLeftControl != 0 { marks += "⌃" }
        if sticky & HIDSpec.modLeftShift != 0   { marks += "⇧" }
        if sticky & HIDSpec.modLeftAlt != 0     { marks += "⌥" }
        if sticky & HIDSpec.modLeftGUI != 0     { marks += "⌘" }
        return marks + " 清除"
    }

    private var stickyNames: String {
        var parts: [String] = []
        if sticky & HIDSpec.modLeftControl != 0 { parts.append("Ctrl") }
        if sticky & HIDSpec.modLeftShift != 0   { parts.append("Shift") }
        if sticky & HIDSpec.modLeftAlt != 0     { parts.append("Option") }
        if sticky & HIDSpec.modLeftGUI != 0     { parts.append("Command") }
        return parts.isEmpty ? "无" : parts.joined(separator: " + ")
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("键盘暂不可用：需在设置里开启「键鼠复合模式」，并按「\(HIDSpec.ipadIgnorePath)」忽略后重新配对；主机还须处于 Report Protocol 并订阅 2A4D。")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.orange)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // MARK: 按键分发

    private func handle(_ key: KeyDef) {
        switch key.role {
        case .spacer:
            return
        case .sticky(let mask):
            sticky ^= mask
            haptics.play()
        case .clear:
            sticky = 0
        case .key(let keycode, let modifier):
            hid.sendKey(keycode, modifiers: modifier | sticky, label: key.label)
            sticky = 0
            // 按键音：与真实键盘一致，敲一下响一下；音量在设置页滑块调节，
            // 键盘页工具条的喇叭按钮可在 静音 / 25% / 50% / 100% 之间循环。
            clicks.play()
            haptics.play()
        }
    }
}

// MARK: - 单行与单个键帽

private struct KeyRow: View {
    let keys: [KeyDef]
    let sticky: UInt8
    let height: CGFloat
    let tap: (KeyDef) -> Void

    private static let spacing: CGFloat = 4

    private func unit(for total: CGFloat) -> CGFloat {
        let weight = keys.reduce(CGFloat(0)) { $0 + $1.weight }
        let usable = max(0, total - KeyRow.spacing * CGFloat(max(0, keys.count - 1)))
        return weight > 0 ? usable / weight : 0
    }

    private func row(unit u: CGFloat) -> some View {
        HStack(spacing: KeyRow.spacing) {
            ForEach(0..<keys.count, id: \.self) { i in
                KeyCap(key: keys[i], sticky: sticky,
                       width: u * keys[i].weight, height: height, tap: tap)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            row(unit: unit(for: geo.size.width))
        }
        .frame(height: height)
    }
}

private struct KeyCap: View {
    let key: KeyDef
    let sticky: UInt8
    let width: CGFloat
    let height: CGFloat
    let tap: (KeyDef) -> Void

    private var isStickyActive: Bool {
        if case .sticky(let mask) = key.role { return sticky & mask != 0 }
        return false
    }

    private var fontSize: CGFloat {
        key.label.count > 2 ? 10 : (key.label.count > 1 ? 12 : 16)
    }

    private var fill: Color {
        if isStickyActive { return Color.accentColor }
        // 只用工程里已在真机/CI 上编译过的系统色，避免引入新的 UIColor 动态色。
        return key.prominent ? Color(.secondarySystemBackground)
                             : Color(.tertiarySystemBackground)
    }

    var body: some View {
        Group {
            if case .spacer = key.role {
                Color.clear
            } else {
                Button {
                    tap(key)
                } label: {
                    Text(key.label)
                        .font(.system(size: fontSize, weight: .medium))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: width, height: height)
                        .background(fill, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(isStickyActive ? Color.white : Color.primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.label)
            }
        }
        .frame(width: width, height: height)
    }
}
