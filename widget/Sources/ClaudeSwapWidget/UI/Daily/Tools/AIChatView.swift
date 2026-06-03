import SwiftUI

/// Chat-style AI advisor content, hosted in its own movable window by
/// `AIChatWindowController`. The host passes a steering `system` prompt, a
/// `context` (the current scan / state as text), and suggested first questions;
/// the user can keep asking follow-ups in the same session.
struct AIChatView: View {
    let palette: BriefingPalette
    let system: String
    let context: String
    let suggestions: [String]

    @StateObject private var advisor = AIAdvisor()
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            transcript
            if let e = advisor.error {
                Text(e).font(.system(size: 11)).foregroundColor(palette.coral)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }
            if advisor.messages.isEmpty { suggestionChips }
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.paper)
        .onAppear { advisor.configure(system: system, context: context) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(palette.plum)
            Text("Trợ lý: \(AIAdvisor.providerLabel)").font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink2)
            Spacer()
            if !advisor.messages.isEmpty {
                Button { advisor.reset() } label: {
                    Label("Hỏi lại", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3).help("Bắt đầu hội thoại mới")
            }
        }
        .padding(14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(advisor.messages) { m in bubble(m).id(m.id) }
                    if advisor.isThinking, advisor.messages.last?.text.isEmpty == true {
                        HStack(spacing: 6) { ProgressView().controlSize(.small)
                            Text("Đang nghĩ…").font(.system(size: 11)).foregroundColor(palette.ink3) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: advisor.messages.last?.text) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func bubble(_ m: AIAdvisor.Msg) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(m.text).font(.system(size: 12.5)).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(palette.plum))
            }
        } else {
            HStack {
                Text(m.text.isEmpty ? " " : LocalizedStringKey(m.text))
                    .font(.system(size: 12.5)).foregroundColor(palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
                Spacer(minLength: 40)
            }
        }
    }

    private var suggestionChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(suggestions, id: \.self) { q in
                Button { send(q) } label: {
                    Text(q).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(palette.plum.opacity(0.12)))
                        .foregroundColor(palette.plum)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Hỏi thêm…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
                .onSubmit { send(input) }
            Button { send(input) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain).foregroundColor(palette.plum)
            .disabled(advisor.isThinking || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        Task { await advisor.send(q) }
    }
}

/// Compact "✨ Hỏi AI" button the Tools tabs drop into their toolbar to open the
/// chat sheet. Label tracks the active provider.
struct AIAskButton: View {
    let palette: BriefingPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Hỏi \(AIAdvisor.providerLabel)", systemImage: "sparkles")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .buttonStyle(.borderedProminent).tint(palette.plum)
    }
}

