import UIKit
import SwiftUI

/// The phone remote's analog stick: a spring-return virtual joystick that drives playback eyes-free.
///
/// ## Why a separate UIKit subtree
/// Hosted as a SIBLING above `RemoteTouchSurface`, never nested inside it. UIKit delivers a touch only
/// to recognizers on the hit-test view or its ANCESTORS, so a sibling's recognizers never see it —
/// which means zero delegate surgery on the surface's five existing recognizers (the pan↔pinch
/// simultaneity pairing there is a documented three-time repeat offender; do not disturb it). The
/// existing chip `Button`s already coexist with the surface exactly this way.
///
/// ## Why raw touches and not a UIPanGestureRecognizer
/// The stick needs an 8 pt deadzone and ZERO recognition delay. `UIPanGestureRecognizer` imposes
/// ~10 pt of slop before it even begins, which would swallow the entire fine-control zone.
///
/// ## Why a CALayer and not @State
/// The dome must track a 120 Hz finger or it feels rubbery, but the SEMANTIC output only needs to move
/// as fast as the glasses can show it. So the dome is a `CALayer` moved directly from the touch
/// handler with implicit animations disabled, deflection lands in a plain reference box, and a 30 Hz
/// `CADisplayLink` reads the box and emits commands. Writing deflection into `@State` would re-render
/// the SwiftUI tree at touch rate — the documented `onGeometryChange` landmine, avoided by
/// construction.
struct RemoteJoystick: UIViewRepresentable {

    /// Derived from the coordinator; there is no manual mode toggle anywhere in this design.
    enum StickMode: Equatable { case browse, transport, frame }

    var mode: StickMode
    var enabled: Bool = true
    /// Live playback duration, so the shuttle ladder can clamp its rates on short files.
    var duration: TimeInterval = 0
    /// Current glasses zoom, so pan velocity can scale with it.
    var zoomScale: CGFloat = 1
    /// True when the inner-right zone should creep by seeking instead of really slowing playback
    /// (the remux route cannot play below 1×).
    var slowUnavailable: Bool = false

    // Semantic output. All are called on the main actor at ≤30 Hz.
    var onFocusStep: (Int, Int) -> Void = { _, _ in }
    var onFocusRefused: () -> Void = {}
    var onSelect: () -> Void = {}
    /// (rung index into `JoystickMapping.jogRates`, direction +1 forward / −1 reverse-creep). nil = off.
    var onJog: (Int?, Int) -> Void = { _, _ in }
    var onShuttle: (Double) -> Void = { _ in }            // signed media-seconds per second, 0 = off
    var onShuttleCommit: () -> Void = {}
    var onSpeedStep: (Int) -> Void = { _ in }             // ±1 rung, latched
    var onPan: (CGVector, Double) -> Void = { _, _ in }   // canvas px/s, dt
    var onZoomStep: (Int) -> Void = { _ in }              // ±1 quarter-step, latched

    func makeUIView(context: Context) -> JoystickHostView {
        let v = JoystickHostView()
        v.coordinator = context.coordinator
        context.coordinator.host = v
        return v
    }

    func updateUIView(_ uiView: JoystickHostView, context: Context) {
        context.coordinator.parent = self
        uiView.isUserInteractionEnabled = enabled
        if !enabled { context.coordinator.abort() }
        uiView.apply(mode: mode)
    }

    func makeCoordinator() -> Driver { Driver(parent: self) }

    // MARK: - Driver

    /// Owns the gesture's state machine and the 30 Hz emit loop. Deliberately NOT an @Observable: the
    /// only things that ever reach SwiftUI are the quantised callbacks above.
    @MainActor
    final class Driver: NSObject {
        var parent: RemoteJoystick
        weak var host: JoystickHostView?

        init(parent: RemoteJoystick) { self.parent = parent }

        private var link: CADisplayLink?
        private var proxy: LinkProxy?
        private var lastTick: CFTimeInterval = 0

        // Gesture state
        private(set) var down = false
        private var offset: CGVector = .zero          // clamped deflection, points
        private var axis: JoystickMapping.Axis?
        private var pastGate = false
        private var jogRung: Int?
        private var shuttleRung: Int?
        private var shuttleActive = false
        private var repeatStep = 0
        private var nextRepeat: CFTimeInterval = 0
        private var atRim = false
        private var fallbackNextTick: CFTimeInterval = 0

        // MARK: Touch phases (called by the host)

        func began() {
            down = true
            offset = .zero
            axis = nil
            pastGate = false
            jogRung = nil
            shuttleRung = nil
            shuttleActive = false
            repeatStep = 0
            nextRepeat = 0
            atRim = false
            Haptics.tap(soft: true)
            StickHaptics.shared.beginBed(bedTexture(u: 0))
            startLink()
        }

        func moved(_ v: CGVector) {
            offset = v
            if axis == nil, parent.mode != .frame { axis = JoystickMapping.axis(of: v) }
        }

        func ended() {
            guard down else { return }
            down = false
            stopLink()
            StickHaptics.shared.endBed()
            if shuttleActive {
                parent.onShuttle(0)
                parent.onShuttleCommit()
                Haptics.tap()
            }
            if jogRung != nil { parent.onJog(nil, 1) }
            if parent.mode == .frame { parent.onPan(.zero, 0) }
            offset = .zero
            axis = nil
            jogRung = nil
            shuttleRung = nil
            shuttleActive = false
        }

        /// A second finger, a lock flip, a disconnect: zero everything and commit nothing.
        func abort() {
            guard down || link != nil else { return }
            down = false
            stopLink()
            StickHaptics.shared.abort()
            if shuttleActive { parent.onShuttle(0) }      // no commit — the seek target is discarded
            if jogRung != nil { parent.onJog(nil, 1) }
            if parent.mode == .frame { parent.onPan(.zero, 0) }
            offset = .zero
            axis = nil
            jogRung = nil
            shuttleRung = nil
            shuttleActive = false
        }

        func tapped() { parent.onSelect() }

        // MARK: 30 Hz emit loop

        private func startLink() {
            stopLink()
            let p = LinkProxy(target: self)
            let l = CADisplayLink(target: p, selector: #selector(LinkProxy.fire))
            // NOTE: CAFrameRateRange takes Float, not Double — an easy CI cycle to burn.
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            proxy = p
            link = l
            lastTick = CACurrentMediaTime()
        }

        private func stopLink() {
            link?.invalidate()
            link = nil
            proxy = nil
        }

        fileprivate func tick() {
            let now = CACurrentMediaTime()
            let dt = min(0.1, max(0.001, now - lastTick))
            lastTick = now
            guard down else { return }

            let d = hypot(offset.dx, offset.dy)
            let u = Float(JoystickMapping.fullFraction(d))
            feedBed(u: u, distance: d, now: now)

            // Rim contact — you are pushing on a wall.
            let rim = d >= JoystickMapping.maxTravel
            if rim != atRim {
                atRim = rim
                if rim { StickHaptics.shared.dip(); Haptics.step() }
            }

            switch parent.mode {
            case .browse:
                emitFocus(distance: d, now: now)
            case .transport:
                emitTransport(distance: d, now: now)
            case .frame:
                emitPan(dt: dt)
            }
        }

        // MARK: Per-mode emission

        private func emitFocus(distance d: CGFloat, now: CFTimeInterval) {
            guard d > JoystickMapping.gate, let axis else {
                repeatStep = 0
                nextRepeat = 0
                return
            }
            guard now >= nextRepeat else { return }
            let dx = axis == .horizontal ? (offset.dx > 0 ? 1 : -1) : 0
            let dy = axis == .vertical ? (offset.dy > 0 ? 1 : -1) : 0
            // Rubber zone = page jump: a repeat-RATE change, never a value change (Apple never lets
            // bounce alter a value, and neither do we).
            let jump = d > JoystickMapping.maxTravel ? 5 : 1
            for _ in 0..<jump { parent.onFocusStep(dx, dy) }
            nextRepeat = now + JoystickMapping.focusRepeatInterval(
                step: repeatStep, outer: JoystickMapping.outerFraction(d))
            repeatStep += 1
        }

        private func emitTransport(distance d: CGFloat, now: CFTimeInterval) {
            guard let axis else { return }
            if axis == .horizontal {
                let direction = offset.dx > 0 ? 1 : -1
                if d > JoystickMapping.gate {
                    // SHUTTLE — the outer zone.
                    if jogRung != nil { jogRung = nil; parent.onJog(nil, 1) }
                    let rung = JoystickMapping.shuttleRung(distance: d, previous: shuttleRung)
                    if rung != shuttleRung {
                        shuttleRung = rung
                        StickHaptics.shared.dip()
                        Haptics.step()
                    }
                    shuttleActive = true
                    parent.onShuttle(JoystickMapping.shuttleRate(
                        distance: d, direction: direction, duration: parent.duration, previous: shuttleRung))
                } else {
                    // JOG — the inner zone. This is where AI slow motion lives: the rungs sit at or
                    // below 0.5×, which is exactly the engage gate in ScenePlayerModel.updateSlowMo.
                    if shuttleActive { shuttleActive = false; parent.onShuttle(0); parent.onShuttleCommit() }
                    let rung = JoystickMapping.jogRung(distance: d, previous: jogRung)
                    if rung != jogRung {
                        jogRung = rung
                        if rung != nil { StickHaptics.shared.dip(); Haptics.step() }
                        parent.onJog(rung, direction)
                    }
                }
                if !pastGate, d > JoystickMapping.gate { pastGate = true; Haptics.step() }
                if pastGate, d < JoystickMapping.gate - 5 { pastGate = false; Haptics.step() }
            } else {
                // Vertical = the LATCHED speed ladder. Push and release for one rung; hold to repeat
                // at a flat cadence (only five rungs exist — overshooting is worse than being slow).
                guard d > JoystickMapping.gate, now >= nextRepeat else { return }
                parent.onSpeedStep(offset.dy < 0 ? 1 : -1)      // up = faster
                nextRepeat = now + JoystickMapping.latchedRepeatInterval(step: repeatStep)
                repeatStep += 1
            }
        }

        private func emitPan(dt: Double) {
            // Vertical past the gate steps ZOOM; everything else pans. Note the symmetry with
            // transport: outer-vertical steps speed there and zoom here — same finger, same feel,
            // and only one can ever be true at a time. One grammar, no modes.
            let d = hypot(offset.dx, offset.dy)
            if d > JoystickMapping.gate, abs(offset.dy) > JoystickMapping.verticalBias * abs(offset.dx) {
                let now = CACurrentMediaTime()
                if now >= nextRepeat {
                    parent.onZoomStep(offset.dy < 0 ? 1 : -1)
                    nextRepeat = now + 0.300
                }
                parent.onPan(.zero, dt)
                return
            }
            nextRepeat = 0
            parent.onPan(JoystickMapping.panVelocity(offset: offset, scale: parent.zoomScale), dt)
        }

        // MARK: Haptic bed

        private func bedTexture(u: Float) -> StickHaptics.Texture {
            switch parent.mode {
            case .browse:    return .off                       // clicks only — absence IS the mode tell
            case .frame:     return .frame
            case .transport: return jogRung != nil ? .viscous : .transport
            }
        }

        private func feedBed(u: Float, distance d: CGFloat, now: CFTimeInterval) {
            guard StickHaptics.isEnabled else { return }
            let texture = bedTexture(u: u)
            guard texture != .off else { return }
            if StickHaptics.shared.usingFallback {
                // No CoreHaptics: a rate-modulated selection-tick train. Coarse, but a real readout.
                guard d > JoystickMapping.deadzone, now >= fallbackNextTick else { return }
                Haptics.selectionTick()
                fallbackNextTick = now + StickHaptics.fallbackInterval(u: u)
            } else {
                StickHaptics.shared.setBed(texture, u: u)
            }
        }
    }

    /// `CADisplayLink` RETAINS its target, so a direct target leaks the driver. Same weak-proxy shape
    /// as `FrameProbeLinkProxy` / `SlowMoLinkProxy` elsewhere in the repo.
    @MainActor
    final class LinkProxy: NSObject {
        weak var target: Driver?
        init(target: Driver) { self.target = target }
        @objc func fire() { target?.tick() }
    }
}

// MARK: - Host view

/// Draws the stick and reads raw touches. Everything visual is a CALayer so nothing here invalidates
/// SwiftUI layout while a finger is down.
@MainActor
final class JoystickHostView: UIView {
    weak var coordinator: RemoteJoystick.Driver?

    private let socket = CAShapeLayer()
    private let socketRimLight = CAShapeLayer()
    private let socketRimShade = CAShapeLayer()
    private let gateRing = CAShapeLayer()
    private let dome = CALayer()
    private let domeFill = CAGradientLayer()
    private let specular = CAGradientLayer()
    private let occlusion = CAShapeLayer()
    private let glyph = CAShapeLayer()

    private var centre: CGPoint = .zero
    private var grabBias: CGVector = .zero
    private var returnAnimator: UIViewPropertyAnimator?
    private var mode: RemoteJoystick.StickMode = .browse

    private let R = JoystickMapping.maxTravel
    private let rBase = JoystickMapping.baseRadius
    private let rDome = JoystickMapping.domeRadius

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Appearance
    //
    // The constraint: a fullscreen true-black remote that must leak NO scene identity, and Liquid
    // Glass reads FLAT over flat black (documented landmine — nothing to refract), so `.glassEffect`
    // and `Material` are both out; they would produce a grey circle.
    //
    // The answer is one virtual key light above-and-left, plus SUBTRACTIVE shadow: a black shadow on
    // a black background is invisible, so the dome does not cast darkness — it OCCLUDES the socket's
    // rim highlight where it overlaps. That reads unmistakably as "this object is in front of that
    // one", and it is the only depth cue that works on true black.

    private func buildLayers() {
        socket.fillColor = UIColor.white.withAlphaComponent(0.022).cgColor
        socket.strokeColor = nil
        layer.addSublayer(socket)

        socketRimLight.fillColor = nil
        socketRimLight.strokeColor = UIColor.white.withAlphaComponent(0.055).cgColor
        socketRimLight.lineWidth = 1
        layer.addSublayer(socketRimLight)

        socketRimShade.fillColor = nil
        socketRimShade.strokeColor = UIColor.white.withAlphaComponent(0.020).cgColor
        socketRimShade.lineWidth = 1
        layer.addSublayer(socketRimShade)

        gateRing.fillColor = nil
        gateRing.strokeColor = UIColor.white.withAlphaComponent(0.05).cgColor
        gateRing.lineWidth = 1
        gateRing.lineDashPattern = [2, 8]
        layer.addSublayer(gateRing)

        domeFill.type = .radial
        domeFill.colors = [UIColor.white.withAlphaComponent(0.20).cgColor,
                           UIColor.white.withAlphaComponent(0.12).cgColor,
                           UIColor.white.withAlphaComponent(0.055).cgColor]
        domeFill.locations = [0, 0.55, 1]
        // Off-centre falloff is the whole trick: the visual system reads it as a sphere lit from
        // above-left. One property, most of the work.
        domeFill.startPoint = CGPoint(x: 0.38, y: 0.34)
        domeFill.endPoint = CGPoint(x: 1.05, y: 1.15)
        domeFill.frame = CGRect(x: 0, y: 0, width: rDome * 2, height: rDome * 2)
        domeFill.cornerRadius = rDome
        domeFill.masksToBounds = true
        dome.addSublayer(domeFill)

        specular.type = .radial
        specular.colors = [UIColor.white.withAlphaComponent(0.16).cgColor,
                           UIColor.white.withAlphaComponent(0).cgColor]
        specular.frame = CGRect(x: rDome * 0.30, y: rDome * 0.26, width: 26, height: 18)
        specular.cornerRadius = 9
        specular.masksToBounds = true
        dome.addSublayer(specular)

        dome.frame = CGRect(x: 0, y: 0, width: rDome * 2, height: rDome * 2)
        dome.cornerRadius = rDome
        dome.borderWidth = 1
        dome.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        layer.addSublayer(dome)

        occlusion.fillColor = UIColor.black.cgColor
        occlusion.opacity = 0.9
        layer.insertSublayer(occlusion, below: dome)

        glyph.fillColor = UIColor.white.withAlphaComponent(0.28).cgColor
        dome.addSublayer(glyph)

        layer.opacity = 0.35   // idle: dim but always findable — never zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if centre == .zero { centre = homeCentre }
        redrawSocket()
        if returnAnimator == nil && coordinator?.down != true { dome.position = centre }
        applyGlyph()
    }

    /// Screen-centred so the stick is ambidextrous with no setting; low enough that a thumb reaches it
    /// without a regrip. Floating capture (below) means this is only where it RESTS.
    private var homeCentre: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY - 254)
    }

    private func redrawSocket() {
        let rect = CGRect(x: centre.x - rBase, y: centre.y - rBase, width: rBase * 2, height: rBase * 2)
        socket.path = UIBezierPath(ovalIn: rect).cgPath
        socketRimLight.path = UIBezierPath(ovalIn: rect.offsetBy(dx: 0, dy: -0.5)).cgPath
        socketRimShade.path = UIBezierPath(ovalIn: rect.offsetBy(dx: 0, dy: 0.5)).cgPath
        let gateRect = CGRect(x: centre.x - JoystickMapping.gate, y: centre.y - JoystickMapping.gate,
                              width: JoystickMapping.gate * 2, height: JoystickMapping.gate * 2)
        gateRing.path = UIBezierPath(ovalIn: gateRect).cgPath
    }

    /// Mode is legible by SHAPE, never colour. Colour fails in peripheral vision, fails for
    /// colour-blind users, and — decisively — a face-up phone glowing an accent hue is a state
    /// broadcast, which is the exact thing XR privacy mode is about. The stick is strictly monochrome.
    func apply(mode newMode: RemoteJoystick.StickMode) {
        guard newMode != mode else { return }
        mode = newMode
        applyGlyph()
        gateRing.lineDashPattern = newMode == .frame ? [4, 6] : (newMode == .browse ? [2, 8] : nil)
    }

    private func applyGlyph() {
        let path = UIBezierPath()
        let c = CGPoint(x: rDome, y: rDome)
        switch mode {
        case .transport:                       // a horizontal bar — an axis of time
            path.append(UIBezierPath(roundedRect: CGRect(x: c.x - 11, y: c.y - 1.5, width: 22, height: 3),
                                     cornerRadius: 1.5))
        case .frame:                           // four dots — two axes, no preferred direction
            for (dx, dy) in [(0.0, -9.0), (9.0, 0.0), (0.0, 9.0), (-9.0, 0.0)] {
                path.append(UIBezierPath(ovalIn: CGRect(x: c.x + dx - 1.5, y: c.y + dy - 1.5,
                                                        width: 3, height: 3)))
            }
        case .browse:                          // a 2×2 grid
            for (dx, dy) in [(-4.0, -4.0), (4.0, -4.0), (-4.0, 4.0), (4.0, 4.0)] {
                path.append(UIBezierPath(roundedRect: CGRect(x: c.x + dx - 2.5, y: c.y + dy - 2.5,
                                                             width: 5, height: 5), cornerRadius: 1))
            }
        }
        glyph.path = path.cgPath
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touches.count == 1, event?.allTouches?.count == 1 else {
            coordinator?.abort()
            return
        }
        returnAnimator?.stopAnimation(true)
        returnAnimator = nil

        // FLOATING CAPTURE — the single most important eyes-free affordance. The stick's logic centre
        // snaps to wherever the thumb lands, so a mis-grab is impossible by construction: you cannot
        // land off-centre because there is no centre until you land.
        let p = touch.location(in: self)
        let clamped = CGPoint(x: min(max(p.x, rBase + 16), bounds.width - rBase - 16),
                              y: min(max(p.y, rBase + 16), bounds.height - 96))
        // If the centre had to be clamped to keep the ring on screen, carry the difference as a bias
        // so the INITIAL deflection is still mathematically zero — it feels like your thumb resting on
        // the edge of a real dome.
        grabBias = CGVector(dx: p.x - clamped.x, dy: p.y - clamped.y)
        centre = clamped
        redrawSocket()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dome.position = p
        CATransaction.commit()
        setAssemblyOpacity(1.0, duration: 0.10)
        coordinator?.began()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        var v = CGVector(dx: p.x - centre.x - grabBias.dx, dy: p.y - centre.y - grabBias.dy)
        let d = hypot(v.dx, v.dy)
        if d > 0 {
            let clampedDist = min(d, R)
            let knobDist = JoystickMapping.rubberBand(fingerDistance: d)   // visual only
            let unit = CGVector(dx: v.dx / d, dy: v.dy / d)
            // The CONTROL value is clamped at the gate; only the KNOB travels into the rubber band.
            v = CGVector(dx: unit.dx * clampedDist, dy: unit.dy * clampedDist)
            // No implicit animations: without this, every position write gets a free 0.25 s animation
            // fighting the finger — the classic "why does my stick feel like syrup".
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dome.position = CGPoint(x: centre.x + unit.dx * knobDist, y: centre.y + unit.dy * knobDist)
            // Parallax: a real sphere's highlight stays fixed in world space while the sphere moves,
            // so the specular slides OPPOSITE by 22 % and the dome tips fractionally away.
            let t = knobDist / R
            specular.position = CGPoint(x: rDome * 0.30 + 13 - unit.dx * 0.22 * 12,
                                        y: rDome * 0.26 + 9 - unit.dy * 0.22 * 12)
            dome.transform = CATransform3DMakeScale(1 - 0.04 * t, 1 - 0.04 * t, 1)
            occlusion.path = UIBezierPath(ovalIn: CGRect(x: dome.position.x - rDome - 1.5,
                                                         y: dome.position.y - rDome - 1.5,
                                                         width: rDome * 2 + 3, height: rDome * 2 + 3)).cgPath
            CATransaction.commit()
        }
        coordinator?.moved(v)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        if cancelled { coordinator?.abort() } else { coordinator?.ended() }
        springHome()
        setAssemblyOpacity(0.35, duration: 0.5)
    }

    /// The return animation is VISUAL ONLY — the control value was zeroed the instant the touch ended,
    /// so a bouncy return carries zero functional risk, and a spring-return stick that returns without
    /// overshoot does not read as sprung. ζ = 0.62 → ~8.4 % overshoot (5.7 pt on a full deflection).
    ///
    /// This deliberately does NOT use the glasses spring token (0.32 / 0.86): that token governs a
    /// 60 Hz birdbath optic at cinema distance, where overshoot strobes. This is a 120 Hz control
    /// surface 30 cm from the eye, in the hand. Two surfaces, two physics — do not "fix" this.
    private func springHome() {
        let target = centre
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let animator = UIViewPropertyAnimator(
            duration: 0.26,
            timingParameters: UISpringTimingParameters(dampingRatio: reduceMotion ? 1.0 : 0.62))
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.dome.position = target
            self.dome.transform = CATransform3DIdentity
            self.specular.position = CGPoint(x: self.rDome * 0.30 + 13, y: self.rDome * 0.26 + 9)
            self.occlusion.path = UIBezierPath(ovalIn: CGRect(x: target.x - self.rDome - 1.5,
                                                              y: target.y - self.rDome - 1.5,
                                                              width: self.rDome * 2 + 3,
                                                              height: self.rDome * 2 + 3)).cgPath
        }
        animator.addCompletion { [weak self] _ in
            self?.returnAnimator = nil
            self?.centre = self?.homeCentre ?? target
            self?.redrawSocket()
        }
        returnAnimator = animator
        animator.startAnimation()
    }

    private func setAssemblyOpacity(_ value: Float, duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.opacity
        anim.toValue = value
        anim.duration = duration
        layer.add(anim, forKey: "opacity")
        layer.opacity = value
    }
}
