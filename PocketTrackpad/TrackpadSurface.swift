import SwiftUI
import UIKit

/// 用 UIKit 手势识别器实现触控区：SwiftUI 原生手势无法可靠区分
/// 单指平移 / 双指滚动 / 轻点 / 长按，这里用 UIPanGestureRecognizer 的
/// minimumNumberOfTouches / maximumNumberOfTouches 做硬隔离。
struct TrackpadSurface: UIViewRepresentable {

    @EnvironmentObject var hid: HIDPeripheral
    /// 连接成功后触控区撑满屏幕：去掉圆角、边框和灰底，避免边缘留白。
    var edgeToEdge: Bool = false
    /// 全键盘页下方的小范围触控区：提示文字精简、圆角缩小，手势逻辑完全不变。
    var compact: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(hid: hid)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.layer.cornerCurve = .continuous
        view.layer.borderColor = UIColor.separator.cgColor
        Self.applyStyle(view, edgeToEdge: edgeToEdge, compact: compact)

        let move = UIPanGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleMove(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        move.cancelsTouchesInView = false
        move.delegate = context.coordinator
        view.addGestureRecognizer(move)

        let scroll = UIPanGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.cancelsTouchesInView = false
        scroll.delegate = context.coordinator
        view.addGestureRecognizer(scroll)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.50
        longPress.numberOfTouchesRequired = 1
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        // 三指上滑：与 1 指平移 / 2 指滚动靠触点数硬隔离。
        // 用 pan 而不是 swipe，可以自己定 80pt 阈值并防止一次手势重复触发。
        let homeSwipe = UIPanGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleHomeSwipe(_:)))
        homeSwipe.minimumNumberOfTouches = 3
        homeSwipe.maximumNumberOfTouches = 3
        homeSwipe.cancelsTouchesInView = false
        homeSwipe.delegate = context.coordinator
        view.addGestureRecognizer(homeSwipe)

        let hint = UILabel()
        hint.text = Self.hintText(composite: hid.compositeDevice, compact: compact)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.font = UIFont.preferredFont(forTextStyle: compact ? .caption2 : .footnote)
        hint.textColor = UIColor.secondaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])
        context.coordinator.hint = hint

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hid = hid
        context.coordinator.hint?.text = Self.hintText(composite: hid.compositeDevice, compact: compact)
        Self.applyStyle(uiView, edgeToEdge: edgeToEdge, compact: compact)
    }

    private static func hintText(composite: Bool, compact: Bool) -> String {
        if compact {
            let base = "单指移动指针 · 轻点左键 · 双击左键\n双指滚动 · 长按右键"
            return composite ? base + "\n三指上滑回桌面" : base
        }
        let base = "单指移动指针  ·  轻点左键  ·  双击左键\n双指滚动  ·  长按右键"
        return composite ? base + "\n三指上滑回桌面（Command+H）" : base
    }

    private static func applyStyle(_ view: UIView, edgeToEdge: Bool, compact: Bool) {
        view.layer.cornerRadius = edgeToEdge ? 0 : (compact ? 12 : 22)
        view.layer.borderWidth = edgeToEdge ? 0 : 1
        view.backgroundColor = edgeToEdge
            ? UIColor.systemBackground
            : UIColor.secondarySystemBackground
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var hid: HIDPeripheral
        weak var hint: UILabel?

        private var lastMove: CGPoint = .zero
        private var lastScroll: CGPoint = .zero
        private var residualX: CGFloat = 0
        private var residualY: CGFloat = 0
        private var residualWheel: CGFloat = 0
        private var didHideHint = false
        private var homeStartY: CGFloat = 0
        private var homeFired = false

        init(hid: HIDPeripheral) { self.hid = hid }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // 允许单指平移与长按共存；其余靠触点数量天然互斥。
            return true
        }

        private func hideHint() {
            guard !didHideHint else { return }
            didHideHint = true
            UIView.animate(withDuration: 0.25) { self.hint?.alpha = 0 }
        }

        @objc func handleMove(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                lastMove = .zero
                residualX = 0
                residualY = 0
                hideHint()
            case .changed:
                let t = g.translation(in: g.view)
                let stepX = t.x - lastMove.x
                let stepY = t.y - lastMove.y
                lastMove = t

                let s = CGFloat(hid.sensitivity)
                let rawX = stepX * s + residualX
                let rawY = stepY * s + residualY
                let ix = Int(rawX.rounded(.toNearestOrAwayFromZero))
                let iy = Int(rawY.rounded(.toNearestOrAwayFromZero))
                residualX = rawX - CGFloat(ix)
                residualY = rawY - CGFloat(iy)
                hid.enqueue(dx: ix, dy: iy)
            default:
                lastMove = .zero
            }
        }

        @objc func handleScroll(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                lastScroll = .zero
                residualWheel = 0
                hideHint()
            case .changed:
                let t = g.translation(in: g.view)
                let stepY = t.y - lastScroll.y
                lastScroll = t

                let s = CGFloat(hid.scrollSensitivity) / 6.0
                // 默认（自然滚动关）：上滑 -> 负 wheel（滚轮下滑），下滑 -> 正 wheel（滚轮上滑）。
                // 打开自然滚动后整体取反；底部滚轮键使用完全相同的定义。
                let direction: CGFloat = hid.naturalScrolling ? -1 : 1
                let raw = stepY * s * direction + residualWheel
                let iw = Int(raw.rounded(.toNearestOrAwayFromZero))
                residualWheel = raw - CGFloat(iw)
                hid.enqueue(wheel: iw)
            default:
                lastScroll = .zero
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            hideHint()
            hid.click(0x01)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            hideHint()
            hid.click(0x01, count: 2)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            hideHint()
            hid.click(0x02)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }

        /// 三指上滑 80pt：发送 Command+H（回主屏幕）。
        /// homeFired 保证一次手势只触发一次，抬手后复位。
        @objc func handleHomeSwipe(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                homeStartY = g.translation(in: g.view).y
                homeFired = false
            case .changed:
                guard !homeFired else { return }
                let dy = g.translation(in: g.view).y - homeStartY
                if dy <= -80 {
                    homeFired = true
                    hideHint()
                    hid.goHome()
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            default:
                homeFired = false
            }
        }
    }
}
