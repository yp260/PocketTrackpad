import Foundation
import AVFoundation

/// 虚拟键盘 / 鼠标的按键音。
///
/// 音色来自打包进 App 的 `keyclick.wav`（机械键盘 click，45ms，由
/// `scripts/gen_keyclick.py` 合成）。用 AVAudioPlayer 播放而不是系统音效，
/// 因为系统音效（AudioServicesPlaySystemSound）的音量不可调，而这里要
/// 提供用户可调的音量。
///
/// 两个实现要点：
/// 1. **播放器池**：连按同一键时 AVAudioPlayer 正在播放会被重播打断，
///    用 4 个播放器轮转，快打也不会吞音；
/// 2. **音频会话**：`.playback` + `.mixWithOthers`——与 iOS 自带键盘一致，
///    手机静音时按键音仍然响，且不会打断 iPad 上正在播放的音频。
final class KeyClickPlayer: ObservableObject {

    static let shared = KeyClickPlayer()

    private static let volumeKey = "PocketTrackpad.keyClickVolume.v1"
    private static let enabledKey = "PocketTrackpad.keyClickEnabled.v1"

    /// 音量 0...1，0 即静音。设置页滑块与键盘页的音量按钮共用这一个值。
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            applyVolume()
        }
    }

    /// 总开关：关闭后即使音量非 0 也不响（设置页 Toggle）。
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// 音量按钮循环的档位：静音 / 25% / 50% / 100%。
    static let levels: [Double] = [0, 0.25, 0.5, 1.0]

    private var players: [AVAudioPlayer] = []
    private var nextIndex = 0
    private var sessionReady = false

    /// 实际发声音量：总开关关闭时恒为 0。
    var effectiveVolume: Double { isEnabled ? volume : 0 }

    /// 当前档位在 levels 中的下标（用于按钮图标与循环）。
    var levelIndex: Int {
        let v = effectiveVolume
        var best = 0
        var bestDiff = Double.greatestFiniteMagnitude
        for (i, level) in Self.levels.enumerated() {
            let d = abs(level - v)
            if d < bestDiff { bestDiff = d; best = i }
        }
        return best
    }

    var iconName: String {
        switch levelIndex {
        case 0: return "speaker.slash.fill"
        case 1: return "speaker.wave.1.fill"
        case 2: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var levelText: String {
        switch levelIndex {
        case 0: return "静音"
        case 1: return "25%"
        case 2: return "50%"
        default: return "100%"
        }
    }

    private init() {
        // 区分「没设置过」与「用户主动设成 0（静音）」：
        // object(forKey:) 返回 nil 表示从未写过。
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double {
            volume = min(max(saved, 0), 1)
        } else {
            volume = 0.6
        }
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        loadPlayers()
    }

    // MARK: - 播放

    /// 按一次键音。音量 0 / 总开关关闭时直接返回，不做任何音频调用。
    func play() {
        guard effectiveVolume > 0.01, !players.isEmpty else { return }
        activateSessionIfNeeded()
        let player = players[nextIndex]
        nextIndex = (nextIndex + 1) % players.count
        player.volume = Float(effectiveVolume)
        player.currentTime = 0
        player.play()
    }

    /// 设置页「试听」按钮用：按当前音量响一次。
    func preview() {
        guard effectiveVolume > 0.01 else { return }
        play()
    }

    /// 键盘页音量按钮：在静音 / 25% / 50% / 100% 之间循环，并立即试听一次。
    func cycleVolume() {
        let current = levelIndex
        let next = (current + 1) % Self.levels.count
        let oldVolume = effectiveVolume
        volume = Self.levels[next]
        if next == 0 {
            // 切到静音档：先用旧音量响一声，让用户确认按钮生效，再真正静音。
            if !players.isEmpty {
                let p = players[nextIndex]
                nextIndex = (nextIndex + 1) % players.count
                p.volume = Float(oldVolume)
                p.currentTime = 0
                p.play()
            }
        } else {
            play()
        }
    }

    // MARK: - 内部

    private func loadPlayers() {
        guard let url = Bundle.main.url(forResource: "keyclick", withExtension: "wav") else {
            // 资源缺失时静默降级：没有按键音，但键盘功能完全不受影响。
            return
        }
        for _ in 0..<4 {
            guard let p = try? AVAudioPlayer(contentsOf: url) else { continue }
            p.volume = Float(effectiveVolume)
            p.prepareToPlay()
            players.append(p)
        }
    }

    private func applyVolume() {
        let v = Float(effectiveVolume)
        for p in players { p.volume = v }
    }

    /// 首次播放时才激活音频会话，避免 App 启动就抢占音频焦点。
    private func activateSessionIfNeeded() {
        guard !sessionReady else { return }
        sessionReady = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 音频不可用（被其他 App 占用等）时忽略：按键音只是锦上添花。
        }
    }
}
