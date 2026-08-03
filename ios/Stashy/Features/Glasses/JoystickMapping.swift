import CoreGraphics
import Foundation

/// Pure value-type math for the remote's analog stick. No UIKit, no state, no isolation — every
/// function here is a total function of its inputs, so the stick's feel can be reasoned about (and
/// changed) without touching the view layer.
///
/// GEOMETRY (points, iPhone 17 Pro):
/// ```
///   0 …  8   DEADZONE   nothing, ever
///   8 … 36   INNER      analog, transient        j = (d−8)/28
///  36 … 68   OUTER      detented, past the GATE  h = (d−36)/32
///     > 68   RUBBER     value pegged; only the knob moves
/// ```
/// `r_dome + R = r_base` (42 + 68 = 110): at full deflection the dome is exactly flush with the
/// socket rim — a physical limit you can see, with no label. The deadzone is 8 pt because thumb
/// tremor on glass is 3–5 pt and capacitive noise 1–2 pt; it also sits BELOW UIKit's ~10 pt pan slop,
/// which is why the stick reads raw touches instead of using a `UIPanGestureRecognizer`.
enum JoystickMapping {

    // MARK: - Geometry

    static let deadzone: CGFloat = 8
    static let gate: CGFloat = 36
    static let maxTravel: CGFloat = 68
    static let rubberAsymptote: CGFloat = 18
    static let domeRadius: CGFloat = 42
    static let baseRadius: CGFloat = 110

    /// Vertical only wins clearly: a thumb pivoting at the MCP joint traces an arc, so "push right"
    /// is physically right-and-slightly-down. Without the bias, honest horizontal intent reads as
    /// diagonal and the axis lock picks wrong.
    static let verticalBias: CGFloat = 1.35

    // MARK: - Curves

    /// Blended cubic expo. Linear gives no fine region (10 pt past the deadzone is already 11 % of
    /// full rate); pure cubic wastes the first 40 % of travel and reads as a bigger deadzone. At
    /// k = 0.25 half deflection yields 21.9 % — fine near centre, coarse at the rim, monotonic.
    static func expo(_ x: CGFloat, k: CGFloat = 0.25) -> CGFloat {
        let c = min(1, max(0, x))
        return k * c + (1 - k) * c * c * c
    }

    /// UIScrollView's asymptotic bounce, which is why it feels right. The CONTROL VALUE stays clamped
    /// at 1.0 throughout — Apple never lets bounce change a value, and neither do we.
    static func rubberBand(fingerDistance d: CGFloat) -> CGFloat {
        guard d > maxTravel else { return d }
        let overflow = d - maxTravel
        return maxTravel + rubberAsymptote * (1 - 1 / (overflow / rubberAsymptote + 1))
    }

    /// Normalised position within the inner (analog) zone.
    static func innerFraction(_ d: CGFloat) -> CGFloat {
        min(1, max(0, (d - deadzone) / (gate - deadzone)))
    }

    /// Normalised position within the outer (detented) zone.
    static func outerFraction(_ d: CGFloat) -> CGFloat {
        min(1, max(0, (d - gate) / (maxTravel - gate)))
    }

    /// One continuous ramp across BOTH zones, ignoring the gate — used by pan, which has no detents.
    static func fullFraction(_ d: CGFloat) -> CGFloat {
        min(1, max(0, (d - deadzone) / (maxTravel - deadzone)))
    }

    // MARK: - Jog (inner zone) — the AI slow-motion ladder

    /// Rungs are {0.10, 0.25, 0.50}× and deliberately NOT a continuum. `SlowMoRunner` rebuilds its
    /// interpolator whenever `desiredMids(forRate:)` changes, and that function saturates at 7 mids:
    /// 0.50 → 3 mids, 0.25 → 7, 0.10 → 7 (clamped). So sweeping the whole slow zone costs at most TWO
    /// rebuilds, and the J1↔J2 boundary — the one crossed most while frame-hunting — costs ZERO.
    /// Do not extend below 0.25 on a latched axis: 0.125× asks for 15 mids, gets 7, and judder returns.
    static let jogRates: [Double] = [0.10, 0.25, 0.50]

    /// Index into `jogRates`, or nil inside the deadzone. Hysteresis is applied against `previous` so
    /// a resting thumb can't chatter across a boundary.
    static func jogRung(distance d: CGFloat, previous: Int?, hysteresis: CGFloat = 0.07) -> Int? {
        guard d > deadzone else { return nil }
        let j = expo(innerFraction(d))
        return rung(fraction: j, count: jogRates.count, previous: previous, hysteresis: hysteresis)
    }

    // MARK: - Shuttle (outer zone)

    /// Base rates in media-seconds per wall-second. S4 ramps into an "afterburner" above h = 0.90:
    /// analog where analog is useful (there is no precision at 110×), quantised where it matters.
    static let shuttleRates: [Double] = [4, 12, 36, 110]

    static func shuttleRung(distance d: CGFloat, previous: Int?, hysteresis: CGFloat = 0.035) -> Int? {
        guard d > gate else { return nil }
        let h = outerFraction(d)
        return rung(fraction: h, count: shuttleRates.count, previous: previous, hysteresis: hysteresis)
    }

    /// Signed shuttle rate. `duration` clamps it so no rung can cross the whole file in under 3 s —
    /// a 4-minute clip compresses gracefully instead of gaining four useless gears.
    static func shuttleRate(distance d: CGFloat, direction: Int, duration: TimeInterval,
                            previous: Int?) -> Double {
        guard let rung = shuttleRung(distance: d, previous: previous) else { return 0 }
        var rate = shuttleRates[rung]
        let h = outerFraction(d)
        if rung == shuttleRates.count - 1, h > 0.90 {
            let t = Double((h - 0.90) / 0.10)
            rate *= 1 + 2.6 * pow(t, 1.5)
        }
        if duration.isFinite, duration > 0 {
            rate = min(rate, max(4, duration / 3))
        }
        return direction < 0 ? -rate : rate
    }

    // MARK: - Pan (frame mode)

    /// Velocity in glasses-canvas px/s. Two intuitions conflict — pan should feel the same at every
    /// zoom (v ∝ travel range) and should never sweep the visible window too fast (v ∝ window width)
    /// — so take the min: constant ~1.1 s corner-to-corner up to 2×, then capped at 2.4 window-widths
    /// per second so a 4× pan never whips. QUADRATIC is what buys precision: at u = 0.15 the velocity
    /// is ~2 % of max, i.e. single-digit px/s at 4×.
    static func panVelocity(offset: CGVector, scale: CGFloat) -> CGVector {
        let s = Double(max(1, scale))
        guard s > 1 else { return .zero }
        let d = hypot(offset.dx, offset.dy)
        guard d > deadzone else { return .zero }
        let u = Double(expo(fullFraction(d), k: 0.20))
        let unit = d > 0 ? CGVector(dx: offset.dx / d, dy: offset.dy / d) : .zero
        let vMaxX = min(0.9 * (s - 1) * 1920, 2.4 * 1920 / s)
        let vMaxY = min(0.9 * (s - 1) * 1080, 2.4 * 1080 / s)
        let mag = u * u
        return CGVector(dx: vMaxX * mag * Double(unit.dx), dy: vMaxY * mag * Double(unit.dy))
    }

    // MARK: - Repeat cadence

    /// Browse/grid focus repeat: accelerates so a long rail is crossable (full deflection reaches the
    /// floor in ~8 steps, 25 cards in ~2.1 s), and the floor tightens with deflection.
    static func focusRepeatInterval(step: Int, outer h: CGFloat) -> TimeInterval {
        let base = 0.380 * pow(0.86, Double(max(0, step)))
        let floor = 0.080 * (1 - 0.35 * Double(min(1, max(0, h))))
        return max(floor, base)
    }

    /// Speed rungs and zoom steps do NOT accelerate: there are only five rungs and thirteen zoom
    /// steps, so overshooting the target is worse than being slightly slow.
    static func latchedRepeatInterval(step: Int) -> TimeInterval {
        step <= 0 ? 0.500 : 0.320
    }

    // MARK: - Shared

    /// Quantise `fraction` into `count` equal bands, holding `previous` until the fraction moves
    /// `hysteresis` beyond the boundary. Detents are ~8 pt apart, comfortably above a thumb's ~4 pt
    /// blind repeatability.
    static func rung(fraction: CGFloat, count: Int, previous: Int?, hysteresis: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let f = min(0.9999, max(0, fraction))
        let raw = min(count - 1, Int(f * CGFloat(count)))
        guard let previous, previous >= 0, previous < count, previous != raw else { return raw }
        // Inside the hysteresis band around the boundary we are leaving, hold the old rung.
        let band = CGFloat(1) / CGFloat(count)
        let boundary = CGFloat(raw > previous ? raw : previous) * band
        return abs(f - boundary) < hysteresis ? previous : raw
    }

    /// Dominant-axis lock with the thumb-arc bias. Returns nil until the deadzone is cleared.
    static func axis(of offset: CGVector) -> Axis? {
        let d = hypot(offset.dx, offset.dy)
        guard d > deadzone else { return nil }
        return abs(offset.dy) > verticalBias * abs(offset.dx) ? .vertical : .horizontal
    }

    enum Axis: Sendable { case horizontal, vertical }
}
