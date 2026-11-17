import SwiftUI
import UIKit

/// 用 UIKit 手势识别器实现触控区：SwiftUI 原生手势无法可靠区分
/// 单指平移 / 双指拖拽 / 轻点 / 长按，这里用 UIPanGestureRecognizer 的
/// minimumNumberOfTouches / maximumNumberOfTouches 做硬隔离。滚动在右侧滚轮条 / 底部滚轮键。
struct TrackpadSurface: UIViewRepresentable {

    @EnvironmentObject var hid: HIDPeripheral
    /// 连接成功后触控区撑满屏幕：去掉圆角、边框和灰底，避免边缘留白。
    var edgeToEdge: Bool = false
    /// 全键盘页下方的小范围触控区：不显示提示文字、圆角缩小，手势逻辑完全不变。
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

        // 双指按住拖动：按下左键并移动指针（拖拽图标 / 选中文字等）。
        // 与单指平移 / 三指手势靠触点数硬隔离。滚动已移到底部滚轮键。
        let drag = UIPanGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleDrag(_:)))
        drag.minimumNumberOfTouches = 2
        drag.maximumNumberOfTouches = 2
        drag.cancelsTouchesInView = false
        drag.delegate = context.coordinator
        view.addGestureRecognizer(drag)

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

        // 三指左右滑：切 App（Cmd+Tab / Cmd+Shift+Tab）。与三指上滑同为 3 触点，
        // 靠方向互斥——上滑只认 dy<=-80，左右滑只认 |dx|>=80 且横向占优。
        let appSwipe = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleAppSwipe(_:)))
        appSwipe.minimumNumberOfTouches = 3
        appSwipe.maximumNumberOfTouches = 3
        appSwipe.cancelsTouchesInView = false
        appSwipe.delegate = context.coordinator
        view.addGestureRecognizer(appSwipe)

        let hint = UILabel()
        hint.text = Self.hintText(composite: hid.compositeDevice || hid.bridgeMode)
        // 键盘页的小触控区不显示任何提示文字；全屏触控板保留手势说明。
        hint.isHidden = compact
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.font = UIFont.preferredFont(forTextStyle: .footnote)
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

        // 右侧竖直滚轮条：直接画在触控区右侧，手指按住它上下滑动即滚动。
        // 它只是视觉提示（isUserInteractionEnabled=false，不吞触摸），命中判定放在
        // handleMove 里做，复用同一个单指 pan，避免与指针移动手势互相抢。
        let bar = UIView()
        bar.isUserInteractionEnabled = false
        bar.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.9)
        bar.layer.cornerRadius = 13
        bar.layer.cornerCurve = .continuous
        bar.layer.borderColor = UIColor.separator.cgColor
        bar.layer.borderWidth = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let grip = UIImageView(image: UIImage(systemName: "arrow.up.and.down"))
        grip.tintColor = UIColor.secondaryLabel
        grip.contentMode = .scaleAspectFit
        grip.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(grip)

        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: compact ? 20 : 26),
            bar.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: compact ? 0.6 : 0.42),
            grip.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 14),
            grip.heightAnchor.constraint(equalToConstant: 26)
        ])
        context.coordinator.scrollBar = bar

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hid = hid
        context.coordinator.hint?.text = Self.hintText(composite: hid.compositeDevice || hid.bridgeMode)
        context.coordinator.hint?.isHidden = compact
        Self.applyStyle(uiView, edgeToEdge: edgeToEdge, compact: compact)
    }

    private static func hintText(composite: Bool) -> String {
        let base = "单指移动指针  ·  轻点左键  ·  双击左键\n双指按住拖动 = 拖拽（图标/选中文字）\n单指长按右键  ·  右侧滚轮条 / 底部滚轮键 = 滚动"
        return composite ? base + "\n三指上滑最小化 / 回桌面  ·  三指左右滑切 App" : base
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
        weak var scrollBar: UIView?

        private var lastMove: CGPoint = .zero
        private var residualX: CGFloat = 0
        private var residualY: CGFloat = 0
        /// 右侧滚轮条：手指起点是否落在竖条内。落在其上只发 wheel、不发指针位移。
        private var scrollBarActive = false
        private var scrollBarResidual: CGFloat = 0
        private var lastDrag: CGPoint = .zero
        private var residualDragX: CGFloat = 0
        private var residualDragY: CGFloat = 0
        /// 双指是否已越过位移阈值、真正按下左键进入拖动。轻点/微动保持 false，
        /// 避免在 iPad 主屏 app 图标上轻点就被按住拖动。
        private var dragArmed = false
        /// 双指拖动触发阈值（pt）：累计位移超过它才 setButton 按下左键。
        private static let dragThreshold: CGFloat = 8
        private var didHideHint = false
        private var homeStartY: CGFloat = 0
        private var homeFired = false
        private var appStartX: CGFloat = 0
        private var appStartY: CGFloat = 0
        private var appFired = false

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

        /// 单指平移：普通区域移动指针；起点落在右侧滚轮条内则只发 wheel。
        /// 滚轮条方向约定与底部滚轮键一致（默认上滑=滚轮下滑，自然滚动开关可反转）。
        @objc func handleMove(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                lastMove = .zero
                residualX = 0
                residualY = 0
                scrollBarResidual = 0
                hideHint()
                let start = g.location(in: g.view)
                // 命中范围略大于竖条本身，方便手指按住。
                scrollBarActive = scrollBar.map {
                    $0.frame.insetBy(dx: -10, dy: -6).contains(start)
                } ?? false
            case .changed:
                let t = g.translation(in: g.view)
                let stepX = t.x - lastMove.x
                let stepY = t.y - lastMove.y
                lastMove = t

                if scrollBarActive {
                    let scale = CGFloat(hid.scrollSensitivity) / 4.0
                    let direction: CGFloat = hid.naturalScrolling ? -1 : 1
                    let raw = stepY * scale * direction + scrollBarResidual
                    let d = Int(raw.rounded(.toNearestOrAwayFromZero))
                    scrollBarResidual = raw - CGFloat(d)
                    if d != 0 { hid.enqueue(wheel: d) }
                    return
                }

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
                scrollBarActive = false
            }
        }

        /// 双指按住拖动 = 按住左键并移动指针（拖拽选中文字 / 文件等）。
        /// 防误触：began 不再立即按下左键，累计位移超过阈值（8pt）才真正进入拖动；
        /// 轻点或微小移动不会按住左键，避免在 iPad 主屏 app 图标上误触发拖动。
        /// 滚动已移到底部滚轮键与右侧滚轮条，双指不再发 wheel。
        @objc func handleDrag(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                lastDrag = .zero
                residualDragX = 0
                residualDragY = 0
                dragArmed = false
                hideHint()
            case .changed:
                let t = g.translation(in: g.view)

                // 尚未越过阈值：只累计位移，不按下左键、不发位移。
                // 用「距手势起点的总位移」判断，跳过阈值之前的这段位移（不补发），
                // 触发后从当前位置开始跟手，避免阈值前微动把 app 图标拖动。
                if !dragArmed {
                    if hypot(t.x, t.y) >= Self.dragThreshold {
                        dragArmed = true
                        lastDrag = t
                        residualDragX = 0
                        residualDragY = 0
                        hid.setButton(0x01, pressed: true)
                        KeyClickPlayer.shared.play()
                        HapticPlayer.shared.play()
                    }
                    return
                }

                let stepX = t.x - lastDrag.x
                let stepY = t.y - lastDrag.y
                lastDrag = t

                // 拖拽跟手：用指针灵敏度，方向与自然滚动无关（这是移动不是滚动）。
                let s = CGFloat(hid.sensitivity)
                let rawX = stepX * s + residualDragX
                let rawY = stepY * s + residualDragY
                let ix = Int(rawX.rounded(.toNearestOrAwayFromZero))
                let iy = Int(rawY.rounded(.toNearestOrAwayFromZero))
                residualDragX = rawX - CGFloat(ix)
                residualDragY = rawY - CGFloat(iy)
                if ix != 0 || iy != 0 { hid.enqueue(dx: ix, dy: iy) }
            default:
                lastDrag = .zero
                if dragArmed {
                    hid.setButton(0x01, pressed: false)
                    dragArmed = false
                }
            }
        }

        /// 手势起点是否落在右侧滚轮条内（与 handleMove 相同的命中范围）。
        /// 滚轮条上只做滚动，不触发轻点/双击/长按，避免按住条准备滚动时误发右键。
        private func isOnScrollBar(_ g: UIGestureRecognizer) -> Bool {
            guard let view = g.view else { return false }
            return scrollBar.map {
                $0.frame.insetBy(dx: -10, dy: -6).contains(g.location(in: view))
            } ?? false
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard !isOnScrollBar(g) else { return }
            hideHint()
            hid.click(0x01)
            KeyClickPlayer.shared.play()
            HapticPlayer.shared.play()
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard !isOnScrollBar(g) else { return }
            hideHint()
            hid.click(0x01, count: 2)
            KeyClickPlayer.shared.play()
            HapticPlayer.shared.play()
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, !isOnScrollBar(g) else { return }
            hideHint()
            hid.click(0x02)
            KeyClickPlayer.shared.play()
            HapticPlayer.shared.play()
        }

        /// 三指上滑 80pt：发送 Command+M（最小化当前程序 / 回桌面）。
        /// homeFired 保证一次手势只触发一次，抬手后复位。
        /// 横向占优时交给 handleAppSwipe，避免同一次左右滑误触发回桌面。
        @objc func handleHomeSwipe(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                homeStartY = g.translation(in: g.view).y
                homeFired = false
            case .changed:
                guard !homeFired else { return }
                let t = g.translation(in: g.view)
                let dy = t.y - homeStartY
                if dy <= -80, abs(dy) >= abs(t.x) {
                    homeFired = true
                    hideHint()
                    hid.goHome()
                    HapticPlayer.shared.play()
                }
            default:
                homeFired = false
            }
        }

        /// 三指左右滑 80pt：切 App。向右=Cmd+Tab（下一个），向左=Cmd+Shift+Tab（上一个）。
        /// 与三指上滑靠方向互斥：只有横向占优（|dx|>80 且 |dx|>|dy|）才触发。
        @objc func handleAppSwipe(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                let t = g.translation(in: g.view)
                appStartX = t.x
                appStartY = t.y
                appFired = false
            case .changed:
                guard !appFired else { return }
                let t = g.translation(in: g.view)
                let dx = t.x - appStartX
                let dy = t.y - appStartY
                guard abs(dx) >= 80, abs(dx) > abs(dy) else { return }
                appFired = true
                hideHint()
                hid.switchApp(forward: dx > 0)
                HapticPlayer.shared.play()
            default:
                appFired = false
            }
        }
    }
}
