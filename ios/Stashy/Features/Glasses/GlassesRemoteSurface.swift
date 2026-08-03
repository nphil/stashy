import SwiftUI

/// The phone-side surface while video plays on the glasses — v1 pipe-proof remote.
///
/// The user's eyes are on the glasses, so this screen is designed to be FELT, not looked at: true black
/// (OLED pixels off), one dim low-burn-in time cluster for the occasional glance, and the whole surface
/// is one big target — tap anywhere to play/pause, confirmed by haptic. The full eyes-free gesture
/// vocabulary (relative scrub, volume, speed, guards) replaces this in the next pass; keeping v1 to one
/// gesture is deliberate — it proves the pipe on device before the feel work is layered on.
struct GlassesRemoteSurface: View {
    @Bindable var model: ScenePlayerModel
    /// Scene title, empty to omit. Privacy gating happens here (not at the call site) so the rule
    /// lives next to the rendering it governs.
    var title: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
                if !Privacy.isOn, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                }
                Text("\(Self.clock(model.currentTime)) / \(Self.clock(model.duration))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
                Text(model.isPlaying ? "Playing on glasses — tap to pause" : "Paused — tap to play")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.togglePlayPause()
            Haptics.tap()
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
