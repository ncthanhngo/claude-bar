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

/// On-disk registry of enrollment recipients. Stored as a JSON blob in
/// UserDefaults to match the other local NetBird metadata stores (colors,
/// notes, roles) — non-secret, machine-local.
enum NetbirdPeopleStore {
    private static let key = "netbird.people.v1"

    static func load() -> [NetbirdPerson] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let people = try? JSONDecoder().decode([NetbirdPerson].self, from: data)
        else { return [] }
        return people
    }

    static func save(_ people: [NetbirdPerson]) {
        guard let data = try? JSONEncoder().encode(people) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
