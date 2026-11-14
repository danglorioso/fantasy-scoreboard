import Foundation
import UIKit

protocol ScoreSource {
    func fetchSnapshot() async throws -> LeagueSnapshot
}

enum ESPNError: LocalizedError {
    case notConfigured
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Fill in Secrets.swift (league ID + cookies), or turn on Demo mode."
        case .http(401), .http(403): return "ESPN rejected the cookies (HTTP 401/403). Re-copy espn_s2 and SWID."
        case .http(404): return "League not found (HTTP 404). Check leagueID and season."
        case .http(let code): return "ESPN returned HTTP \(code)."
        case .badResponse(let msg): return "Couldn't read ESPN response: \(msg)"
        }
    }
}

/// Talks to ESPN's (unofficial) fantasy v3 API — the same endpoints cwendt94/espn-api uses.
///
/// Each check makes one request (live box scores). League info and NFL game clocks are
/// cached and refreshed on their own, slower schedules, so frequent checks stay light.
actor ESPNSource: ScoreSource {
    let leagueID: String
    let season: Int
    let espnS2: String
    let swid: String

    private struct Meta {
        let week: Int
        let matchupPeriod: Int
        let teams: [Int: ESPNLeague.Team]
        let fetchedAt: Date
    }
    private var meta: Meta?
    private var games: [NFLGame] = []
    private var gamesFetchedAt = Date.distantPast

    init(leagueID: String, season: Int, espnS2: String, swid: String) {
        self.leagueID = leagueID
        self.season = season
        self.espnS2 = espnS2
        self.swid = swid
    }

    private var baseURL: URL {
        URL(string: "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/\(season)/segments/0/leagues/\(leagueID)")!
    }

    func fetchSnapshot() async throws -> LeagueSnapshot {
        guard Config.isConfigured else { throw ESPNError.notConfigured }
        let now = Date()

        // 1) Which week is it + team names (cached; refreshed every few minutes)
        if meta == nil || now.timeIntervalSince(meta!.fetchedAt) > Config.metaRefreshSeconds {
            do {
                let m = try await get(views: ["mStatus", "mTeam"], scoringPeriod: nil)
                let week = m.scoringPeriodId ?? 1
                var teamsById: [Int: ESPNLeague.Team] = [:]
                for t in m.teams ?? [] { teamsById[t.id] = t }
                meta = Meta(week: week, matchupPeriod: m.status?.currentMatchupPeriod ?? week,
                            teams: teamsById, fetchedAt: now)
            } catch {
                if meta == nil { throw error }   // keep using the cached copy otherwise
            }
        }
        guard let meta else { throw ESPNError.badResponse("no league info") }

        // 2) NFL game clocks for the win-probability estimate (cached; refreshed every 30 s)
        if now.timeIntervalSince(gamesFetchedAt) > Config.clockRefreshSeconds {
            if let fresh = try? await NFLGameClock.fetchGames() {
                games = fresh
                gamesFetchedAt = now
            }
        }
        var clock: [Int: Double]? = nil
        if !games.isEmpty {
            var map: [Int: Double] = [:]
            for g in games { for t in g.teamIds { map[t] = g.remaining } }
            clock = map
        }

        // 3) Live box scores for this week (starters' fantasy points + projections)
        let live = try await get(views: ["mMatchupScore", "mBoxscore"], scoringPeriod: meta.week)

        let matchups: [MatchupScore] = (live.schedule ?? [])
            .filter { $0.matchupPeriodId == meta.matchupPeriod }
            .compactMap { m in
                guard let home = m.home else { return nil }
                var matchup = MatchupScore(
                    id: m.id,
                    home: teamScore(home, meta.teams, meta.week),
                    away: m.away.map { teamScore($0, meta.teams, meta.week) }
                )
                if let clock {
                    // Teams not on the scoreboard (bye) have nothing left to play.
                    WinProbability.annotate(&matchup) { clock[$0] ?? 0 }
                }
                return matchup
            }

        return LeagueSnapshot(week: meta.week, matchups: matchups, games: games)
    }

    private func teamScore(_ side: ESPNLeague.Side, _ teams: [Int: ESPNLeague.Team], _ week: Int) -> TeamScore {
        let entries = side.rosterForCurrentScoringPeriod?.entries ?? []
        let starters: [PlayerScore] = entries
            .filter { $0.lineupSlotId != 20 && $0.lineupSlotId != 21 } // 20 = bench, 21 = IR
            .map { e in
                let player = e.playerPoolEntry?.player
                // statSourceId 0 = actual stats, 1 = ESPN projection
                let actual = player?.stats?.first { $0.scoringPeriodId == week && $0.statSourceId == 0 }
                let weekStat = actual?.appliedTotal
                let projection = player?.stats?.first { $0.scoringPeriodId == week && $0.statSourceId == 1 }?.appliedTotal
                let pts = weekStat ?? e.playerPoolEntry?.appliedStatTotal ?? 0
                let position = ESPNPosition.name(player?.defaultPositionId)
                let proTeamId = player?.proTeamId ?? 0
                let photo = position == "D/ST"
                    ? NFLTeams.logoURL(proTeamId: proTeamId)
                    : URL(string: "https://a.espncdn.com/i/headshots/nfl/players/full/\(e.playerId).png")
                return PlayerScore(
                    id: e.playerId,
                    name: player?.fullName ?? "Player \(e.playerId)",
                    position: position,
                    points: pts.rounded(toPlaces: 2),
                    projected: projection ?? 0,
                    proTeamId: proTeamId,
                    headshotURL: photo,
                    stats: actual?.stats ?? [:]
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
        /// Raw stat totals keyed by ESPN stat id ("42" = receiving yards, …).
        let stats: [String: Double]?
    }
}

// MARK: - Player photos

/// Downloads player headshots ahead of time and keeps small copies in memory, so an
/// alert can draw the photo instantly. Safe to use from any thread.
final class HeadshotCache: @unchecked Sendable {
    static let shared = HeadshotCache()

    private let lock = NSLock()
    private var images: [URL: CGImage] = [:]
    private var attempted: Set<URL> = []

    func image(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        return images[url]
    }

    /// Fetches any of these that haven't been tried yet (a few at a time).
    func prefetch(_ urls: [URL]) async {
        let todo = claim(urls)
        guard !todo.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var remaining = todo.makeIterator()
            for _ in 0..<4 {
                if let url = remaining.next() { group.addTask { await self.load(url) } }
            }
            while await group.next() != nil {
                if let url = remaining.next() { group.addTask { await self.load(url) } }
            }
        }
    }

    private func claim(_ urls: [URL]) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        var out: [URL] = []
        for u in urls where !attempted.contains(u) {
            attempted.insert(u)
            out.append(u)
        }
        return out
    }

    private func store(_ image: CGImage, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        images[url] = image
    }

    private func load(_ url: URL) async {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let full = UIImage(data: data), full.size.width > 0 else { return }

        // Keep a small copy: ~100 full-size photos would use too much memory in the background.
        let width: CGFloat = 240
        let size = CGSize(width: width, height: (width * full.size.height / full.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            full.draw(in: CGRect(origin: .zero, size: size))
        }
        if let cg = small.cgImage { store(cg, for: url) }
    }
}
