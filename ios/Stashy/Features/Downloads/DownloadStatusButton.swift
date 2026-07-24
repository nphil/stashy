import SwiftUI

/// Tiny floating glass status button for the root browse screens (bottom-trailing, above the tab bar):
/// a colored progress ring with a live % while any download / server or on-device transcode is active;
/// tapping it jumps to the Downloads tab. Hidden entirely when idle, so normal browsing pays nothing.
///
/// Glass note: the owner asked for glass here. The big glass-over-scroll landmine was a FULL-WIDTH bar
/// re-sampling the whole moving grid; this is a single ~52 pt circle — a negligible sampling region —
/// and its live updates ride the existing 120 ms transfer poll, which already pauses during scrolls.
struct DownloadStatusButton: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppRouter.self) private var router
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        let status = downloads.floatingStatus
        ZStack {
            if let status {
                Button {
                    router.selectedTab = .downloads
                } label: {
                    ZStack {
                        Circle()
                            .stroke(themeManager.current.foregroundColor.opacity(0.18), lineWidth: 3.5)
                        Circle()
                            .trim(from: 0, to: max(0.02, status.progress))   // a sliver even at 0% reads "alive"
                            .stroke(themeManager.current.accentColor,
                                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: -1) {
                            Text("\(Int((status.progress * 100).rounded()))")
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .contentTransition(.numericText())
                            if status.count > 1 {
                                Text("×\(status.count)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(themeManager.current.foregroundColor)
                    }
                    .padding(9)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Downloads in progress — \(Int((status.progress * 100).rounded())) percent")
            }
        }
        .animation(.snappy(duration: 0.3), value: status != nil)
    }
}

extension View {
    /// Attach the floating download-status button to a ROOT screen (Scenes / Performers / Settings).
    /// Pushed detail screens cover it naturally; the Downloads screen doesn't need it.
    func downloadStatusOverlay() -> some View {
        overlay(alignment: .bottomTrailing) {
            DownloadStatusButton()
                .padding(.trailing, 16)
                .padding(.bottom, 12)
        }
    }
}
