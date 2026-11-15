import Foundation

/// Rough live win probability for a fantasy matchup. Only used when ESPN doesn't send its
/// own (ESPN's `winProbability` is preferred), e.g. in the invented demo league.
///
/// Expected final = points so far + (projection × share of that player's NFL game left).
/// Uncertainty grows with how much of each player's game is left. The gap between the
/// two expected finals, divided by the combined uncertainty, gives the win chance.
enum WinProbability {
    /// - Parameter remaining: share of an NFL team's game still to play (1 = not started, 0 = final).
    static func home(_ home: TeamScore, vs away: TeamScore, remaining: (Int) -> Double) -> Double {
        let h = outlook(home, remaining)
        let a = outlook(away, remaining)
        let diff = h.mean - a.mean
        let sd = (h.variance + a.variance).squareRoot()
        if sd < 0.05 { return diff > 0.001 ? 1 : (diff < -0.001 ? 0 : 0.5) }
        return normalCDF(diff / sd)
    }

    static func expectedFinal(_ team: TeamScore, remaining: (Int) -> Double) -> Double {
        outlook(team, remaining).mean
    }

    /// Fills in projected totals and the home win probability.
    static func annotate(_ m: inout MatchupScore, remaining: (Int) -> Double) {
        m.home.projectedTotal = expectedFinal(m.home, remaining: remaining)
        if let away = m.away {
            m.away?.projectedTotal = expectedFinal(away, remaining: remaining)
            m.homeWinProbability = home(m.home, vs: away, remaining: remaining)
        }
    }

    private static func outlook(_ team: TeamScore, _ remaining: (Int) -> Double) -> (mean: Double, variance: Double) {
        var mean = 0.0, variance = 0.0
        for p in team.starters {
            let left = min(1, max(0, remaining(p.proTeamId)))
            let proj = max(p.projected, 0)
            mean += p.points + proj * left
            // Fallback only (the app uses ESPN's own win probability when it has one).
            // Tuned so this estimate lands close to ESPN's numbers.
            let sd = 1.1 * max(proj, 3) * left.squareRoot()
            variance += sd * sd
        }
        return (mean, variance)
    }

    private static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }
}

/// This week's NFL games + live clocks from ESPN's public scoreboard (no login needed).
enum NFLGameClock {
    static func fetchGames() async throws -> [NFLGame] {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard")!
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        let board = try JSONDecoder().decode(Scoreboard.self, from: data)

        return (board.events ?? []).compactMap { event in
            guard let id = event.id else { return nil }
            let left: Double
            switch event.status?.type?.state {
            case "pre": left = 1
            case "post": left = 0
            case "in":
                let period = event.status?.period ?? 1
                let clock = event.status?.clock ?? 0
                left = period <= 4 ? (Double(4 - period) * 900 + clock) / 3600 : 0.02 // OT
            default: left = 1
            }
            let teamIds = (event.competitions?.first?.competitors ?? []).compactMap { $0.team?.id }.compactMap(Int.init)
            return NFLGame(id: id,
                           name: event.shortName ?? event.name ?? "Game \(id)",
                           teamIds: teamIds,
                           remaining: min(1, max(0, left)),
                           detail: event.status?.type?.shortDetail ?? "")
        }
    }

    private struct Scoreboard: Decodable {
        let events: [Event]?
        struct Event: Decodable {
            let id: String?
            let name: String?
            let shortName: String?
            let status: Status?
            let competitions: [Competition]?
        }
        struct Status: Decodable {
            let clock: Double?
            let period: Int?
            let type: StatusType?
        }
        struct StatusType: Decodable {
            let state: String?
            let shortDetail: String?
        }
        struct Competition: Decodable { let competitors: [Competitor]? }
        struct Competitor: Decodable { let team: Team? }
        struct Team: Decodable { let id: String? }
    }
}
