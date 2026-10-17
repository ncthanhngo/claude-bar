import SwiftUI
import SMCKit

/// Fan tab of the popover: live speed of every fan plus Auto / Max / Custom
/// control. Changing the mode asks for the admin password once, the first
/// time, to install the fan helper (see `FanControlStore`).
struct FanPopoverTab: View {
    @StateObject private var store = FanControlStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .task { await store.poll() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Fan")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            if store.isApplying {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if store.fans.isEmpty {
            Text("Mac này không có quạt hoặc không đọc được quạt.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.fans) { FanRow(fan: $0, showIndex: store.fans.count > 1) }
                    controls
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { store.mode }, set: { store.select($0) })) {
                ForEach(FanMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(store.isApplying)

            if store.mode == .custom {
                HStack(spacing: 8) {
                    Slider(value: $store.customRPM, in: store.rpmRange, step: 100) { editing in
                        if !editing { store.commitCustomRPM() }
                    }
                    Text("\(Int(store.customRPM)) rpm")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }

            Text(store.error ?? hint)
                .font(.system(size: 10))
                .foregroundColor(store.error == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var hint: String {
        switch store.mode {
        case .auto: return "macOS tự điều chỉnh quạt theo nhiệt độ."
        case .max: return "Quạt chạy tốc độ tối đa. Thoát app sẽ trả về Auto."
        case .custom: return "Thả thanh trượt để áp dụng. Thoát app sẽ trả về Auto."
        }
    }
}

private struct FanRow: View {
    let fan: FanReading
    let showIndex: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "fan")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if showIndex {
                    Text("Fan \(fan.index + 1)").font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Text("\(Int(fan.actual.rounded()))")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("rpm").font(.system(size: 11)).foregroundColor(.secondary)
            }
            ProgressView(value: min(max(fan.actual - fan.min, 0), fan.max - fan.min), total: max(fan.max - fan.min, 1))
                .tint(.accentColor)
            HStack {
                Text("\(Int(fan.min))")
                Spacer()
                Text(fan.isManual ? "target \(Int(fan.target.rounded()))" : "auto")
                Spacer()
                Text("\(Int(fan.max))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
