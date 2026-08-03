import SwiftUI
import UIKit

/// The remote's full-screen touch surface — UIKit recognizers, NOT SwiftUI gestures, for the same
/// reasons the player surface uses them (deterministic require-to-fail chains, dominant-axis locks).
/// Deliberately its OWN view rather than an extension of ZoomablePlayerSurface (documented
/// gesture-lifecycle landmine). The surface reports semantic events; policy lives in RemoteRootView.
struct RemoteTouchSurface: UIViewRepresentable {
    enum Mode { case browse, playback }
    var mode: Mode

    // Browse events
    var onFocusStep: (Int, Int) -> Void = { _, _ in }      // dx, dy ∈ {-1, 0, 1}, one step
    var onFocusEnd: () -> Void = {}                        // hit a rail/row end (hard-stop feedback)
    var onSelect: () -> Void = {}

    // Playback events
    var onTogglePlay: () -> Void = {}
    var onSkip: (Int) -> Void = { _ in }                   // ±1 per double-tap rep; side by tap half
    var onScrub: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }   // dx pts since last, |vertical|, ended
    var onSpeedStep: (Int) -> Void = { _ in }              // vertical drag: ±1 ladder rung per step
    var onHoldSpeed: (Bool) -> Void = { _ in }             // long-press 2× while held
    var onMute: () -> Void = {}
    // Zoom (playback only). Pinch reports absolute gesture scale; pans report deltas while zoomed.
    var isZoomed: () -> Bool = { false }
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }     // scale factor since gesture start, ended
    var onZoomPan: (CGFloat, CGFloat) -> Void = { _, _ in }   // dx, dy deltas
    var onZoomToggle: () -> Void = {}                      // double-tap while zoomed = reset/engage

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        context.coordinator.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RemoteTouchSurface
        init(parent: RemoteTouchSurface) { self.parent = parent }

        private weak var host: UIView?
        // Pan bookkeeping
        private var panAxis: Axis? = nil
        private enum Axis { case horizontal, vertical }
        private var lastTranslation: CGPoint = .zero
        private var stepAccumulator: CGPoint = .zero

        func attach(to view: UIView) {
            host = view

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            // Same trade as the player surface: the single-tap waits out the double-tap window.
            singleTap.require(toFail: doubleTap)
            view.addGestureRecognizer(singleTap)

            let twoFinger = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFinger.numberOfTouchesRequired = 2
            view.addGestureRecognizer(twoFinger)

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
            hold.minimumPressDuration = 0.5
            view.addGestureRecognizer(hold)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            guard parent.mode == .playback else { return }
            switch gr.state {
            case .changed: parent.onPinch(gr.scale, false)
            case .ended, .cancelled: parent.onPinch(gr.scale, true)
            default: break
            }
        }

        @objc func handleSingleTap(_ gr: UITapGestureRecognizer) {
            switch parent.mode {
            case .browse: parent.onSelect()
            case .playback: parent.onTogglePlay()
            }
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard parent.mode == .playback, let host else { return }
            // Zoomed: double-tap resets to fit (Photos parity). Fit: skip by tap half.
            if parent.isZoomed() { parent.onZoomToggle(); return }
            let side = gr.location(in: host).x < host.bounds.midX ? -1 : 1
            parent.onSkip(side)
        }

        @objc func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
            guard parent.mode == .playback else { return }
            parent.onMute()
        }

        @objc func handleHold(_ gr: UILongPressGestureRecognizer) {
            guard parent.mode == .playback else { return }
            switch gr.state {
            case .began: parent.onHoldSpeed(true)
            case .ended, .cancelled, .failed: parent.onHoldSpeed(false)
            default: break
            }
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let host else { return }
            let t = gr.translation(in: host)
            switch gr.state {
            case .began:
                panAxis = nil
                lastTranslation = .zero
                stepAccumulator = .zero
            case .changed:
                // Dominant-axis intent lock at 12 pt, then the axis holds for the whole gesture — an
                // eyes-free hand drifts, and re-deciding mid-drag turns a scrub into a volume jump.
                if panAxis == nil {
                    if abs(t.x) >= 12 || abs(t.y) >= 12 {
                        panAxis = abs(t.x) >= abs(t.y) ? .horizontal : .vertical
                    } else { return }
                }
                let dx = t.x - lastTranslation.x
                let dy = t.y - lastTranslation.y
                lastTranslation = t
                // Zoomed playback: one-finger drags PAN the zoom on both axes (no axis lock — panning
                // is 2D). Scrub/speed come back the moment zoom resets.
                if parent.mode == .playback, parent.isZoomed() {
                    parent.onZoomPan(dx, dy)
                    return
                }
                switch (parent.mode, panAxis!) {
                case (.browse, .horizontal):
                    // 52 pt per step (down from 72 after device feel-testing: "a bit slow").
                    stepAccumulator.x += dx
                    while stepAccumulator.x >= 52 { stepAccumulator.x -= 52; emitStep(1, 0) }
                    while stepAccumulator.x <= -52 { stepAccumulator.x += 52; emitStep(-1, 0) }
                case (.browse, .vertical):
                    stepAccumulator.y += dy
                    while stepAccumulator.y >= 70 { stepAccumulator.y -= 70; emitStep(0, 1) }
                    while stepAccumulator.y <= -70 { stepAccumulator.y += 70; emitStep(0, -1) }
                case (.playback, .horizontal):
                    parent.onScrub(dx, abs(t.y), false)
                case (.playback, .vertical):
                    // Speed ladder: one rung per 80 pt, drag UP = faster.
                    stepAccumulator.y += dy
                    while stepAccumulator.y >= 80 { stepAccumulator.y -= 80; parent.onSpeedStep(-1) }
                    while stepAccumulator.y <= -80 { stepAccumulator.y += 80; parent.onSpeedStep(1) }
                }
            case .ended, .cancelled:
                if parent.mode == .playback {
                    if parent.isZoomed() { panAxis = nil; return }
                    switch panAxis {
                    case .horizontal: parent.onScrub(0, abs(t.y), true)
                    case .vertical: break
                    case nil: break
                    }
                } else if panAxis == nil {
                    // A flick that never crossed a step threshold still means "one step that way".
                    let v = gr.velocity(in: host)
                    if abs(v.x) > 300 || abs(v.y) > 300 {
                        if abs(v.x) >= abs(v.y) { emitStep(v.x > 0 ? 1 : -1, 0) }
                        else { emitStep(0, v.y > 0 ? 1 : -1) }
                    }
                }
                panAxis = nil
            default: break
            }
        }

        private func emitStep(_ dx: Int, _ dy: Int) {
            parent.onFocusStep(dx, dy)
        }
    }
}
