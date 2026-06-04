import SwiftUI

/// Chat with the active Claude account as a server-ops assistant. It proposes
/// shell commands; read-only ones run automatically, anything that mutates the
/// server gates behind `ServerCommandConfirmSheet`. Command results render as
/// their own cells and are fed back so the assistant continues the job.
struct ServerAgentView: View {
    @ObservedObject var store: ServerAgentStore
    let palette: BriefingPalette

    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            if store.selectedHost == nil {
                noHostState
            } else {
                transcript
                if let e = store.error {
                    Text(e).font(.system(size: 11)).foregroundColor(palette.coral)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                }
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
        .task { await store.loadHosts() }
        .sheet(isPresented: confirmBinding) {
            if let cmd = store.pendingCommand {
                ServerCommandConfirmSheet(
                    command: cmd, host: store.selectedHost ?? "", palette: palette,
                    onRun: { store.approvePending() },
                    onCancel: { store.declinePending() }
                )
            }
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { store.pendingCommandID != nil }, set: { if !$0 { store.declinePending() } })
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(palette.plum)
            Text("Trợ lý máy chủ").font(.system(size: 12, weight: .semibold)).foregroundColor(palette.ink)
            Spacer()
            hostPicker
            if !store.cells.isEmpty {
                Button { store.reset() } label: {
                    Label("Mới", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3).help("Bắt đầu hội thoại mới")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var hostPicker: some View {
        Group {
            if store.hosts.isEmpty {
                Text("Chưa có host — thêm ở Netbird → SSH")
                    .font(.system(size: 10.5)).foregroundColor(palette.coral)
            } else {
                Picker("", selection: Binding(
                    get: { store.selectedHost ?? "" },
                    set: { store.selectedHost = $0 }
                )) {
                    ForEach(store.hosts) { h in
                        Text(h.name + (h.hostName.map { " · \($0)" } ?? "")).tag(h.name)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 220)
                .disabled(!store.cells.isEmpty)   // lock host once a session is underway
                .help(store.cells.isEmpty ? "Chọn máy chủ" : "Bấm Mới để đổi máy chủ")
            }
        }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.cells.isEmpty { emptyHint }
                    ForEach(store.cells) { cell in
                        cellView(cell).id(cell.id)
                    }
                    if store.isBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Đang xử lý…").font(.system(size: 11)).foregroundColor(palette.ink3)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: store.cells.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func cellView(_ cell: ServerAgentStore.Cell) -> some View {
        switch cell {
        case .user(_, let t):
            HStack {
                Spacer(minLength: 40)
                Text(t).font(.system(size: 12.5)).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(palette.plum))
            }
        case .assistant(_, let t):
            HStack {
                Text(t.isEmpty ? " " : LocalizedStringKey(t))
                    .font(.system(size: 12.5)).foregroundColor(palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
                Spacer(minLength: 40)
            }
        case .command(let c):
            ServerCommandCell(command: c, palette: palette)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nhờ trợ lý cài đặt / cấu hình máy chủ")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
            Text("VD: “Cài Docker và docker compose”, “Kiểm tra dung lượng đĩa còn trống”, “Dựng nginx reverse proxy cho cổng 3000”.")
                .font(.system(size: 11.5)).foregroundColor(palette.ink3)
            Text("Lệnh chỉ-đọc chạy tự động; lệnh thay đổi máy chủ sẽ hỏi xác nhận trước.")
                .font(.system(size: 11)).foregroundColor(palette.ink3).italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // MARK: composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Nhập yêu cầu cho máy chủ…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain).foregroundColor(palette.plum)
            .disabled(!store.canSend || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
    }

    private func send() {
        let q = input
        input = ""
        store.send(q)
    }

    private var noHostState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 30)).foregroundColor(palette.ink3)
            Text("Chưa có máy chủ SSH").font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)
            Text("Thêm host ở Netbird → SSH rồi quay lại để trò chuyện với trợ lý.")
                .font(.system(size: 12)).foregroundColor(palette.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One executed/proposed command rendered in the transcript: the command line,
/// a risk badge, a status glyph, and (when finished) collapsible output.
struct ServerCommandCell: View {
    let command: ServerAgentStore.Command
    let palette: BriefingPalette
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusGlyph
                Text(command.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(palette.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                riskBadge
            }
            if hasOutput {
                Button { expanded.toggle() } label: {
                    Label(expanded ? "Ẩn kết quả" : "Xem kết quả (mã \(command.exitCode ?? -1))",
                          systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5)).foregroundColor(palette.ink3)
                }
                .buttonStyle(.plain)
                if expanded {
                    ScrollView {
                        Text(outputText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(palette.ink2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line2, lineWidth: 1))
    }

    private var hasOutput: Bool {
        command.status == .succeeded || command.status == .failed
    }

    private var outputText: String {
        let parts = [command.stdout, command.stderr.isEmpty ? "" : "[stderr] " + command.stderr]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "(không có output)" : parts.joined(separator: "\n")
    }

    @ViewBuilder private var statusGlyph: some View {
        switch command.status {
        case .pendingConfirm: Image(systemName: "hand.raised.fill").foregroundColor(palette.gold)
        case .running:        ProgressView().controlSize(.small)
        case .succeeded:      Image(systemName: "checkmark.circle.fill").foregroundColor(palette.moss)
        case .failed:         Image(systemName: "xmark.octagon.fill").foregroundColor(palette.coral)
        case .declined:       Image(systemName: "nosign").foregroundColor(palette.ink3)
        }
    }

    private var riskBadge: some View {
        let (text, color): (String, Color)
        switch command.risk {
        case .low:         (text, color) = ("đọc", palette.moss)
        case .medium:      (text, color) = ("thay đổi", palette.gold)
        case .destructive: (text, color) = ("nguy hiểm", palette.coral)
        }
        return Text(text).font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }
}
