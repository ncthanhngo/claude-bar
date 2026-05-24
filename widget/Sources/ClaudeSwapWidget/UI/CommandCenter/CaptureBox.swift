import SwiftUI

/// Top-of-source-bar capture box. Free-text input parses `#list @assignee
/// !priority due <day>` tokens locally and renders a live preview so the
/// user sees what will be created before they hit ⌘↩.
///
/// Submit routes through the chat tab's send pipeline so the LLM sees the
/// capture and decides whether to invoke `cb_clickup_capture` (which then
/// hits the write-gate). The widget never calls cb_clickup_capture
/// directly — the gate's Origin field would be OriginLLM, defeating the
/// purpose of trust-capture. Once the dedicated `csw capture` RPC lands,
/// this view can call it with OriginCapture.
struct CaptureBox: View {
    @EnvironmentObject var chatStore: ChatStore
    @State private var input = ""
    @FocusState private var focused: Bool

    private var parsed: CaptureParseResult { parseCapture(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "plus.app").foregroundColor(.accentColor)
                TextField("Add task — #list @assignee !priority due fri", text: $input, onCommit: submit)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                Button("Add") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(parsed.title.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
            )
            if !input.isEmpty {
                previewLine
            }
        }
    }

    private var previewLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundColor(.secondary).font(.system(size: 9))
            chip(parsed.list ?? "Inbox", color: .blue, icon: "tray")
            if let p = parsed.priority {
                chip(p, color: priorityColor(p), icon: "flag.fill")
            }
            ForEach(parsed.assignees, id: \.self) { a in
                chip("@" + a, color: .purple, icon: "person.fill")
            }
            if let d = parsed.due {
                chip("due " + d, color: .orange, icon: "calendar")
            }
            Spacer()
            Text(parsed.title).font(.system(size: 11)).foregroundColor(.primary).lineLimit(1)
        }
        .padding(.horizontal, 10)
    }

    private func chip(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "urgent", "high": return .red
        case "low": return .secondary
        default: return .orange
        }
    }

    private func submit() {
        let p = parsed
        guard !p.title.isEmpty else { return }
        var lines = ["Tạo task ClickUp với capture:"]
        lines.append("- Title: \(p.title)")
        if let l = p.list { lines.append("- List: #\(l)") }
        if let pr = p.priority { lines.append("- Priority: \(pr)") }
        if !p.assignees.isEmpty { lines.append("- Assignees: " + p.assignees.joined(separator: ", ")) }
        if let d = p.due { lines.append("- Due: \(d)") }
        lines.append("Gọi cb_clickup_capture với origin=capture.")
        chatStore.sendCurrent(text: lines.joined(separator: "\n"))
        input = ""
    }
}

// MARK: - Local parser (mirror of backend ParseCapture in Go)

struct CaptureParseResult: Equatable {
    var title: String
    var list: String?
    var priority: String?
    var assignees: [String]
    var due: String?
}

/// Pure parser mirroring `backend/internal/mcp/clickup_capture.go::ParseCapture`.
/// Kept in sync with the Go side so the preview matches what the backend
/// will receive when cb_clickup_capture fires.
func parseCapture(_ input: String) -> CaptureParseResult {
    var result = CaptureParseResult(title: "", list: nil, priority: nil, assignees: [], due: nil)
    let priorityWords: [String: String] = [
        "!urgent": "urgent", "!high": "high", "!normal": "normal", "!low": "low",
    ]
    let tokens = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var keep: [String] = []
    var pendingDue = false
    for t in tokens {
        if pendingDue {
            result.due = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            pendingDue = false
            continue
        }
        if t.hasPrefix("#") && t.count > 1 {
            if result.list == nil {
                result.list = String(t.dropFirst())
                continue
            }
        }
        if t.hasPrefix("@") && t.count > 1 {
            result.assignees.append(String(t.dropFirst()))
            continue
        }
        if let p = priorityWords[t.lowercased()] {
            result.priority = p
            continue
        }
        if t.lowercased() == "due" {
            pendingDue = true
            continue
        }
        keep.append(t)
    }
    result.title = keep.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return result
}
