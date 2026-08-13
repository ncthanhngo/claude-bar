import SwiftUI

/// GitLab pipeline status as returned by the API.
/// Reference: https://docs.gitlab.com/ee/api/pipelines.html
///
/// Ported from GitLabBar. `isActive` is the single source of truth for the
/// "a pipeline is running" state that drives the menu-bar swap.
enum PipelineStatus: String, Codable, Sendable, CaseIterable {
    case created
    case waitingForResource = "waiting_for_resource"
    case preparing
    case pending
    case running
    case success
    case failed
    case canceled
    case skipped
    case manual
    case scheduled

    /// Best-effort decoding for unknown values GitLab may add in the future.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PipelineStatus(rawValue: raw) ?? .pending
    }

    /// `true` when the pipeline is occupying CI resources right now. This is
    /// what flips the menu bar to the pipeline indicator; when no watched
    /// pipeline is active the bar reverts to the default Claude usage label.
    var isActive: Bool {
        switch self {
        case .created, .waitingForResource, .preparing, .pending, .running:
            return true
        default:
            return false
        }
    }

    /// SF Symbol that visually represents this state.
    var sfSymbol: String {
        switch self {
        case .running, .preparing:            return "arrow.triangle.2.circlepath"
        case .created, .pending,
             .waitingForResource, .scheduled: return "clock"
        case .success:                        return "checkmark.circle.fill"
        case .failed:                         return "xmark.octagon.fill"
        case .canceled:                       return "minus.circle.fill"
        case .skipped:                        return "forward.fill"
        case .manual:                         return "hand.point.up.left.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running, .preparing:                                return .orange
        case .pending, .created, .waitingForResource, .scheduled: return .yellow
        case .success:                                            return .green
        case .failed:                                             return .red
        case .canceled, .skipped:                                 return .secondary
        case .manual:                                             return .blue
        }
    }

    /// Short label shown in the popover row.
    var displayName: String {
        switch self {
        case .waitingForResource: return "waiting"
        default:                  return rawValue
        }
    }
}
