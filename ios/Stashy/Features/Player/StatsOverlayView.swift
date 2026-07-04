import SwiftUI
import UIKit

/// A clean, translucent on-video diagnostics panel. Refreshes once a second via `TimelineView` (off the
/// render path), pulling a fresh `PlaybackStats` snapshot from the model. Section-based so the future
/// Stash-transcoder stats slot in without changing this view.
struct StatsOverlayView: View {
    let scene: StashScene
    let model: ScenePlayerModel
    /// The direct file URL to demux-probe with FFmpeg (debug; runs once when the overlay opens).
    var probeURL: URL?
    /// Landscape fullscreen → a wider box (more fits per row); portrait → a taller box.
    var isLandscape = false
    @State private var demux = "probing…"
    @State private var loopback = "testing…"
    @State private var debugLogging = RemoteLog.isLoggingEnabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            panel(model.snapshotStats(scene: scene))
        }
        .task(id: probeURL) {
            guard let probeURL else { demux = "no direct stream"; loopback = "no direct stream"; return }
            demux = await FFmpegSource(url: probeURL).probeSummary()
            loopback = await LoopbackProbe(url: probeURL).run()
        }
    }

    /// Snapshot the key window to JPEG for upload. Runs on the main actor (button action). Captures the
    /// UIKit/SwiftUI layer tree only — AVPlayer/Metal-backed video renders black in a UIKit snapshot.
    @MainActor
    static func captureWindowJPEG() -> Data? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first
        else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.jpegData(compressionQuality: 0.6)
    }

    private func panel(_ stats: PlaybackStats) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(stats.sections) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                        ForEach(section.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.label)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 88, alignment: .leading)
                                Text(line.value)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                }

                // FFmpeg demux probe of the direct file (proof the custom-AVIO interop works).
                VStack(alignment: .leading, spacing: 3) {
                    Text("FFMPEG DEMUX")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(demux)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Loopback self-test: remux the direct file to a temp MP4, serve it over the local HTTP
                // server, fetch the opening bytes back, and confirm it's a valid MP4 — proving the whole
                // remux→file→server→client chain the AVPlayer feed will use.
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOOPBACK SERVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(loopback)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Debug log streaming to ntfy (off by default — broadcasts to a public topic).
                Toggle(isOn: $debugLogging) {
                    Text("DEBUG LOG → ntfy/\(RemoteLog.topic)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .tint(.white.opacity(0.6))
                .onChange(of: debugLogging) { _, on in
                    RemoteLog.isLoggingEnabled = on
                    if on { RemoteLog.shared.enable() } else { RemoteLog.shared.disable() }
                }

                // Manual screenshot → ntfy attachment (only useful while logging is on). Note: a UIKit
                // window snapshot can't capture the AVPlayer/Metal video layer, so the video area reads
                // black — this is for UI/layout/overlay bugs; the video pixels are diagnosed via the text
                // stream (presentationSize / transcode-frame1) instead.
                if debugLogging {
                    Button {
                        if let data = Self.captureWindowJPEG() {
                            RemoteLog.shared.uploadImage(data, caption: "manual · \(scene.title ?? "scene")")
                        }
                    } label: {
                        Label("Send screenshot", systemImage: "camera")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: isLandscape ? 360 : 280)
        .frame(maxHeight: isLandscape ? 230 : 420)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }
}
