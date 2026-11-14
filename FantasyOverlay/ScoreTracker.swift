import Foundation
import SwiftUI

/// Polls the league, diffs each poll against the last one, and feeds a queue of alerts.
@MainActor
final class ScoreTracker: ObservableObject {
    @Published private(set) var snapshot: LeagueSnapshot?
    @Published private(set) var currentEvent: ScoreEvent?
    @Published private(set) var recent: [String] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published var demoMode: Bool {
        didSet { if demoMode != oldValue { loadSelections(); restart() } }
    }
    /// Fantasy teams to alert on. Empty = all teams.
    @Published var selectedTeamIds: Set<Int> = [] {
        didSet { saveSelections() }
    }
    /// NFL games to alert on. Empty = all games.
    @Published var selectedGameIds: Set<String> = [] {
        didSet { saveSelections() }
    }

    private var source: any ScoreSource
    private var queue: [ScoreEvent] = []
    private var pollTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?

    init() {
        let demo = !Config.isConfigured
        demoMode = demo
        source = Self.makeSource(demo: demo)
        loadSelections()
    }

    // MARK: Team / game selection

    var selectionSummary: String {
        let teams = selectedTeamIds.isEmpty ? "All teams"
            : "\(selectedTeamIds.count) team\(selectedTeamIds.count == 1 ? "" : "s")"
        let liveGames = (snapshot?.games ?? []).filter { selectedGameIds.contains($0.id) }.count
        let games = liveGames == 0 ? "all games" : "\(liveGames) game\(liveGames == 1 ? "" : "s")"
        return "\(teams) · \(games)"
    }

    private var storagePrefix: String { demoMode ? "demo." : "live." }
    private var isLoadingSelections = false

    private func loadSelections() {
        isLoadingSelections = true
        let d = UserDefaults.standard
        selectedTeamIds = Set((d.array(forKey: storagePrefix + "teams") as? [Int]) ?? [])
        selectedGameIds = Set((d.array(forKey: storagePrefix + "games") as? [String]) ?? [])
        isLoadingSelections = false
    }

    private func saveSelections() {
        guard !isLoadingSelections else { return }
        let d = UserDefaults.standard
        d.set(Array(selectedTeamIds), forKey: storagePrefix + "teams")
        d.set(Array(selectedGameIds), forKey: storagePrefix + "games")
    }

    var statusLine: String {
        var parts: [String] = []
        if demoMode { parts.append("DEMO") }
        if let lastUpdated {
            parts.append("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
        } else {
            parts.append("Connecting…")
        }
        if !queue.isEmpty { parts.append("\(queue.count) queued") }
        return parts.joined(separator: " · ")
    }

    // MARK: Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let wait = self.demoMode ? Config.demoPollSeconds : Config.pollSeconds
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        if alertTask == nil {
            alertTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.showNextAlert()
                }
            }
        }
    }

    private func restart() {
        source = Self.makeSource(demo: demoMode)
        snapshot = nil
        queue.removeAll()
        recent.removeAll()
        currentEvent = nil
        lastUpdated = nil
        errorMessage = nil
        start()
    }

    private static func makeSource(demo: Bool) -> any ScoreSource {
        demo ? DemoSource()
             : ESPNSource(leagueID: Config.leagueID, season: Config.season,
                          espnS2: Config.espnS2, swid: Config.swid)
    }

    /// Filter using the incoming snapshot's game list (so a brand-new week works right away).
    private func filterFor(_ new: LeagueSnapshot) -> AlertFilter {
        var f = AlertFilter(teamIds: selectedTeamIds)
        let games = new.games.filter { selectedGameIds.contains($0.id) }
        if !games.isEmpty { f.proTeamIds = Set(games.flatMap(\.teamIds)) }
        return f
    }

    func pollOnce() async {
        do {
            let new = try await source.fetchSnapshot()
            if let old = snapshot, old.week == new.week {
                enqueue(Self.diff(old: old, new: new, filter: filterFor(new)))
            }
            snapshot = new
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendTestAlert() {
        guard let m = snapshot?.matchups.first, var p = m.home.starters.first else { return }
        var team = m.home
        team.points += 6
        p.points += 6
        let before = m.winProbability(for: team.id)
        queue.insert(ScoreEvent(kind: .scoring([PlayerChange(player: p, delta: 6)]),
                                team: team, opponent: m.away,
                                winProbability: before.map { min(0.99, $0 + 0.06) },
                                previousWinProbability: before,
                                previousTeam: m.home,
                                previousOpponent: m.away), at: 0)
    }

    // MARK: Diffing

    static func diff(old: LeagueSnapshot, new: LeagueSnapshot, filter: AlertFilter = AlertFilter()) -> [ScoreEvent] {
        var oldById: [Int: MatchupScore] = [:]
        for m in old.matchups { oldById[m.id] = m }
        let threshold = max(Config.minimumPointChange, 0.01)
        var events: [ScoreEvent] = []

        for m in new.matchups {
            guard let om = oldById[m.id] else { continue }
            var matchupHadAlert = false

            for team in m.teams {
                guard filter.allowsTeam(team.id), let oldTeam = om.team(team.id) else { continue }
                var before: [Int: Double] = [:]
                for p in oldTeam.starters { before[p.id] = p.points }

                let changes = team.starters.compactMap { p -> PlayerChange? in
                    guard filter.allowsPlayer(p) else { return nil }
                    guard let prev = before[p.id] else { return nil } // lineup swap: no alert
                    let d = (p.points - prev).rounded(toPlaces: 2)
                    return abs(d) >= threshold ? PlayerChange(player: p, delta: d) : nil
                }
                .sorted { abs($0.delta) > abs($1.delta) }

                // One alert per player, biggest change first.
                for change in changes {
                    matchupHadAlert = true
                    events.append(ScoreEvent(kind: .scoring([change]), team: team,
                                             opponent: m.opponent(of: team.id),
                                             winProbability: m.winProbability(for: team.id),
                                             previousWinProbability: om.winProbability(for: team.id),
                                             previousTeam: oldTeam,
                                             previousOpponent: om.opponent(of: team.id)))
                }
            }

            if Config.alertOnLeadChange,
               let was = om.leaderId, let now = m.leaderId, was != now,
               let leader = m.team(now),
               m.teams.contains(where: { filter.allowsTeam($0.id) }),
               filter.proTeamIds == nil || matchupHadAlert {
                events.append(ScoreEvent(kind: .leadChange, team: leader, opponent: m.opponent(of: now),
                                         winProbability: m.winProbability(for: now),
                                         previousWinProbability: om.winProbability(for: now),
                                         previousTeam: om.team(now),
                                         previousOpponent: om.opponent(of: now)))
            }
        }
        return events
    }

    /// Every player's point change gets its own card, shown in order for Config.alertSeconds each.
    private func enqueue(_ events: [ScoreEvent]) {
        queue.append(contentsOf: events)
    }

    /// How many alerts are waiting (shown in the app's status line).
    var queuedCount: Int { queue.count }

    private func showNextAlert() async {
        guard !queue.isEmpty else {
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        let event = queue.removeFirst()
        currentEvent = event
        recent.insert(event.tickerText, at: 0)
        recent = Array(recent.prefix(5))

        try? await Task.sleep(for: .seconds(Config.alertSeconds))
        currentEvent = nil
        try? await Task.sleep(for: .milliseconds(400))
    }
}
