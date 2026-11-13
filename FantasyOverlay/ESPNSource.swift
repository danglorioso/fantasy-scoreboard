import Foundation

protocol ScoreSource {
    func fetchSnapshot() async throws -> LeagueSnapshot
}

enum ESPNError: LocalizedError {
    case notConfigured
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Fill in Config.swift (league ID + cookies), or turn on Demo mode."
        case .http(401), .http(403): return "ESPN rejected the cookies (HTTP 401/403). Re-copy espn_s2 and SWID."
        case .http(404): return "League not found (HTTP 404). Check leagueID and season."
        case .http(let code): return "ESPN returned HTTP \(code)."
        case .badResponse(let msg): return "Couldn't read ESPN response: \(msg)"
        }
    }
}

/// Talks to ESPN's (unofficial) fantasy v3 API — the same endpoints cwendt94/espn-api uses.
struct ESPNSource: ScoreSource {
    let leagueID: String
    let season: Int
    let espnS2: String
    let swid: String

    private var baseURL: URL {
        URL(string: "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/\(season)/segments/0/leagues/\(leagueID)")!
    }

    func fetchSnapshot() async throws -> LeagueSnapshot {
        guard Config.isConfigured else { throw ESPNError.notConfigured }

        // 1) Which week is it + team names
        let meta = try await get(views: ["mStatus", "mTeam"], scoringPeriod: nil)
        let week = meta.scoringPeriodId ?? 1
        let matchupPeriod = meta.status?.currentMatchupPeriod ?? week
        var teamsById: [Int: ESPNLeague.Team] = [:]
        for t in meta.teams ?? [] { teamsById[t.id] = t }

        // 2) Live box scores for this week (includes starters' fantasy points + projections),
        //    and NFL game clocks for the win-probability estimate, fetched in parallel.
        async let gamesTask = try? NFLGameClock.fetchGames()
        let live = try await get(views: ["mMatchupScore", "mBoxscore"], scoringPeriod: week)
        let games = await gamesTask
        var clock: [Int: Double]? = nil
        if let games {
            var map: [Int: Double] = [:]
            for g in games { for t in g.teamIds { map[t] = g.remaining } }
            clock = map
        }

        let matchups: [MatchupScore] = (live.schedule ?? [])
            .filter { $0.matchupPeriodId == matchupPeriod }
            .compactMap { m in
                guard let home = m.home else { return nil }
                var matchup = MatchupScore(
                    id: m.id,
                    home: teamScore(home, teamsById, week),
                    away: m.away.map { teamScore($0, teamsById, week) }
                )
                if let clock {
                    // Teams not on the scoreboard (bye) have nothing left to play.
                    WinProbability.annotate(&matchup) { clock[$0] ?? 0 }
                }
                return matchup
            }

        return LeagueSnapshot(week: week, matchups: matchups, games: games ?? [])
    }

    private func teamScore(_ side: ESPNLeague.Side, _ teams: [Int: ESPNLeague.Team], _ week: Int) -> TeamScore {
        let entries = side.rosterForCurrentScoringPeriod?.entries ?? []
        let starters: [PlayerScore] = entries
            .filter { $0.lineupSlotId != 20 && $0.lineupSlotId != 21 } // 20 = bench, 21 = IR
            .map { e in
                let player = e.playerPoolEntry?.player
                // statSourceId 0 = actual stats, 1 = ESPN projection
                let weekStat = player?.stats?.first { $0.scoringPeriodId == week && $0.statSourceId == 0 }?.appliedTotal
                let projection = player?.stats?.first { $0.scoringPeriodId == week && $0.statSourceId == 1 }?.appliedTotal
                let pts = weekStat ?? e.playerPoolEntry?.appliedStatTotal ?? 0
                return PlayerScore(
                    id: e.playerId,
                    name: player?.fullName ?? "Player \(e.playerId)",
                    position: ESPNPosition.name(player?.defaultPositionId),
                    points: pts.rounded(toPlaces: 2),
                    projected: projection ?? 0,
                    proTeamId: player?.proTeamId ?? 0
                )
            }

        let total = starters.isEmpty
            ? (side.totalPointsLive ?? side.totalPoints ?? 0)
            : starters.reduce(0) { $0 + $1.points }

        let t = teams[side.teamId]
        let fullName = t?.name
            ?? [t?.location, t?.nickname].compactMap { $0 }.joined(separator: " ")
        let name = fullName.isEmpty ? "Team \(side.teamId)" : fullName
        let abbrev = t?.abbrev ?? String(name.prefix(4)).uppercased()

        return TeamScore(id: side.teamId, name: name, abbrev: abbrev,
                         points: total.rounded(toPlaces: 2), starters: starters)
    }

    private func get(views: [String], scoringPeriod: Int?) async throws -> ESPNLeague {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var items = views.map { URLQueryItem(name: "view", value: $0) }
        if let scoringPeriod { items.append(URLQueryItem(name: "scoringPeriodId", value: String(scoringPeriod))) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpShouldHandleCookies = false
        req.setValue("espn_s2=\(espnS2); SWID=\(swid)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ESPNError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(ESPNLeague.self, from: data)
        } catch {
            throw ESPNError.badResponse(error.localizedDescription)
        }
    }
}

// MARK: - Raw ESPN JSON (only the fields we use; everything optional)

struct ESPNLeague: Decodable {
    let scoringPeriodId: Int?
    let status: Status?
    let teams: [Team]?
    let schedule: [Matchup]?

    struct Status: Decodable { let currentMatchupPeriod: Int? }

    struct Team: Decodable {
        let id: Int
        let abbrev: String?
        let name: String?
        let location: String?
        let nickname: String?
    }

    struct Matchup: Decodable {
        let id: Int
        let matchupPeriodId: Int?
        let home: Side?
        let away: Side?
    }

    struct Side: Decodable {
        let teamId: Int
        let totalPoints: Double?
        let totalPointsLive: Double?
        let rosterForCurrentScoringPeriod: Roster?
    }

    struct Roster: Decodable { let entries: [Entry]? }

    struct Entry: Decodable {
        let playerId: Int
        let lineupSlotId: Int
        let playerPoolEntry: PoolEntry?
    }

    struct PoolEntry: Decodable {
        let appliedStatTotal: Double?
        let player: Player?
    }

    struct Player: Decodable {
        let fullName: String?
        let defaultPositionId: Int?
        let proTeamId: Int?
        let stats: [Stat]?
    }

    struct Stat: Decodable {
        let scoringPeriodId: Int?
        let statSourceId: Int?
        let appliedTotal: Double?
    }
}
