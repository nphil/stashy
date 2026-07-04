import SwiftUI

/// The player's volume control: a speaker button that expands *inline* — rightward, in the same row, no
/// popup — into a one-finger horizontal slider with a live **0–100** readout. The value is a whole-percent
/// scale (0–100 in 1-unit steps): the drag snaps to integers and the number shows the exact level.
/// Dragging to the far left mutes; the speaker glyph reflects the level. Every scene starts silent.
struct VolumeControl: View {
    /// Current linear volume 0…1 (owned by the model; already quantised to whole percent).
    let volume: Double
    let isMuted: Bool
    /// Set a new volume (0…1). Called live while dragging.
    let onChange: (Double) -> Void
    /// Keep the controls from auto-hiding while the user is adjusting volume.
    let onInteract: () -> Void

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    private let trackWidth: CGFloat = 100
    private let readoutWidth: CGFloat = 30

    private var percent: Int { Int((volume * 100).rounded()) }
    private var panelWidth: CGFloat { trackWidth + 6 + readoutWidth }

    var body: some View {
        HStack(spacing: 6) {
            Button { toggleExpanded() } label: {
                Image(systemName: icon).modifier(ControlIcon())
            }
            panel
                .frame(width: expanded ? panelWidth : 0, height: 44)
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

    private var panel: some View {
        HStack(spacing: 6) {
            slider.frame(width: trackWidth)
            Text("\(percent)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: readoutWidth, alignment: .trailing)
        }
        .frame(width: panelWidth, height: 44)   // fixed intrinsic width so the clip matches the animation
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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Snap to whole-percent steps so the value moves 0–100 in 1-unit increments.
                        let frac = min(1, max(0, v.location.x / w))
                        onChange((frac * 100).rounded() / 100)
                        onInteract()
                        armCollapse()
                    }
            )
        }
    }

    private func toggleExpanded() {
        expanded.toggle()
        onInteract()
        if expanded { armCollapse() } else { collapseTask?.cancel() }
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
