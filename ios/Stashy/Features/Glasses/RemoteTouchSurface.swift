import SwiftUI
import UIKit

/// The remote's full-screen touch surface — UIKit recognizers, NOT SwiftUI gestures, for the same
/// reasons the player surface uses them (deterministic require-to-fail chains, dominant-axis locks).
/// Deliberately its OWN view rather than an extension of ZoomablePlayerSurface (documented
/// gesture-lifecycle landmine). The surface reports semantic events; policy lives in RemoteRootView.
///
/// The host view also draws a GLOWING FINGER TRAIL (owner, 2026-08-04: "show a glowing trail
/// following my finger so it's clear what I'm doing") — pure CALayer work fed by raw touch events,
/// so it costs no SwiftUI re-renders. Recognizers run with `cancelsTouchesInView = false` so the
/// trail keeps flowing after a pan/pinch recognises; nothing else reads the raw touches.
struct RemoteTouchSurface: UIViewRepresentable {
    enum Mode { case browse, playback }
    var mode: Mode

    // Browse events
    var onFocusStep: (Int, Int) -> Void = { _, _ in }      // dx, dy ∈ {-1, 0, 1}, one step
    var onFocusEnd: () -> Void = {}                        // hit a rail/row end (hard-stop feedback)
    var onSelect: () -> Void = {}
    /// Two-finger tap while browsing = back out of a full list. (Declaration order matters: the call
    /// site's labelled arguments must match it exactly — Swift won't reorder them.)
    var onBack: () -> Void = {}

    // Playback events. Mute and hold-2× are deliberately GONE (owner, 2026-08-04): hardware buttons
    // own volume, and speed changes only via the vertical swipe ladder.
    var onTogglePlay: () -> Void = {}
    var onSkip: (Int) -> Void = { _ in }                   // ±1 per double-tap rep; side by tap half
    var onScrub: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }   // dx pts since last, |vertical|, ended
    var onSpeedStep: (Int) -> Void = { _ in }              // vertical drag: ±1 ladder rung per step
    // Zoom (playback only). Pinch reports absolute gesture scale; pans report deltas while zoomed.
    var isZoomed: () -> Bool = { false }
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }     // scale factor since gesture start, ended
    var onZoomPan: (CGFloat, CGFloat) -> Void = { _, _ in }   // dx, dy deltas
    var onZoomToggle: () -> Void = {}                      // double-tap while zoomed = reset/engage

    func makeUIView(context: Context) -> GestureTrailView {
        let v = GestureTrailView()
        v.backgroundColor = .clear
        context.coordinator.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: GestureTrailView, context: Context) {
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

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
            panGR = pan
            pinchGR = pinch

            // The trail lives on raw touch events. By default a recognising pan/pinch CANCELS the
            // view's touches and the trail dies 12 pt into every drag — exactly the gestures the
            // trail exists to visualise.
            for gr in view.gestureRecognizers ?? [] { gr.cancelsTouchesInView = false }
        }

        private weak var panGR: UIPanGestureRecognizer?
        private weak var pinchGR: UIPinchGestureRecognizer?

        /// Pan↔pinch ONLY: a second finger landing mid-drag must start the zoom instead of dying
        /// behind the pan's exclusive claim (default UIKit exclusion starved the pinch whenever one
        /// finger moved ~10 pt first). Taps keep their require(toFail:) ordering untouched.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === panGR && other === pinchGR)
                || (gestureRecognizer === pinchGR && other === panGR)
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
            // Back out of a full list while browsing — its ONLY remaining job. The mute binding was
            // removed (owner, 2026-08-04): hardware volume buttons own sound entirely.
            guard parent.mode == .browse else { return }
            parent.onBack()
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
                // eyes-free hand drifts, and re-deciding mid-drag turns a scrub into a speed jump.
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

// MARK: - Finger trail

/// Draws a comet of soft glow dots under every touch. Pure CALayer: one small radial-gradient layer
/// per sample, animated to fade-and-shrink and removed on completion — no @State, no SwiftUI
/// invalidation, no display link. At 120 Hz touch delivery with the 6 pt spacing gate this tops out
/// around ~50 live layers, which is nothing.
@MainActor
final class GestureTrailView: UIView {
    /// Last emitted point per active touch, so a resting finger doesn't pile up dots.
    private var lastDot: [ObjectIdentifier: CGPoint] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true      // both pinch fingers get trails
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for t in touches {
            let p = t.location(in: self)
            lastDot[ObjectIdentifier(t)] = p
            addGlow(at: p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for t in touches {
            let p = t.location(in: self)
            let key = ObjectIdentifier(t)
            if let last = lastDot[key], hypot(p.x - last.x, p.y - last.y) < 6 { continue }
            lastDot[key] = p
            addGlow(at: p)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for t in touches { lastDot.removeValue(forKey: ObjectIdentifier(t)) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for t in touches { lastDot.removeValue(forKey: ObjectIdentifier(t)) }
    }

    private func addGlow(at p: CGPoint) {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [UIColor.white.withAlphaComponent(0.40).cgColor,
                       UIColor.white.withAlphaComponent(0.10).cgColor,
                       UIColor.white.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.45, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
        layer.addSublayer(glow)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.35
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
        glow.opacity = 0                    // model value = the animation's end state, no flash-back
        glow.add(group, forKey: "trail")
        CATransaction.commit()
    }
}
