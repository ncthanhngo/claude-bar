import SwiftUI

/// Typed classification of a failed `csw switch` attempt. Parsed once at the
/// AppStore boundary so the UI never has to substring-match raw backend
/// strings to decide which icon/tone/CTA to show.
///
/// Wording recognized:
///   • "credentials need login again"   → .needsRelogin (terminal, re-auth)
///   • "swap deferred ... rate limited" → .rateLimited  (transient, auto-retry hint)
///   • "swap deferred ..."              → .transient    (network/5xx, retry hint)
///   • "swap busy ..."                  → .busy         (lock contention)
///   • everything else                  → .unknown
struct SwapError: Equatable, Identifiable {
    enum Kind: Equatable {
        case needsRelogin
        case rateLimited
        case transient
        case busy
        case unknown
    }

    let id = UUID()
    let kind: Kind
    let targetAccount: Int
    let targetName: String
    let rawMessage: String

    init(targetAccount: Int, targetName: String, message: String) {
        self.targetAccount = targetAccount
        self.targetName = targetName
        self.rawMessage = message
        let lower = message.lowercased()
        if lower.contains("credentials need login again") || lower.contains("need login again") {
            self.kind = .needsRelogin
        } else if lower.contains("swap busy") || lower.contains("file lock acquire timeout") {
            self.kind = .busy
        } else if lower.contains("rate limited") || lower.contains("429") {
            self.kind = .rateLimited
        } else if lower.contains("swap deferred") || lower.contains("retry shortly") {
            self.kind = .transient
        } else {
            self.kind = .unknown
        }
    }

    var iconName: String {
        switch kind {
        case .needsRelogin: return "person.crop.circle.badge.exclamationmark"
        case .rateLimited:  return "clock.badge.exclamationmark"
        case .transient:    return "arrow.clockwise.circle"
        case .busy:         return "lock.circle"
        case .unknown:      return "exclamationmark.triangle.fill"
        }
    }

    var accent: Color {
        switch kind {
        case .needsRelogin: return .red
        case .rateLimited:  return .orange
        case .transient:    return .orange
        case .busy:         return .yellow
        case .unknown:      return .red
        }
    }

    var title: String {
        switch kind {
        case .needsRelogin: return "Cần đăng nhập lại"
        case .rateLimited:  return "Đang bị giới hạn tốc độ"
        case .transient:    return "Tạm thời chưa đổi được"
        case .busy:         return "Có thao tác khác đang chạy"
        case .unknown:      return "Chuyển account không thành công"
        }
    }

    var headline: String {
        "Không chuyển sang \(targetName)"
    }

    /// Friendly explanation. Drops technical noise; keeps the actionable part.
    var explanation: String {
        switch kind {
        case .needsRelogin:
            return "Refresh token của tài khoản này đã bị thu hồi. Mở Add account và đăng nhập lại để khôi phục."
        case .rateLimited:
            return "Anthropic OAuth đang chặn vì refresh quá dày. Thử lại sau ~1 phút — không cần đăng nhập lại."
        case .transient:
            return "Lỗi tạm thời khi refresh token (mạng hoặc server). Thử lại sau một lát — không cần đăng nhập lại."
        case .busy:
            return "Một tiến trình csw khác đang giữ lock (thường do swap song song). Thử lại sau vài giây."
        case .unknown:
            return rawMessage
        }
    }

    /// True if Retry button should be the primary action.
    var allowsRetry: Bool { kind != .needsRelogin }

    /// True if a re-login flow should be offered.
    var suggestsRelogin: Bool { kind == .needsRelogin }
}
