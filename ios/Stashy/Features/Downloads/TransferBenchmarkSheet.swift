import SwiftUI

/// Medium-detent sheet that runs `TransferBenchmark` against the current scene and shows the result.
/// Reached from the scene ••• menu; transient, so it costs the browse/player paths nothing.
///
/// Dismissal cancels the run — an abandoned benchmark would otherwise keep pulling hundreds of
/// megabytes with no UI attached.
struct TransferBenchmarkSheet: View {
    let scene: StashScene
    let apiKey: String
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @State private var benchmark = TransferBenchmark()
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // The player behind this sheet keeps streaming the same file from the same server,
                    // which would compete with the measurement. Pausing is the user's call — the player
                    // is load-bearing and not worth reaching into for a diagnostic.
                    Label("Pause the video first — it streams from the same server and will skew the result.",
                          systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Text("Times six reads of this scene — one connection, eight requests, and eight with "
                         + "the per-host limit lifted — each twice, in A B C C B A order so a warm server "
                         + "cache can't favour whichever ran last. Nothing is saved; the bytes are counted "
                         + "and discarded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(benchmark.totalMegabytes > 0
                         ? "Transferred about \(benchmark.totalMegabytes) MB."
                         : "Transfers up to about 580 MB on Wi-Fi, about 145 MB on cellular.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let error = benchmark.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if benchmark.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(benchmark.status)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !benchmark.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Average").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(benchmark.summary) { row in
                                resultRow(row.label, row.megabytesPerSecond, emphasised: true)
                            }
                        }
                    }

                    if let transport = benchmark.transportNote {
                        Text("Transport: \(transport)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    if let verdict = benchmark.verdict {
                        Text(verdict)
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(themeManager.current.accentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !benchmark.runs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Individual runs (A B C C B A)")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(benchmark.runs) { run in
                                resultRow(run.label, run.megabytesPerSecond, emphasised: false)
                            }
                        }
                    }

                    Button {
                        runTask?.cancel()
                        runTask = Task { await benchmark.run(scene: scene, apiKey: apiKey) }
                    } label: {
                        Label(benchmark.summary.isEmpty ? "Run Benchmark" : "Run Again",
                              systemImage: "speedometer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(benchmark.isRunning)
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Transfer Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .onDisappear {
            runTask?.cancel()
            benchmark.cancel()
        }
    }

    private func resultRow(_ label: String, _ rate: Double, emphasised: Bool) -> some View {
        HStack {
            Text(label)
                .font(emphasised ? .callout.weight(.medium) : .caption)
            Spacer(minLength: 8)
            Text(String(format: "%.1f MB/s", rate))
                .font((emphasised ? Font.callout.weight(.semibold) : Font.caption).monospacedDigit())
                .foregroundStyle(emphasised ? themeManager.current.accentColor : .secondary)
        }
    }
}
