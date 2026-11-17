import Foundation
import UIKit

/// 虚拟按键的本机振动反馈。
///
/// 与按键音（KeyClickPlayer）平行：一个总开关 + 强弱档位，设置页可调并试振，
/// 键盘按键 / 鼠标底部键 / 触控区点击统一走这里，替换掉原先散落各处写死的
/// `UIImpactFeedbackGenerator(style: .light)`。
///
/// 强弱用 UIImpactFeedbackGenerator 的 style 表示（系统定义的体感强度，最一致）：
/// 弱 = .light，中 = .medium，强 = .heavy。设置持久化在 UserDefaults。
final class HapticPlayer: ObservableObject {

    static let shared = HapticPlayer()

    // v2 key：默认关闭振动反馈。老用户旧 key 里存着 true，继续读会让「默认关闭」无效；
    // 换新 key 让所有用户拿到新默认值（个人如需可到设置里重新打开）。
    private static let enabledKey = "PocketTrackpad.hapticEnabled.v2"
    private static let strengthKey = "PocketTrackpad.hapticStrength.v1"

    /// 强弱档位，rawValue 存 UserDefaults。
    enum Strength: Int, Codable, CaseIterable {
        case light = 0
        case medium = 1
        case heavy = 2

        var label: String {
            switch self {
            case .light: return "弱"
            case .medium: return "中"
            case .heavy: return "强"
            }
        }

        var style: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            }
        }
    }

    /// 总开关。
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// 当前强弱。
    @Published var strength: Strength {
        didSet { UserDefaults.standard.set(strength.rawValue, forKey: Self.strengthKey) }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        let raw = UserDefaults.standard.integer(forKey: Self.strengthKey)
        strength = Strength(rawValue: raw) ?? .light
    }

    /// 触发一次振动。关闭时直接返回，不做任何反馈调用。
    func play() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: strength.style)
        generator.impactOccurred()
    }

    /// 设置页「试振」用：即使用户把开关关了也响一次，让他知道当前档位的手感。
    func preview() {
        let generator = UIImpactFeedbackGenerator(style: strength.style)
        generator.impactOccurred()
    }
}
