import SwiftUI

/// Termius-style SSH connection manager — the right half of the Workspace zone.
/// Lists saved hosts (shared with the cb_ssh_* tools), search, add/delete, and
/// one-click Connect into Terminal. Can seed itself from the NetBird servers.
struct SSHManagerView: View {
    let palette: BriefingPalette
    /// Mesh servers to offer as one-click imports: (display, host, defaultUser).
    let meshServers: [(name: String, host: String, user: String)]

    @StateObject private var store = SSHManagerStore()
    @State private var query = ""
    @State private var adding = false

    private var filtered: [CswClient.SSHHostDTO] {
        guard !query.isEmpty else { return store.hosts }
        let q = query.lowercased()
        return store.hosts.filter { $0.name.lowercased().contains(q) || $0.hostNameOr.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchBar
            if let err = store.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral)
            }
            VStack(spacing: 8) {
                ForEach(filtered) { h in hostRow(h) }
                if store.hosts.isEmpty { emptyState }
                if !untrackedMesh.isEmpty { meshImport }
            }
        }
        .padding(.top, 4)
        .task { await store.load() }
        .sheet(isPresented: $adding) { addSheet }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KẾT NỐI · SSH").font(.system(size: 11, weight: .bold)).tracking(1.4)
                    .foregroundColor(palette.gold)
                Text("Máy chủ").font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundColor(palette.ink)
            }
            Spacer()
            Button { adding = true } label: {
                Label("Thêm", systemImage: "plus").font(.system(size: 12, weight: .semibold))
            }.buttonStyle(.bordered)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(palette.ink3)
            TextField("Tìm máy chủ…", text: $query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }

    private func hostRow(_ h: CswClient.SSHHostDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 16)).foregroundColor(palette.ink2)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.paper2.opacity(0.6)))
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name).font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                Text(rowSubtitle(h)).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink3)
                    .lineLimit(1)
            }
            Spacer()
            Button { store.connect(h) } label: {
                Label("Connect", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
            }.buttonStyle(.borderedProminent)
            Button { Task { await store.remove(h.name) } } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundColor(palette.ink3)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func rowSubtitle(_ h: CswClient.SSHHostDTO) -> String {
        var s = h.target.isEmpty ? h.name : h.target
        if h.portOr > 0 { s += ":\(h.portOr)" }
        if !h.noteOr.isEmpty { s += "  · \(h.noteOr)" }
        return s
    }

    private var untrackedMesh: [(name: String, host: String, user: String)] {
        let tracked = Set(store.hosts.map(\.name))
        return meshServers.filter { !tracked.contains($0.name) }
    }

    private var meshImport: some View {
        Button {
            Task { await store.seedFromMesh(meshServers) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("Thêm \(untrackedMesh.count) máy chủ từ NetBird")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(palette.gold)
            .padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.gold.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.gold.opacity(0.35),
                                                                     style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "server.rack").font(.system(size: 26)).foregroundColor(palette.ink3)
            Text("Chưa có máy chủ nào.").font(.system(size: 13)).foregroundColor(palette.ink2)
            Text("Bấm Thêm, hoặc import từ NetBird bên dưới.")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: add sheet

    @State private var fName = ""
    @State private var fHost = ""
    @State private var fUser = ""
    @State private var fPort = ""
    @State private var fNote = ""

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thêm máy chủ").font(.system(size: 16, weight: .semibold))
            TextField("Tên hiển thị", text: $fName).textFieldStyle(.roundedBorder)
            TextField("Host / IP", text: $fHost).textFieldStyle(.roundedBorder)
            HStack {
                TextField("User", text: $fUser).textFieldStyle(.roundedBorder)
                TextField("Port (22)", text: $fPort).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            TextField("Ghi chú", text: $fNote).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Huỷ") { adding = false }
                Button("Lưu") {
                    Task {
                        await store.add(name: fName, host: fHost, port: Int(fPort) ?? 0, user: fUser, note: fNote)
                        fName = ""; fHost = ""; fUser = ""; fPort = ""; fNote = ""
                        adding = false
                    }
                }
                .buttonStyle(.borderedProminent).disabled(fName.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }
}
