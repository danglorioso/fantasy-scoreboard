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
    /// This week's running stat totals, keyed by ESPN stat id (see PlayType).
    var stats: [String: Double] = [:]

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
    /// What happened, e.g. "TOUCHDOWN · 18 YDS" or "RECEPTION · 12 YDS". nil if unknown.
    var play: String? = nil
}

/// Works out what kind of play produced a point change by comparing a player's stat
/// totals before and after. ESPN stat ids (from its fantasy API):
///   3 pass yds · 4 pass TD · 20 INT thrown · 24 rush yds · 25 rush TD · 42 rec yds
///   43 rec TD · 53 receptions · 72 fumbles lost · 19/26/44 two-point conversions
///   74 FG 50+ · 77 FG 40–49 · 80 FG under 40 · 83 FG made · 86 extra point
///   93 blocked kick TD · 95 INT · 96 fumble recovery · 98 safety · 99 sack
///   101 kickoff return TD · 102 punt return TD · 103 fumble return TD · 104 INT return TD
enum PlayType {
    static func label(before: [String: Double], after: [String: Double], position: String) -> String? {
        guard !after.isEmpty else { return nil }
        func d(_ id: String) -> Double { (after[id] ?? 0) - (before[id] ?? 0) }
        func n(_ id: String) -> Int { Int(d(id).rounded()) }
        func yds(_ id: String) -> String { "\(Int(d(id).rounded())) YDS" }
        func times(_ count: Int, _ one: String, _ many: String) -> String { count > 1 ? "\(count) \(many)" : one }

        if position == "D/ST" {
            if n("104") > 0 { return "PICK SIX" }
            if n("103") > 0 { return "FUMBLE RETURN TD" }
            if n("101") > 0 || n("102") > 0 { return "RETURN TD" }
            if n("93") > 0 { return "BLOCKED KICK TD" }
            if n("98") > 0 { return "SAFETY" }
            if n("95") > 0 { return times(n("95"), "INTERCEPTION", "INTERCEPTIONS") }
            if n("96") > 0 { return "FUMBLE RECOVERY" }
            if n("99") > 0 { return times(n("99"), "SACK", "SACKS") }
            return nil
        }
        if position == "K" {
            if n("74") > 0 { return "FIELD GOAL · 50+ YDS" }
            if n("77") > 0 { return "FIELD GOAL · 40–49 YDS" }
            if n("83") > 0 || n("80") > 0 { return times(max(n("83"), n("80")), "FIELD GOAL", "FIELD GOALS") }
            if n("86") > 0 { return times(n("86"), "EXTRA POINT", "EXTRA POINTS") }
            return nil
        }

        if n("43") > 0 { return d("42") > 0 ? "TOUCHDOWN · \(yds("42"))" : "TOUCHDOWN" }
        if n("25") > 0 { return d("24") > 0 ? "TOUCHDOWN · \(yds("24"))" : "TOUCHDOWN" }
        if n("4") > 0 {
            let label = times(n("4"), "TD PASS", "TD PASSES")
            return d("3") > 0 ? "\(label) · \(yds("3"))" : label
        }
        if n("20") > 0 { return times(n("20"), "INTERCEPTION", "INTERCEPTIONS") }
        if n("72") > 0 { return "FUMBLE LOST" }
        if n("19") + n("26") + n("44") > 0 { return "2-PT CONVERSION" }
        if n("53") > 0 { return "\(times(n("53"), "RECEPTION", "CATCHES")) · \(yds("42"))" }
        if abs(d("24")) >= 1 { return "RUSH · \(yds("24"))" }
        if abs(d("3")) >= 1 { return "PASSING · \(yds("3"))" }
        if abs(d("42")) >= 1 { return "RECEIVING · \(yds("42"))" }
        return nil
    }
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
