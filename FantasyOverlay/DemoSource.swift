import Foundation

/// Demo mode: fake scoring every few seconds, so you can test the overlay over your
/// streaming app when no games are on.
///
/// If your league is set up (Secrets.swift), the demo plays on your REAL teams and
/// starters, so names, nicknames and player photos are the ones you'll see on Sunday.
/// Only the scoring is made up. Otherwise it falls back to an invented league.
actor DemoSource: ScoreSource {
    private var matchups: [MatchupScore] = []
    private var realGames: [NFLGame] = []
    private var week = 11
    private var loaded = false
    private var ticks = 0

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if Config.isConfigured {
            let espn = ESPNSource(leagueID: Config.leagueID, season: Config.season,
                                  espnS2: Config.espnS2, swid: Config.swid)
            if let real = try? await espn.fetchSnapshot(),
               real.matchups.contains(where: { !$0.home.starters.isEmpty }) {
                matchups = real.matchups
                realGames = real.games
                week = real.week
                return
            }
        }
        matchups = Self.inventedLeague()
    }

    private static func inventedLeague() -> [MatchupScore] {
        let teamNames = [
            ("Gridiron Gurus", "GURU"), ("Blitz Brigade", "BLTZ"), ("End Zone Elite", "EZE"),
            ("Pigskin Pirates", "PIRT"), ("Hail Mary Heroes", "HAIL"), ("Fourth & Long", "4TH"),
            ("Red Zone Rebels", "RZR"), ("Sack Masters", "SACK"), ("Two-Point Titans", "2PT"),
            ("Waiver Warriors", "WAIV"), ("Bye Week Bandits", "BYE"), ("Fumble Factory", "FUMB"),
        ]
        let surnames = ["Rivers", "Bishop", "Calloway", "Dunmore", "Ellison", "Fairbanks", "Garrity",
                        "Holloway", "Ingram", "Jessup", "Kincaid", "Lockhart", "Mercer", "Navarro",
                        "Oakes", "Prescott", "Quill", "Ramsey", "Sutter", "Thibault", "Upton", "Vance"]
        let slots = ["QB", "RB", "RB", "WR", "WR", "TE", "RB", "K", "D/ST"]
        var nextId = 1

        var teams: [TeamScore] = []
        for (i, t) in teamNames.enumerated() {
            let starters = slots.map { pos -> PlayerScore in
                defer { nextId += 1 }
                let name = pos == "D/ST" ? "\(t.0.split(separator: " ").last!) D/ST"
                    : "\(String("ABCDEFGHJKLMNPRST".randomElement()!)). \(surnames.randomElement()!)"
                return PlayerScore(id: nextId, name: name, position: pos,
                                   points: Double(Int.random(in: 0...60)) / 10,
                                   projected: Double(Int.random(in: 50...200)) / 10,
                                   proTeamId: Int.random(in: 1...32))
            }
            teams.append(TeamScore(id: i + 1, name: t.0, abbrev: t.1,
                                   points: starters.reduce(0) { $0 + $1.points }.rounded(toPlaces: 2),
                                   starters: starters))
        }
        return stride(from: 0, to: teams.count, by: 2).map {
            MatchupScore(id: $0 / 2 + 1, home: teams[$0], away: teams[$0 + 1])
        }
    }

    func fetchSnapshot() async throws -> LeagueSnapshot {
        await loadIfNeeded()
        guard !matchups.isEmpty else { return LeagueSnapshot(week: week, matchups: []) }
        let plays: [Double] = [6, 6, 4, 3, 1.2, 0.8, 2.4, 0.5, 1.0, 1.7, -2, 0.4]
        for _ in 0..<Int.random(in: 1...3) {
            let mi = Int.random(in: matchups.indices)
            let useHome = Bool.random() || matchups[mi].away == nil
            var team = useHome ? matchups[mi].home : matchups[mi].away!
            guard !team.starters.isEmpty else { continue }
            let pi = Int.random(in: team.starters.indices)
            team.starters[pi].points = (team.starters[pi].points + plays.randomElement()!).rounded(toPlaces: 2)
            team.points = team.starters.reduce(0) { $0 + $1.points }.rounded(toPlaces: 2)
            if useHome { matchups[mi].home = team } else { matchups[mi].away = team }
        }

        // Pretend the games run down over ~20 minutes of demo time.
        ticks += 1
        let left = max(0, 1 - Double(ticks) / 200)
        for i in matchups.indices {
            WinProbability.annotate(&matchups[i]) { _ in left }
        }

        if !realGames.isEmpty {
            return LeagueSnapshot(week: week, matchups: matchups, games: realGames)
        }

        // 16 fake NFL games: teams 1&2, 3&4, ... (players have random proTeamIds 1-32).
        let abbrevs = ["ARI", "ATL", "BAL", "BUF", "CAR", "CHI", "CIN", "CLE", "DAL", "DEN", "DET", "GB",
                       "HOU", "IND", "JAX", "KC", "LV", "LAC", "LAR", "MIA", "MIN", "NE", "NO", "NYG",
                       "NYJ", "PHI", "PIT", "SF", "SEA", "TB", "TEN", "WSH"]
        let quarter = min(4, 1 + Int((1 - left) * 4))
        let games = stride(from: 1, through: 31, by: 2).map { a in
            NFLGame(id: "demo-\(a)", name: "\(abbrevs[a - 1]) @ \(abbrevs[a])", teamIds: [a, a + 1],
                    remaining: left, detail: left > 0 ? "Q\(quarter) (demo)" : "Final (demo)")
        }
        return LeagueSnapshot(week: week, matchups: matchups, games: games)
    }
}
