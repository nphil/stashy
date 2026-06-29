import SwiftUI

/// A tasteful, abstract feminine silhouette shown when a performer has no image (or none is set).
/// Drawn as a single curvy contour so it reads as elegant line-art rather than a literal figure.
struct FemmeSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }

        var path = Path()

        // Head.
        let headR = 0.085 * h
        let headC = p(0.5, 0.10)
        path.addEllipse(in: CGRect(x: headC.x - headR, y: headC.y - headR, width: headR * 2, height: headR * 2))

        // Body — a symmetric standing contour with the feminine waist→hip curve.
        path.move(to: p(0.44, 0.19))
        path.addCurve(to: p(0.31, 0.34), control1: p(0.41, 0.24), control2: p(0.34, 0.28))   // shoulder/arm down (L)
        path.addCurve(to: p(0.41, 0.50), control1: p(0.35, 0.42), control2: p(0.41, 0.44))   // waist in (L)
        path.addCurve(to: p(0.31, 0.66), control1: p(0.41, 0.57), control2: p(0.32, 0.58))   // hip out (L)
        path.addCurve(to: p(0.41, 0.95), control1: p(0.34, 0.80), control2: p(0.40, 0.88))   // leg down (L)
        path.addLine(to: p(0.59, 0.95))                                                       // base
        path.addCurve(to: p(0.69, 0.66), control1: p(0.60, 0.88), control2: p(0.66, 0.80))   // leg up (R)
        path.addCurve(to: p(0.59, 0.50), control1: p(0.68, 0.58), control2: p(0.59, 0.57))   // hip out (R)
        path.addCurve(to: p(0.69, 0.34), control1: p(0.59, 0.44), control2: p(0.65, 0.42))   // waist in (R)
        path.addCurve(to: p(0.56, 0.19), control1: p(0.66, 0.28), control2: p(0.59, 0.24))   // shoulder (R)
        path.closeSubpath()                                                                  // neck

        return path
    }
}

struct PerformerPlaceholder: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                themeManager.current.surfaceColor
                FemmeSilhouette()
                    .fill(
                        LinearGradient(
                            colors: [
                                themeManager.current.accentColor.opacity(0.30),
                                themeManager.current.accentColor.opacity(0.10)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay {
                        FemmeSilhouette()
                            .stroke(
                                themeManager.current.accentColor.opacity(0.65),
                                style: StrokeStyle(lineWidth: max(1.5, min(w, h) * 0.012), lineCap: .round, lineJoin: .round)
                            )
                    }
                    .frame(width: w * 0.7, height: h * 0.82)
                    .position(x: w / 2, y: h / 2)
            }
        }
    }
}
