import Foundation

struct PlayerScore: Identifiable, Hashable {
    let id: Int
    let name: String
    let position: String
    var points: Double
    /// ESPN's full-game projection for this week.
    var projected: Double = 0
    /// NFL team id (matches ESPN's NFL scoreboard team ids). 0 = unknown.
    var proTeamId: Int = 0
    /// ESPN headshot (or the NFL team's logo for a D/ST). nil = show a placeholder.
    var headshotURL: URL? = nil

    var shortName: String {
        if position == "D/ST" { return name }
        let parts = name.split(separator: " ")
        guard parts.count >= 2, let initial = parts.first?.first else { return name }
        return "\(initial). \(parts.dropFirst().joined(separator: " "))"
    }
}

struct TeamScore: Identifiable, Hashable {
    let id: Int
    let name: String
    let abbrev: String
    var points: Double
    var starters: [PlayerScore]
    /// Expected final score (points so far + remaining projection). nil if unknown.
    var projectedTotal: Double? = nil

    /// Short name for score rows: your nickname if you set one, else ESPN's abbreviation.
    var label: String { Nicknames.nickname(for: name) ?? abbrev }
}

/// Short team names. Saved on this Apple TV; Config.teamNicknames supplies defaults.
enum Nicknames {
    static let maxLength = 8
    private static func key(_ teamName: String) -> String { "nickname." + teamName }

    /// The nickname typed on this Apple TV ("" if none).
    static func saved(for teamName: String) -> String {
        UserDefaults.standard.string(forKey: key(teamName)) ?? ""
    }

    static func nickname(for teamName: String) -> String? {
        let typed = saved(for: teamName).trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        if let preset = Config.teamNicknames[teamName], !preset.isEmpty { return preset }
        return nil
    }

    static func set(_ value: String, for teamName: String) {
        let trimmed = String(value.prefix(maxLength))
        if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.removeObject(forKey: key(teamName))
        } else {
            UserDefaults.standard.set(trimmed, forKey: key(teamName))
        }
    }
}

struct MatchupScore: Identifiable, Hashable {
    let id: Int
    var home: TeamScore
    var away: TeamScore?
    /// Our estimate of the home team's chance to win (0...1). nil if unknown.
    var homeWinProbability: Double? = nil

    var teams: [TeamScore] { [home] + (away.map { [$0] } ?? []) }

    func winProbability(for teamId: Int) -> Double? {
        guard let p = homeWinProbability else { return nil }
        return teamId == home.id ? p : 1 - p
    }

    var leaderId: Int? {
        guard let away else { return nil }
        if home.points > away.points + 0.001 { return home.id }
        if away.points > home.points + 0.001 { return away.id }
        return nil
    }

    func team(_ id: Int) -> TeamScore? { teams.first { $0.id == id } }
    func opponent(of id: Int) -> TeamScore? { home.id == id ? away : home }
}

struct LeagueSnapshot {
    let week: Int
    let matchups: [MatchupScore]
    /// This week's NFL games (for the game filter + win probability).
    var games: [NFLGame] = []

    var allTeams: [TeamScore] {
        matchups.flatMap(\.teams).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct NFLGame: Identifiable, Hashable {
    let id: String
    let name: String        // "BUF @ KC"
    let teamIds: [Int]      // ESPN NFL team ids (same as fantasy proTeamId)
    let remaining: Double   // share of the game left: 1 = not started, 0 = final
    let detail: String      // "Sun 1:00 PM", "Q2 4:31", "Final"
}

/// Which alerts to show. Empty set = everything.
struct AlertFilter {
    var teamIds: Set<Int> = []
    /// NFL team ids playing in the selected games. nil = all games.
    var proTeamIds: Set<Int>? = nil

    func allowsTeam(_ id: Int) -> Bool { teamIds.isEmpty || teamIds.contains(id) }
    func allowsPlayer(_ p: PlayerScore) -> Bool { proTeamIds?.contains(p.proTeamId) ?? true }
}

struct PlayerChange: Hashable {
    var player: PlayerScore
    var delta: Double
}

struct ScoreEvent: Identifiable {
    enum Kind {
        case scoring([PlayerChange])
        case leadChange
    }

    let id = UUID()
    var kind: Kind
    var team: TeamScore
    var opponent: TeamScore?
    /// `team`'s chance to win the matchup at the time of this alert.
    var winProbability: Double? = nil
    /// The same numbers just before this change, to show how the matchup moved.
    var previousWinProbability: Double? = nil
    var previousTeam: TeamScore? = nil
    var previousOpponent: TeamScore? = nil

    var isLeadChange: Bool {
        if case .leadChange = kind { return true }
        return false
    }

    var totalDelta: Double {
        if case .scoring(let changes) = kind { return changes.reduce(0) { $0 + $1.delta } }
        return 0
    }

    var tickerText: String {
        switch kind {
        case .scoring(let changes):
            let top = changes.first.map { " · \($0.player.shortName) \($0.delta.signedString)" } ?? ""
            return "\(team.label) \(totalDelta.signedString)\(top)"
        case .leadChange:
            return "\(team.label) takes the lead" + (opponent.map { " vs \($0.label)" } ?? "")
        }
    }
}

/// ESPN's NFL team ids, for D/ST logos.
enum NFLTeams {
    static let abbrev: [Int: String] = [
        1: "atl", 2: "buf", 3: "chi", 4: "cin", 5: "cle", 6: "dal", 7: "den", 8: "det",
        9: "gb", 10: "ten", 11: "ind", 12: "kc", 13: "lv", 14: "lar", 15: "mia", 16: "min",
        17: "ne", 18: "no", 19: "nyg", 20: "nyj", 21: "phi", 22: "ari", 23: "pit", 24: "lac",
        25: "sf", 26: "sea", 27: "tb", 28: "wsh", 29: "car", 30: "jax", 33: "bal", 34: "hou",
    ]

    static func logoURL(proTeamId: Int) -> URL? {
        guard let a = abbrev[proTeamId] else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/nfl/500/\(a).png")
    }
}

enum ESPNPosition {
    static func name(_ id: Int?) -> String {
        switch id {
        case 1: return "QB"
        case 2: return "RB"
        case 3: return "WR"
        case 4: return "TE"
        case 5: return "K"
        case 16: return "D/ST"
        default: return ""
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }

    var formatted1: String { String(format: "%.1f", self) }

    /// Like signedString, with a real minus sign for big display text.
    var displaySigned: String { signedString.replacingOccurrences(of: "-", with: "−") }

    /// "+6.0", "-2.0", "+0.40" (two decimals for tiny yardage ticks)
    var signedString: String {
        let fmt = (abs(self) < 1 && self != 0) ? "%.2f" : "%.1f"
        return (self >= 0 ? "+" : "") + String(format: fmt, self)
    }
}
