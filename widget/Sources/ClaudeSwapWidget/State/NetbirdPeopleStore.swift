import Foundation

/// One person who can be issued an enrollment key — the requester directory the
/// admin maintains so a single-use key can be named after, and emailed to, a
/// specific human (instead of a generic "dev-enroll" key shared around).
/// Non-secret contact metadata; persisted locally in UserDefaults.
struct NetbirdPerson: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var position: String   // vị trí / chức danh
    var team: String
    var email: String
    var phone: String

    init(id: String = UUID().uuidString, name: String, position: String = "",
         team: String = "", email: String = "", phone: String = "") {
        self.id = id
        self.name = name
        self.position = position
        self.team = team
        self.email = email
        self.phone = phone
    }
}

/// On-disk registry of enrollment recipients. Stored as a JSON-string under
/// `netbird.people.v1.json` so the PreferencesCloudSync whitelist (string-only)
/// carries it across Macs. Legacy Data blob at `netbird.people.v1` is read once
/// for migration.
enum NetbirdPeopleStore {
    private static let key = "netbird.people.v1.json"
    private static let legacyKey = "netbird.people.v1"

    static func load() -> [NetbirdPerson] {
        if let s = UserDefaults.standard.string(forKey: key),
           let data = s.data(using: .utf8),
           let people = try? JSONDecoder().decode([NetbirdPerson].self, from: data) {
            return people
        }
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let people = try? JSONDecoder().decode([NetbirdPerson].self, from: data)
        else { return [] }
        save(people) // write-back so iCloud sync picks up legacy data on first launch
        return people
    }

    static func save(_ people: [NetbirdPerson]) {
        guard let data = try? JSONEncoder().encode(people),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: key)
    }
}
