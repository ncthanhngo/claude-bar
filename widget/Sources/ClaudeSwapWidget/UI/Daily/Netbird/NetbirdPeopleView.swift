import SwiftUI

/// Manage the enrollment recipient directory — the people a single-use key can
/// be issued to and emailed. Add / edit / delete; stored locally. Reached from
/// the "Thêm máy" menu so issuing a key and curating who can receive one live
/// next to each other.
struct NetbirdPeopleView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    @State private var editing: NetbirdPerson?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Danh bạ người dùng").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Button { editing = NetbirdPerson(name: "") } label: {
                    Label("Thêm người", systemImage: "person.badge.plus").font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(palette.moss)
            }

            if let p = editing {
                personForm(p)
            }

            if coord.people.isEmpty {
                Text("Chưa có ai. Thêm người để cấp key enroll riêng và gửi email.")
                    .font(.system(size: 11.5)).foregroundColor(palette.ink3)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(coord.people) { person in
                            row(person)
                            if person.id != coord.people.last?.id {
                                Rectangle().fill(palette.line).frame(height: 1)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func row(_ person: NetbirdPerson) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(palette.ink)
                Text(subtitle(person)).font(.system(size: 10.5)).foregroundColor(palette.ink3).lineLimit(1)
            }
            Spacer()
            Button { editing = person } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(palette.ink3).help("Sửa")
            Button { coord.removePerson(person.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(palette.ink3).help("Xoá")
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
    }

    private func subtitle(_ p: NetbirdPerson) -> String {
        var parts: [String] = []
        let posTeam = [p.position, p.team].filter { !$0.isEmpty }.joined(separator: " · ")
        if !posTeam.isEmpty { parts.append(posTeam) }
        if !p.email.isEmpty { parts.append(p.email) }
        if !p.phone.isEmpty { parts.append(p.phone) }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private func personForm(_ p: NetbirdPerson) -> some View {
        let binding = Binding(get: { editing ?? p }, set: { editing = $0 })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Tên *", text: binding.name).textFieldStyle(.roundedBorder)
                TextField("Vị trí", text: binding.position).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                TextField("Team", text: binding.team).textFieldStyle(.roundedBorder)
                TextField("Email", text: binding.email).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                TextField("SĐT", text: binding.phone).textFieldStyle(.roundedBorder).frame(width: 160)
                Spacer()
                Button("Huỷ") { editing = nil }.buttonStyle(.plain).foregroundColor(palette.ink3)
                Button("Lưu") {
                    let v = binding.wrappedValue
                    coord.upsertPerson(v)
                    editing = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(binding.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
    }
}
