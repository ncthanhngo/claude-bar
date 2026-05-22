import Foundation

/// One headline pulled from an RSS / Atom feed configured in
/// `AppSettings.briefingNewsFeedsJSON`. Lightweight shape — title + source
/// label + permalink + publish date. Body / image are intentionally absent;
/// the PLAN reading card surfaces a one-line teaser only.
struct NewsItemDTO: Identifiable, Hashable {
    let feedID: UUID
    let feedLabel: String
    let title: String
    let link: String
    let publishedAt: Date?

    /// Composite ID since RSS items don't carry a stable URN we can trust
    /// across renders.
    var id: String { "\(feedID.uuidString):\(link)" }
}
