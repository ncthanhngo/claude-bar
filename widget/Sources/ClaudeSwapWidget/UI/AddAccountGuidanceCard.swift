import SwiftUI

/// Bilingual (EN / VI) explainer rendered above the "Add account" button in
/// Settings → Accounts. The single recurring support question is "do I need
/// to `/logout` first?" — this card answers it before the user clicks Add.
struct AddAccountGuidanceCard: View {
    enum Lang: String, CaseIterable, Identifiable {
        case en, vi
        var id: String { rawValue }
        var label: String { self == .en ? "EN" : "VI" }
        var flag: String { self == .en ? "🇺🇸" : "🇻🇳" }
    }

    @AppStorage("addAccountGuidanceLang") private var langRaw: String = Lang.en.rawValue

    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            highlight
            steps
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 13, weight: .semibold))
            Text(lang == .en ? "Before you add an account" : "Trước khi thêm tài khoản")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            langPicker
        }
    }

    private var langPicker: some View {
        HStack(spacing: 2) {
            ForEach(Lang.allCases) { l in
                Button {
                    langRaw = l.rawValue
                } label: {
                    Text("\(l.flag) \(l.label)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                l == lang ? Color.accentColor.opacity(0.25) : Color.clear
                            )
                        )
                        .foregroundColor(l == lang ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var highlight: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.system(size: 12, weight: .bold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(lang == .en
                     ? "You do NOT need to `/logout` first."
                     : "KHÔNG cần `/logout` tài khoản hiện tại trước.")
                    .font(.system(size: 12, weight: .semibold))
                Text(lang == .en
                     ? "Claude Bar snapshots the active account's credentials before the new login overwrites them. Logging out first throws those tokens away and forces a re-login later."
                     : "Claude Bar tự sao lưu credentials của tài khoản đang dùng trước khi login mới ghi đè. Logout trước sẽ xóa token đang sống và bắt bạn đăng nhập lại sau này.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lang == .en ? "What happens when you click Add account:" : "Khi bạn bấm Add account, app sẽ:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            stepLine(1, lang == .en
                     ? "Snapshot the current active account into its backup slot."
                     : "Sao lưu tài khoản đang active vào slot backup riêng.")
            stepLine(2, lang == .en
                     ? "Open Terminal — run `claude`, then `/login`, finish in browser."
                     : "Mở Terminal — chạy `claude`, gõ `/login`, hoàn tất trên browser.")
            stepLine(3, lang == .en
                     ? "Click \"I'm logged in\" — the new account is captured into its own slot."
                     : "Bấm \"I'm logged in\" — tài khoản mới được lưu vào slot riêng.")
        }
    }

    private func stepLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 10))
                .padding(.top, 2)
            Text(lang == .en
                 ? "Never run `claude /login` outside this wizard — it skips the snapshot and silently wipes the active account's tokens."
                 : "Tuyệt đối không chạy `claude /login` ngoài wizard — sẽ bỏ qua bước snapshot và âm thầm xóa token của tài khoản đang active.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
