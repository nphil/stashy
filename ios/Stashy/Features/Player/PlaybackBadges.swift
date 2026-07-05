import SwiftUI

/// Player-overlay status badges: a **quality** pill (resolution + codec of what's actually on screen)
/// and a **method** pill (the playback cost tier — direct / remux / on-device / server — colour-coded so
/// the cheap native path reads green and the workstation-server last resort reads red).

extension PlaybackTier {
    /// Best→worst, green→red. Distinct from the app accent — this is a semantic cost scale.
    var color: Color {
        switch self {
        case .direct:         return Color(red: 0.30, green: 0.80, blue: 0.46)  // green — least work
        case .remux:          return Color(red: 0.24, green: 0.80, blue: 0.80)  // teal — cheap rewrite
        case .server:         return Color(red: 1.00, green: 0.35, blue: 0.30)  // red — server compute
        }
    }
}

/// Pure styling helpers for the quality pill (kept out of the view so they're easy to reason about).
enum PlaybackBadgeStyle {
    /// The live quality label + its tier colour. Prefers the *actual decoded* size (honest across a
    /// quality switch); falls back to the source file's metadata resolution before the first frame.
    static func quality(presentationSize: CGSize, scene: StashScene) -> (label: String, color: Color) {
        let minDim: Int
        if presentationSize.width > 0, presentationSize.height > 0 {
            minDim = Int(min(presentationSize.width, presentationSize.height))
        } else if let h = Int((scene.resolutionLabel ?? "").dropLast()) {   // "1080p" → 1080
            minDim = h
        } else {
            return (scene.resolutionLabel ?? "—", Color(white: 0.72))
        }
        switch minDim {
        case 1700...: return ("4K",    Color(red: 0.72, green: 0.56, blue: 1.00))  // indigo — premium
        case 900...:  return ("1080p", Color(red: 0.40, green: 0.85, blue: 0.55))  // green
        case 620...:  return ("720p",  Color(red: 0.42, green: 0.70, blue: 1.00))  // blue
        case 380...:  return ("480p",  Color(red: 0.95, green: 0.76, blue: 0.32))  // amber
        default:      return ("240p",  Color(white: 0.72))                          // grey
        }
    }

    /// Tidy the raw container codec string into a familiar label.
    static func codec(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "H264", "AVC", "AVC1": return "H.264"
        case "HEVC", "H265", "HVC1", "HEV1": return "H.265"
        default: return raw.uppercased()   // AV1, VP9, MPEG4, …
        }
    }
}

/// The two status pills (quality + method), compact enough to share the single control row with the
/// time, volume and transport buttons. Fixed-size so text never truncates; kept short so nothing spills.
struct PlayerStatusBadges: View {
    let scene: StashScene
    let presentationSize: CGSize
    let tier: PlaybackTier

    var body: some View {
        HStack(spacing: 4) {
            qualityBadge
            methodBadge
        }
        .lineLimit(1)
        .fixedSize()
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
    }

    private var qualityBadge: some View {
        let q = PlaybackBadgeStyle.quality(presentationSize: presentationSize, scene: scene)
        return HStack(spacing: 4) {
            Text(q.label).foregroundStyle(q.color)
            if let codec = PlaybackBadgeStyle.codec(scene.codecLabel) {
                Text(codec).foregroundStyle(.white.opacity(0.82))
            }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.black.opacity(0.38), in: Capsule())
        .overlay(Capsule().strokeBorder(q.color.opacity(0.55), lineWidth: 0.75))
    }

    private var methodBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: tier.symbol).font(.system(size: 8.5, weight: .black))
            Text(tier.label).font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(tier.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tier.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tier.color.opacity(0.5), lineWidth: 0.75))
    }
}
