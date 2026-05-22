import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Profile chip occupying the top-left of the Daily window header. Click the
/// avatar to upload a new image (PNG/JPEG/HEIC), click the name to rename in
/// place. Persists to `AppSettings.dailyProfileName` /
/// `dailyProfileAvatarPath` so the chip survives relaunch.
struct DailyProfileBrand: View {
    let palette: BriefingPalette

    @ObservedObject private var settings = AppSettings.shared

    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    private let avatarSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarButton
            VStack(alignment: .leading, spacing: 2) {
                nameField
                Text("DAILY · CLAUDE BAR")
                    .font(.system(size: 10))
                    .kerning(1.4)
                    .foregroundColor(palette.ink3)
            }
        }
    }

    // MARK: - Avatar

    @ViewBuilder private var avatarButton: some View {
        Button(action: pickAvatar) {
            ZStack {
                Circle()
                    .fill(palette.paper2)
                Circle()
                    .stroke(palette.line2, lineWidth: 1)

                if let image = loadedAvatar {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                } else {
                    Text(initial)
                        .font(.system(size: 16, weight: .semibold, design: .serif).italic())
                        .foregroundColor(palette.coral)
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(palette.coral)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "camera.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(palette.paper)
                    )
                    .overlay(Circle().stroke(palette.paper, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Click để đổi avatar")
        .contextMenu {
            Button("Chọn ảnh…", action: pickAvatar)
            if !settings.dailyProfileAvatarPath.isEmpty {
                Button("Xoá avatar", role: .destructive, action: clearAvatar)
            }
        }
    }

    // MARK: - Name

    @ViewBuilder private var nameField: some View {
        if isEditingName {
            TextField("Tên của bạn", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .serif).italic())
                .foregroundColor(palette.ink)
                .frame(minWidth: 120, maxWidth: 240)
                .focused($nameFieldFocused)
                .onSubmit(commitName)
                .onExitCommand(perform: cancelEditingName)
                .onAppear { nameFieldFocused = true }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused && isEditingName { commitName() }
                }
        } else {
            Button(action: beginEditingName) {
                Text(displayName)
                    .font(.system(size: 22, weight: .semibold, design: .serif).italic())
                    .foregroundColor(palette.coral)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Click để đổi tên")
        }
    }

    // MARK: - Derived

    private var displayName: String {
        let trimmed = settings.dailyProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Bạn" : trimmed
    }

    private var initial: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    /// Re-reads the on-disk PNG whenever `dailyProfileAvatarVersion` changes
    /// so a re-upload to the same path still re-renders.
    private var loadedAvatar: NSImage? {
        _ = settings.dailyProfileAvatarVersion
        guard !settings.dailyProfileAvatarPath.isEmpty else { return nil }
        return ProfileAvatarStore.load()
    }

    // MARK: - Actions

    private func beginEditingName() {
        draftName = settings.dailyProfileName
        isEditingName = true
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.dailyProfileName = trimmed
        isEditingName = false
    }

    private func cancelEditingName() {
        isEditingName = false
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.title = "Chọn avatar"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]

        // The Daily window sits above NSWindow.Level.statusBar so a default
        // modal panel would render *behind* it. Mirror the
        // LocalMCPSettingsView pattern: lower the host window, present as a
        // sheet, restore on dismiss.
        if let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        {
            let originalLevel = window.level
            window.level = .normal
            panel.beginSheetModal(for: window) { response in
                window.level = originalLevel
                guard response == .OK, let url = panel.url else { return }
                applyPickedAvatar(url: url)
            }
            return
        }

        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPickedAvatar(url: url)
    }

    private func applyPickedAvatar(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            NSSound.beep()
            return
        }
        guard let saved = ProfileAvatarStore.save(image) else {
            NSSound.beep()
            return
        }
        settings.dailyProfileAvatarPath = saved.path
        settings.dailyProfileAvatarVersion &+= 1
    }

    private func clearAvatar() {
        ProfileAvatarStore.clear()
        settings.dailyProfileAvatarPath = ""
        settings.dailyProfileAvatarVersion &+= 1
    }
}
