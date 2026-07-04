import SwiftUI

/// The player's volume control: a speaker button that expands *inline* — rightward, in the same row, no
/// popup — into a one-finger horizontal slider with the live **0–100** value overlaid on the track (so it
/// adds no extra width). Dragging to the far left mutes; the speaker glyph reflects the level. The value
/// is a whole-percent scale (0–100 in 1-unit steps). Every scene starts silent.
struct VolumeControl: View {
    /// Current linear volume 0…1 (owned by the model; already quantised to whole percent).
    let volume: Double
    let isMuted: Bool
    /// Set a new volume (0…1). Called live while dragging.
    let onChange: (Double) -> Void
    /// Keep the controls from auto-hiding while the user is adjusting volume.
    let onInteract: () -> Void
    /// Width of the expanded slider track. Wider in landscape fullscreen (lots of room), 54 elsewhere.
    var trackWidth: CGFloat = 54

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var lastPct = -1

    private var percent: Int { Int((volume * 100).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Button { toggleExpanded() } label: {
                Image(systemName: icon).modifier(ControlIcon())
            }
            slider
                .frame(width: expanded ? trackWidth : 0, height: 44)
                .opacity(expanded ? 1 : 0)
                .clipped()
                .allowsHitTesting(expanded)
        }
        .animation(.easeOut(duration: 0.22), value: expanded)
    }

    private var icon: String {
        if isMuted { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var slider: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let fill = CGFloat(min(1, max(0, volume)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 5)
                Capsule().fill(.white).frame(width: max(5, w * fill), height: 5)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .offset(x: min(max(w * fill - 7, 0), w - 14))
            }
            .frame(maxHeight: .infinity)
            // Live 0–100 value overlaid at the top of the track (adds no horizontal width).
            .overlay(alignment: .top) {
                Text("\(percent)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Snap to whole-percent steps so the value moves 0–100 in 1-unit increments.
                        let frac = Double(min(1, max(0, v.location.x / w)))
                        let pct = Int((frac * 100).rounded())
                        onChange(Double(pct) / 100)
                        // One haptic tick per 1% step — quick drag = rapid taps, slow drag = one per step.
                        if pct != lastPct { lastPct = pct; Haptics.selectionTick() }
                        onInteract()
                        armCollapse()
                    }
            )
        }
    }

    private func toggleExpanded() {
        expanded.toggle()
        onInteract()
        if expanded { lastPct = percent; Haptics.prepareSelection(); armCollapse() } else { collapseTask?.cancel() }
    }

    /// Auto-collapse back to the icon after a few seconds of no adjustment.
    private func armCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) { expanded = false }
        }
    }
}
