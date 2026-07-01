import SwiftUI
import LocalAuthentication

/// Biometric (Face ID / Touch ID) app lock with passcode fallback.
enum AppLock {
    /// Whether the device can perform owner authentication (biometry or passcode).
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"
        let policy: LAPolicy = .deviceOwnerAuthentication // biometrics, falling back to passcode
        guard context.canEvaluatePolicy(policy, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: "Unlock Stashy") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Covers the app with a lock screen and requires authentication whenever app lock is enabled and
/// the app returns to the foreground.
private struct AppLockModifier: ViewModifier {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked = false
    @State private var isAuthenticating = false

    func body(content: Content) -> some View {
        ZStack {
            content
            if appLockEnabled && !isUnlocked {
                lockScreen
            }
        }
        .onAppear(perform: evaluate)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: evaluate()
            case .background: isUnlocked = false // re-lock when fully backgrounded
            default: break
            }
        }
        .onChange(of: appLockEnabled) { _, enabled in
            if enabled { isUnlocked = false; evaluate() } else { isUnlocked = true }
        }
    }

    // Minimal privacy cover — a heavy blur (so content isn't visible while locked) with just a small
    // lock glyph. No "locked" splash/headline or prominent button: Face ID is triggered automatically the
    // moment the app becomes active, so the extra chrome only added a perceived delay. Tapping anywhere
    // re-triggers Face ID if the previous prompt was dismissed/cancelled.
    private var lockScreen: some View {
        ZStack {
            Rectangle().fill(.thickMaterial).ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: evaluate)
    }

    private func evaluate() {
        guard appLockEnabled, !isUnlocked, !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let ok = await AppLock.authenticate()
            isUnlocked = ok
            isAuthenticating = false
        }
    }
}

extension View {
    func appLock() -> some View { modifier(AppLockModifier()) }
}
