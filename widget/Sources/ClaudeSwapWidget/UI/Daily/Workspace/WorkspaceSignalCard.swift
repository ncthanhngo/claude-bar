import SwiftUI
import AppKit

/// One row in the Workspace feed: source chip + the action title/context, a
/// deep-link "Mở →", and an expandable AI draft with approve→execute controls.
struct WorkspaceSignalCard: View {
    let signal: WorkspaceSignalDTO
    let isNew: Bool
    let palette: BriefingPalette

    @StateObject private var model = WorkspaceCardModel()
    @State private var confirming = false
    @State private var refine = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            if model.expanded { draftSection.padding(.top, 12) }
            if let e = model.error { errorRow(e) }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.raisedSurface)
                .shadow(color: palette.cardShadow, radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isNew ? palette.coral.opacity(0.55) : palette.line, lineWidth: isNew ? 1.5 : 1)
        )
        .opacity(model.executed ? 0.6 : 1)
        .confirmationDialog("Gửi phản hồi này?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Gửi") { Task { await model.execute(signal) } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(confirmTarget)
        }
    }

    // MARK: top row

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            sourceChip
            VStack(alignment: .leading, spacing: 4) {
                Text(signal.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.ink).lineLimit(2)
                if !signal.context.isEmpty {
                    Text(signal.context)
                        .font(.system(size: 12)).foregroundColor(palette.ink2).lineLimit(2)
                }
                metaLine
            }
            Spacer(minLength: 8)
            trailingControls
        }
    }

    @ViewBuilder private var trailingControls: some View {
        if model.executed {
            Label("Đã gửi", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(palette.moss)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                pillButton("Soạn", icon: "sparkles", filled: true) { model.toggle(signal) }
                if let link = signal.deepLink, !link.isEmpty {
                    pillButton("Mở →", icon: nil, filled: false) { open(link) }
                }
            }
        }
    }

    // MARK: draft section

    @ViewBuilder private var draftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(palette.line)
            if model.isDrafting && model.draft.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Đang soạn…").font(.system(size: 12)).foregroundColor(palette.ink3)
                }
            } else {
                TextEditor(text: $model.draft)
                    .font(.system(size: 12.5))
                    .frame(minHeight: 70, maxHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
                if let r = model.rationale, !r.isEmpty {
                    Text(r).font(.system(size: 10.5).italic()).foregroundColor(palette.ink3)
                }
                refineRow
                actionRow
            }
        }
    }

    private var refineRow: some View {
        HStack(spacing: 6) {
            TextField("Chỉnh: ngắn hơn, lịch sự hơn…", text: $refine)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1))
            Button {
                let ins = refine; refine = ""
                Task { await model.draftNow(signal, instruction: ins) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(palette.ink2)
            .disabled(model.isDrafting || refine.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Chỉnh lại bản nháp")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            pillButton("Copy", icon: "doc.on.doc", filled: false) { copyDraft() }
            pillButton("Soạn lại", icon: "sparkles", filled: false) {
                Task { await model.draftNow(signal) }
            }
            .disabled(model.isDrafting)
            Spacer()
            if signal.isExecutable {
                Button { confirming = true } label: {
                    HStack(spacing: 5) {
                        if model.isExecuting { ProgressView().scaleEffect(0.5) }
                        Text("Thực thi").font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(palette.coral))
                }
                .buttonStyle(.plain)
                .disabled(model.isExecuting || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func errorRow(_ e: String) -> some View {
        Text(e).font(.system(size: 11)).foregroundColor(palette.coral).padding(.top, 8)
    }

    // MARK: pieces

    private var sourceChip: some View {
        VStack(spacing: 5) {
            Image(systemName: sourceIcon)
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(sourceColor))
            Circle().fill(urgencyColor).frame(width: 6, height: 6)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if !signal.actor.isEmpty {
                Text(signal.actor).font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink3)
                Text("·").foregroundColor(palette.ink3)
            }
            Text(timeLabel).font(.system(size: 11)).foregroundColor(palette.ink3)
        }
    }

    private func pillButton(_ title: String, icon: String?, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(filled ? palette.ink : palette.ink2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(filled ? palette.ink.opacity(0.07) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: actions + styling

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.draft, forType: .string)
    }

    private var confirmTarget: String {
        switch signal.kind {
        case .mention, .dm: return "Gửi reply tới \(signal.actor.isEmpty ? "Slack" : signal.actor)."
        case .taskDue:      return "Thêm comment vào task ClickUp."
        default:            return "Thực thi hành động."
        }
    }

    private var sourceIcon: String {
        switch signal.source {
        case .slack: return "number"; case .gmail: return "envelope.fill"
        case .clickup: return "checklist"; case .gcal: return "calendar"
        }
    }
    private var sourceColor: Color {
        switch signal.source {
        case .slack: return palette.plum; case .gmail: return palette.coral
        case .clickup: return palette.moss; case .gcal: return palette.gold
        }
    }
    private var urgencyColor: Color {
        switch signal.urgency {
        case .urgent: return palette.coral; case .soon: return palette.gold; case .normal: return palette.ink3
        }
    }
    private var timeLabel: String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        switch signal.kind {
        case .meetingNow:  return "đang diễn ra"
        case .taskDue:     return signal.context.isEmpty ? fmt.string(from: signal.timestamp) : ""
        default:           return fmt.string(from: signal.timestamp)
        }
    }
}
