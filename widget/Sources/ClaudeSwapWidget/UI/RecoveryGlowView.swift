import SwiftUI

/// Soft, additive "logging in" glow overlaid on a popover account row while a
/// hidden credential-recovery re-login is in flight. Because the re-login runs
/// in an off-screen window, this is the user's only signal that something is
/// happening.
///
/// Replicates the Briefing-page glow aesthetic — a radial gradient softened
/// with blur and composited with `.plusLighter` so it reads as light rather
/// than paint — animated as a gentle pulse. The view only animates while it is
/// on screen (it appears solely during `.recovering`), so there is no idle
/// cost. Honours Reduce Motion by holding a steady glow instead of pulsing.
struct RecoveryGlowView: View {
    var accent: Color = .orange

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(
                RadialGradient(
                    colors: [
                        .white.opacity(0.55),
                        accent.opacity(0.45),
                        accent.opacity(0.12),
                        .clear
                    ],
                    center: .leading,
                    startRadius: 0,
                    endRadius: 130
                )
            )
            .blur(radius: 4)
            .blendMode(.plusLighter)
            .opacity(reduceMotion ? 0.6 : (pulsing ? 0.85 : 0.35))
            .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.0 : 0.99))
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
