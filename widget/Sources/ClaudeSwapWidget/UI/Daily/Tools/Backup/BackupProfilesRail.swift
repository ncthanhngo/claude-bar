import SwiftUI

/// Left rail of the Backup page: profile list + "new profile" + delete.
struct BackupProfilesRail: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette
    @State private var confirmDeleteID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("HỒ SƠ").font(.system(size: 10, weight: .bold)).tracking(1.1)
                    .foregroundColor(palette.ink3)
                Spacer()
                Button { store.newProfile() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }.buttonStyle(.plain).foregroundColor(palette.moss)
                    .help("Tạo hồ sơ sao lưu mới")
            }
            .padding(.horizontal, 10).padding(.bottom, 2)

            if store.profiles.isEmpty && store.draft == nil {
                Text("Trống").font(.system(size: 11)).foregroundColor(palette.ink3)
                    .padding(.horizontal, 12).padding(.top, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if store.isDirtyNew {
                        row(name: "Hồ sơ mới *", id: "", installed: false, selected: true)
                    }
                    ForEach(store.profiles) { p in
                        row(name: p.name.isEmpty ? "(chưa đặt tên)" : p.name,
                            id: p.id, installed: p.lastInstalledAt != nil,
                            selected: store.selectedID == p.id) {
                            store.select(p)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 172, alignment: .leading)
        .padding(.top, 4)
        .confirmationDialog("Xoá hồ sơ này?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) {
                if let id = confirmDeleteID { Task { await store.remove(id) } }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Chỉ xoá cấu hình trong app. Script/lịch trên server (nếu đã cài) vẫn còn — gỡ bằng nút Gỡ lịch trước.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDeleteID != nil }, set: { if !$0 { confirmDeleteID = nil } })
    }

    @ViewBuilder
    private func row(name: String, id: String, installed: Bool, selected: Bool,
                     _ select: (() -> Void)? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10))
                .foregroundColor(installed ? palette.moss : palette.ink3)
            Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? palette.ink : palette.ink2).lineLimit(1)
            Spacer(minLength: 0)
            if !id.isEmpty && selected {
                Button { confirmDeleteID = id } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(palette.coral)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.ink.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { select?() }
        .padding(.horizontal, 4)
    }
}
