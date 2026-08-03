import SwiftUI

/// What the glasses show when connected but with nothing better to display (logged out, or the home
/// has no content). Pure black — micro-OLED black is pixels-off, and the themed mesh would glow in a
/// dark room. The glyph breathes slowly so a static frame doesn't read as a hang.
struct GlassesIdleCard: View {
    /// Guidance line under the wordmark ("Pick something on your phone", "Remote closed — resume from
    /// phone"). Empty hides it.
    var hint: String = ""
    @State private var breathe = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(.white.opacity(breathe ? 0.30 : 0.16))
                Text("Stashy")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
