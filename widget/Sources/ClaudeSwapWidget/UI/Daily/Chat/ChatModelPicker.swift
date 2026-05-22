import SwiftUI

/// Model definitions surfaced by the picker. Kept in the widget so the UI
/// can pre-render without an RPC; backend's models_catalog.go is the source
/// of truth at request time — pickable ids must stay aligned.
struct ChatModelOption: Identifiable, Hashable {
    let id: String           // Anthropic model ID
    let displayName: String
    let blurb: String
    let badge: String
    let badgeColor: Color
    let tag: String?
}

enum ChatModelCatalog {
    static func defaults(palette: BriefingPalette) -> [ChatModelOption] {
        [
            ChatModelOption(
                id: "claude-opus-4-7",
                displayName: "Claude Opus 4.7",
                blurb: "Mạnh nhất · suy luận sâu, code phức tạp",
                badge: "O", badgeColor: palette.plum, tag: "Pro"
            ),
            ChatModelOption(
                id: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                blurb: "Cân bằng · nhanh + chất lượng cao",
                badge: "S", badgeColor: palette.coral, tag: "mặc định"
            ),
            ChatModelOption(
                id: "claude-haiku-4-5-20251001",
                displayName: "Claude Haiku 4.5",
                blurb: "Nhanh nhất · prompt ngắn, tiết kiệm quota",
                badge: "H", badgeColor: palette.sage, tag: "rẻ"
            ),
        ]
    }
}

/// Compact pill that opens the model picker menu. Tapping a model:
///  - With an active conversation: calls the backend to update that
///    conversation's stored model, so the *next* SendMessage uses it. The
///    local snapshot is patched immediately so the pill label updates
///    without waiting for a list refresh.
///  - Without an active conversation: just updates `preferredModel`, which
///    is the default used when `newConversation()` runs.
struct ChatModelPicker: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette

    var body: some View {
        Menu {
            ForEach(ChatModelCatalog.defaults(palette: palette)) { opt in
                Button {
                    Task { await chatStore.setActiveConversationModel(opt.id) }
                } label: {
                    HStack {
                        Text(opt.displayName)
                        if opt.id == currentModelID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Text("OAuth từ tài khoản active · /v1/messages stateless")
        } label: {
            HStack(spacing: 6) {
                badge
                Text(currentSpec.displayName.replacingOccurrences(of: "Claude ", with: ""))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(palette.ink)
                Text("▾").font(.system(size: 9)).foregroundColor(palette.ink3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(palette.paper)
            .overlay(Capsule().stroke(palette.line2, lineWidth: 1))
            .clipShape(Capsule())
        }
        // `.borderlessButton` style strips the label content down to just the
        // first Text node — the badge and the chevron disappear, leaving the
        // pill looking like a bare "S". Use `.button` so SwiftUI renders the
        // full custom HStack label, and hide the system arrow with
        // `.menuIndicator(.hidden)`. `.buttonStyle(.plain)` keeps macOS from
        // wrapping it in the default bordered button chrome.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentModelID: String {
        chatStore.activeConversation?.model ?? chatStore.preferredModel
    }

    private var currentSpec: ChatModelOption {
        ChatModelCatalog.defaults(palette: palette)
            .first(where: { $0.id == currentModelID })
            ?? ChatModelCatalog.defaults(palette: palette)[1]
    }

    @ViewBuilder private var badge: some View {
        Text(currentSpec.badge)
            .font(.system(size: 9, weight: .bold, design: .serif).italic())
            .foregroundColor(palette.paper)
            .frame(width: 16, height: 16)
            .background(Circle().fill(currentSpec.badgeColor))
    }
}
