import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ThemedBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer().frame(height: 60)

                    // Logo mark
                    StashyLogoView()
                        .frame(width: 88, height: 88)

                    VStack(spacing: 6) {
                        Text("Stashy")
                            .font(.largeTitle.bold())
                            .foregroundStyle(themeManager.current.foregroundColor)
                        Text("Connect to your Stash server")
                            .font(.subheadline)
                            .foregroundStyle(themeManager.current.foregroundColor.opacity(0.6))
                    }

                    // Connection form
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Server URL", systemImage: "server.rack")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(themeManager.current.foregroundColor.opacity(0.7))
                            TextField("http://192.168.1.100:9999", text: $serverURL)
                                .textFieldStyle(.plain)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Label("API Key", systemImage: "key")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(themeManager.current.foregroundColor.opacity(0.7))
                            SecureField("Paste your API key", text: $apiKey)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }

                        if let error = errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(error)
                                    .font(.caption)
                            }
                            .foregroundStyle(.red)
                            .padding(10)
                            .glassEffect(.regular.tint(.red), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Button {
                            connect()
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.85)
                                }
                                Text(isConnecting ? "Connecting…" : "Connect")
                                    .font(.body.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(serverURL.isEmpty || apiKey.isEmpty || isConnecting)
                        .animation(.easeInOut(duration: 0.15), value: isConnecting)
                    }
                    .padding(24)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))

                    Text("Generate an API key in Stash → Settings → Security")
                        .font(.caption2)
                        .foregroundStyle(themeManager.current.foregroundColor.opacity(0.4))
                        .multilineTextAlignment(.center)

                    Spacer()
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await appState.connect(serverURL: serverURL, apiKey: apiKey)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

// MARK: - Logo

struct StashyLogoView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [themeManager.current.accentColor, themeManager.current.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Film strip + play mark
            ZStack {
                // Horizontal film strip bar
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.9))
                    .frame(width: 56, height: 14)

                // Film perforations
                HStack(spacing: 10) {
                    ForEach(0..<4) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(themeManager.current.accentColor)
                            .frame(width: 5, height: 7)
                    }
                }

                // Play triangle
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -1)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
        }
        .frame(width: 88, height: 88)
        .shadow(color: themeManager.current.accentColor.opacity(0.4), radius: 12, y: 6)
    }
}
