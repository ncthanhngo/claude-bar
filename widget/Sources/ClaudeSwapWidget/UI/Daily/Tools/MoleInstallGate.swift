import SwiftUI

/// Gates a mole-powered App page: shows its content once `mo` is installed,
/// otherwise a one-time install call-to-action that runs mole's `install.sh`.
struct MoleInstallGate<Content: View>: View {
    let palette: BriefingPalette
    @ViewBuilder let content: () -> Content

    @ObservedObject private var mole = MoleInstaller.shared

    var body: some View {
        if mole.installed {
            content()
        } else {
            MoleInstallCTA(palette: palette, installer: mole)
        }
    }
}

/// The install prompt. Explains that mole powers these tools and offers to
/// install it (single admin prompt). Re-probes when it re-appears.
private struct MoleInstallCTA: View {
    let palette: BriefingPalette
    @ObservedObject var installer: MoleInstaller

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 34)).foregroundColor(palette.ink3)
            Text("Cần cài mole").font(.system(size: 16, weight: .semibold, design: .serif)).foregroundColor(palette.ink)
            Text("Các công cụ App (phân tích đĩa · file lớn · dọn rác · sức khoẻ máy) chạy bằng mole (mo). Cài một lần từ script chính chủ — không đóng gói sẵn.")
                .font(.system(size: 11.5)).foregroundColor(palette.ink3)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if let err = installer.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral).multilineTextAlignment(.center)
            }
            Button {
                installer.install()
            } label: {
                HStack(spacing: 6) {
                    if installer.installing { ProgressView().controlSize(.small) }
                    Text(installer.installing ? "Đang cài…" : "Cài mole")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).tint(palette.moss).disabled(installer.installing)
            Text("brew install mole — nếu bạn muốn tự cài bằng Homebrew.")
                .font(.system(size: 10)).foregroundColor(palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { installer.refresh() }
    }
}
