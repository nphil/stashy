import SwiftUI

/// The player's volume control: a speaker button that expands into a one-finger slider with the live
/// **0–100** value overlaid on the track. Dragging to the quiet end mutes; the speaker glyph reflects the
/// level. Whole-percent scale (0–100 in 1-unit steps). Every scene starts silent.
///
/// Two layouts: **horizontal** (landscape — expands rightward inline, lots of room) and **vertical**
/// (portrait — floats a compact slider *upward* as an overlay above the speaker, so it never widens the
/// control row or clips off a narrow screen).
struct VolumeControl: View {
    /// Current linear volume 0…1 (owned by the model; already quantised to whole percent).
    let volume: Double
    let isMuted: Bool
    /// Set a new volume (0…1). Called live while dragging.
    let onChange: (Double) -> Void
    /// Keep the controls from auto-hiding while the user is adjusting volume.
    let onInteract: () -> Void
    /// Width of the expanded *horizontal* slider track. Wider in landscape fullscreen (lots of room).
    var trackWidth: CGFloat = 54
    /// Portrait: expand upward as a floating vertical slider instead of rightward.
    var vertical = false

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var lastPct = -1

    private var percent: Int { Int((volume * 100).rounded()) }
    private let verticalTrackHeight: CGFloat = 116

    var body: some View {
        Group {
            if vertical {
                // Portrait: the speaker with the slider floating *above* it as an overlay — zero-width in the
                // row (never clips, never pushes neighbours).
                Button { toggleExpanded() } label: {
                    Image(systemName: icon).modifier(ControlIcon())
                }
                .overlay(alignment: .top) {
                    verticalSlider
                        .frame(width: 34, height: verticalTrackHeight)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        .environment(\.colorScheme, .dark)
                        .offset(y: -(verticalTrackHeight + 8))
                        .opacity(expanded ? 1 : 0)
                        .allowsHitTesting(expanded)
                }
            } else {
                // Landscape: expand rightward inline in the same row.
                HStack(spacing: 6) {
                    Button { toggleExpanded() } label: {
                        Image(systemName: icon).modifier(ControlIcon())
                    }
                    horizontalSlider
                        .frame(width: expanded ? trackWidth : 0, height: 44)
                        .opacity(expanded ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(expanded)
                }
            }
        }
        .animation(.easeOut(duration: 0.22), value: expanded)
    }

    private var icon: String {
        if isMuted { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Horizontal slider (landscape)

    private var horizontalSlider: some View {
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
                        setPercent(Int((Double(min(1, max(0, v.location.x / w))) * 100).rounded()))
                    }
            )
        }
    }

    // MARK: - Vertical slider (portrait) — bottom = quiet, top = loud

    private var verticalSlider: some View {
        GeometryReader { geo in
            let h = max(geo.size.height - 22, 1)   // leave room for the value readout at the top
            let fill = CGFloat(min(1, max(0, volume)))
            VStack(spacing: 4) {
                Text("\(percent)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.28)).frame(width: 5)
                    Capsule().fill(.white).frame(width: 5, height: max(5, h * fill))
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .offset(y: -min(max(h * fill - 7, 0), h - 14))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Top of the track is louder, so invert the y position.
                        let y = v.location.y - 8 - 22        // subtract top padding + readout height
                        setPercent(Int((Double(min(1, max(0, 1 - y / h))) * 100).rounded()))
                    }
            )
        }
    }

    /// Apply a whole-percent volume with a per-step haptic tick and keep the controls awake.
    private func setPercent(_ pct: Int) {
        let clamped = min(100, max(0, pct))
        onChange(Double(clamped) / 100)
        if clamped != lastPct { lastPct = clamped; Haptics.selectionTick() }
        onInteract()
        armCollapse()
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
