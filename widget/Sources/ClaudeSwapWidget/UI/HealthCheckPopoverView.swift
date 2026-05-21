import SwiftUI

enum HealthCheckResult {
    case healthy(Int)
    case issues(failed: [AccountVerificationDTO])
    case failed(String)
}

struct HealthCheckPopoverView: View {
    let result: HealthCheckResult
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultBody
            HStack {
                Spacer()
                Button("Dismiss") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var resultBody: some View {
        switch result {
        case .healthy(let count):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 4) {
                    Text("All accounts healthy")
                        .font(.callout).fontWeight(.semibold)
                    Text("\(count) account\(count == 1 ? "" : "s") checked — credentials refreshed")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

        case .issues(let failed):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16))
                    Text("\(failed.count) issue\(failed.count == 1 ? "" : "s") found")
                        .font(.callout).fontWeight(.semibold)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failed) { acc in
                            failedAccountRow(acc)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

        case .failed(let msg):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Health check failed")
                        .font(.callout).fontWeight(.semibold)
                    Text(msg)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(4)
                }
            }
        }
    }

    private func failedAccountRow(_ acc: AccountVerificationDTO) -> some View {
        let failedChecks = acc.checks.filter { !$0.passed && $0.skipped != true }
        return VStack(alignment: .leading, spacing: 4) {
            Text(acc.displayName)
                .font(.caption).fontWeight(.semibold)
            ForEach(failedChecks) { check in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 10))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.label).font(.caption2)
                        if let detail = check.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
