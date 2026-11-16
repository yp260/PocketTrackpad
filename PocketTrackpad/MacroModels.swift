import Foundation

// MARK: - 宏数据模型
//
// 一条「宏」= 一段时间轴上的键鼠事件序列。录制时按真实时序采集，回放时按
// 相同时间偏移重新注入到 HIDPeripheral 的公共输入方法，因此录制/回放走的是
// 完全相同的一条链路（BLE HID 的 iPad / Windows 模式、以及 WiFi 桥接都适用）。

/// 单个宏事件。用 kind + 若干可选字段而不是带关联值的 enum，方便 Codable 持久化
/// 与在编辑器里逐字段修改（改时间、替换键位、改位移量）。
struct MacroEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Equatable, Hashable {
        case move          // 指针相对位移 (dx, dy)
        case wheel         // 滚轮 (wheel)
        case key           // 按键 (keycode + modifiers)，按下后由系统逻辑自动松开
        case buttonDown    // 鼠标按下 (mask)
        case buttonUp      // 鼠标抬起 (mask)
        case click         // 短按点击 (mask, count)
    }

    var id: UUID = UUID()
    /// 事件类型
    var kind: Kind
    /// 相对录制起点的秒数（回放按此调度）
    var t: TimeInterval

    var dx: Int = 0
    var dy: Int = 0
    var wheel: Int = 0
    /// USB HID 键码
    var keycode: UInt8 = 0
    /// 修饰键位图（Ctrl / Shift / Option / Command）
    var modifiers: UInt8 = 0
    /// 鼠标键位图：1=左, 2=右, 4=中
    var mask: UInt8 = 0
    /// 连击次数
    var count: Int = 1
    /// 可读说明（按键名等），仅用于界面显示
    var label: String = ""

    /// 界面上一行摘要
    var summary: String {
        switch kind {
        case .move:
            return "移动 dx=\(dx) dy=\(dy)"
        case .wheel:
            return "滚动 \(wheel > 0 ? "+" : "")\(wheel)"
        case .key:
            let name = label.isEmpty ? String(format: "0x%02X", keycode) : label
            let mods = MacroEvent.modifierText(modifiers)
            return mods.isEmpty ? "按键 \(name)" : "按键 \(mods) + \(name)"
        case .buttonDown:
            return "按下\(MacroEvent.buttonText(mask))"
        case .buttonUp:
            return "松开\(MacroEvent.buttonText(mask))"
        case .click:
            let suffix = count > 1 ? " ×\(count)" : ""
            return "点击\(MacroEvent.buttonText(mask))\(suffix)"
        }
    }

    static func modifierText(_ m: UInt8) -> String {
        var parts: [String] = []
        if m & 0x01 != 0 { parts.append("Ctrl") }
        if m & 0x02 != 0 { parts.append("Shift") }
        if m & 0x04 != 0 { parts.append("Opt") }
        if m & 0x08 != 0 { parts.append("Cmd") }
        return parts.joined(separator: "+")
    }

    static func buttonText(_ mask: UInt8) -> String {
        switch mask {
        case 0x01: return "左键"
        case 0x02: return "右键"
        case 0x04: return "中键"
        default: return "0x\(String(mask, radix: 16))"
        }
    }
}

/// 一条保存好的宏。
struct Macro: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    /// 总时长（秒）。回放一轮的结束点取 duration 与最后一个事件时间的较大值。
    var duration: TimeInterval
    var events: [MacroEvent]

    /// 回放时一轮的实际长度，避免编辑删掉尾部事件后还空等。
    var playbackDuration: TimeInterval {
        max(duration, events.last?.t ?? 0) + 0.05
    }
}

/// 播放模式。
enum PlayMode: Codable, Hashable {
    case once
    case times(Int)   // 播放 N 次后停止，N >= 1
    case infinite     // 无限循环

    var label: String {
        switch self {
        case .once: return "单次"
        case .times(let n): return "播放 \(n) 次"
        case .infinite: return "无限循环"
        }
    }
}

// MARK: - 宏存储（UserDefaults 持久化）

/// 管理宏列表的增删改与持久化。作为 EnvironmentObject 注入整个 App。
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = []

    private static let key = "PocketTrackpad.macros.v1"

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: MacroStore.key),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else { return }
        macros = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        UserDefaults.standard.set(data, forKey: MacroStore.key)
    }

    func add(_ macro: Macro) {
        macros.append(macro)
        save()
    }

    func update(_ macro: Macro) {
        guard let i = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        macros[i] = macro
        save()
    }

    func delete(id: UUID) {
        macros.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to name: String) {
        guard let i = macros.firstIndex(where: { $0.id == id }) else { return }
        macros[i].name = name
        save()
    }
}
