import Foundation
import SwiftUI

/// Polls the league, diffs each poll against the last one, and feeds a queue of alerts.
@MainActor
final class ScoreTracker: ObservableObject {
    @Published private(set) var snapshot: LeagueSnapshot?
    /// What the floating window shows between alerts: the league as it was `alertDelaySeconds`
    /// ago, so scores there don't get ahead of your stream either.
    @Published private(set) var displaySnapshot: LeagueSnapshot?
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
    /// Smallest change in a player's points that gets an alert. Saved on this Apple TV.
    @Published var minimumPointChange: Double = {
        let saved = UserDefaults.standard.double(forKey: "minimumPointChange")
        return saved > 0 ? saved : Config.minimumPointChange
    }() {
        didSet { UserDefaults.standard.set(minimumPointChange, forKey: "minimumPointChange") }
    }
    /// Alert sound volume, 0 (off) to 1. Saved on this Apple TV.
    @Published var soundVolume: Double = {
        UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? Config.defaultSoundVolume
    }() {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    /// Holds every alert (and the between-alerts scores) back this many seconds, so they match a
    /// stream that runs behind live TV. Saved on this Apple TV.
    @Published var alertDelaySeconds: Double = UserDefaults.standard.double(forKey: "alertDelaySeconds") {
        didSet {
            UserDefaults.standard.set(alertDelaySeconds, forKey: "alertDelaySeconds")
            updateDisplaySnapshot()
        }
    }
    /// NFL games to alert on. Empty = all games.
    @Published var selectedGameIds: Set<String> = [] {
        didSet { saveSelections() }
    }

    private var source: any ScoreSource
    private var queue: [ScoreEvent] = []
    private var consecutiveFailures = 0
    /// Recent snapshots with when they arrived, for the delayed between-alerts view.
    private var history: [(at: Date, snapshot: LeagueSnapshot)] = []
    /// Each player's points as of their last alert (key "teamId-playerId"). Changes are measured
    /// from here, so small gains below the threshold add up until together they reach it.
    private var alertedPoints: [String: AlertBaseline] = [:]
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

    // MARK: Team nicknames

    func savedNickname(for team: TeamScore) -> String { Nicknames.saved(for: team.name) }

    func setNickname(_ value: String, for team: TeamScore) {
        objectWillChange.send()
        Nicknames.set(value, for: team.name)
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
                var wait = self.demoMode ? Config.demoPollSeconds : Config.pollSeconds
                // Back off when ESPN is erroring (or throttling us); recover once it works again.
                if self.consecutiveFailures > 0, !Config.backoffSeconds.isEmpty {
                    let i = min(self.consecutiveFailures, Config.backoffSeconds.count) - 1
                    wait = max(wait, Config.backoffSeconds[i])
                }
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
        history.removeAll()
        displaySnapshot = nil
        recent.removeAll()
        alertedPoints.removeAll()
        currentEvent = nil
        lastUpdated = nil
        errorMessage = nil
        consecutiveFailures = 0
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
                enqueue(Self.diff(old: old, new: new, filter: filterFor(new),
                                  threshold: minimumPointChange, baseline: &alertedPoints))
            }
            snapshot = new
            history.append((Date(), new))
            updateDisplaySnapshot()
            lastUpdated = Date()
            errorMessage = nil
            consecutiveFailures = 0

            // Get player photos ready before anyone scores.
            let photos = new.matchups.flatMap(\.teams).flatMap(\.starters).compactMap(\.headshotURL)
            Task.detached(priority: .utility) { await HeadshotCache.shared.prefetch(photos) }
        } catch {
            errorMessage = error.localizedDescription
            consecutiveFailures += 1
        }
    }

    func sendTestAlert() {
        guard let m = snapshot?.matchups.first, var p = m.home.starters.first else { return }
        var team = m.home
        team.points += 6
        p.points += 6
        let before = m.winProbability(for: team.id)
        queue.insert(ScoreEvent(kind: .scoring([PlayerChange(player: p, delta: 6, play: "TOUCHDOWN · 22 YDS")]),
                                team: team, opponent: m.away,
                                winProbability: before.map { min(0.99, $0 + 0.06) },
                                previousWinProbability: before,
                                previousTeam: m.home,
                                previousOpponent: m.away), at: 0)   // test alerts skip the delay
    }

    /// Picks the newest snapshot that is at least `alertDelaySeconds` old.
    private func updateDisplaySnapshot() {
        let cutoff = Date().addingTimeInterval(-alertDelaySeconds)
        history.removeAll { $0.at < cutoff.addingTimeInterval(-120) }
        let chosen = history.last(where: { $0.at <= cutoff })?.snapshot
            ?? (displaySnapshot == nil ? history.first?.snapshot : nil)
        if let chosen, chosen.matchups != displaySnapshot?.matchups || displaySnapshot == nil {
            displaySnapshot = chosen
        }
    }

    // MARK: Diffing

    /// A player's points and stat totals as of their last alert.
    struct AlertBaseline {
        var points: Double
        var stats: [String: Double]
    }

    /// `baseline` holds each player's points (and stats) as of their last alert; a player alerts
    /// once their points have moved by at least `threshold` from it, and the baseline then moves up.
    static func diff(old: LeagueSnapshot, new: LeagueSnapshot, filter: AlertFilter = AlertFilter(),
                     threshold rawThreshold: Double, baseline: inout [String: AlertBaseline]) -> [ScoreEvent] {
        var oldById: [Int: MatchupScore] = [:]
        for m in old.matchups { oldById[m.id] = m }
        let threshold = max(rawThreshold, 0.01)
        var events: [ScoreEvent] = []

        for m in new.matchups {
            guard let om = oldById[m.id] else { continue }
            var matchupHadAlert = false

            for team in m.teams {
                guard filter.allowsTeam(team.id), let oldTeam = om.team(team.id) else { continue }
                var before: [Int: Double] = [:]
                for p in oldTeam.starters { before[p.id] = p.points }

                var beforeStats: [Int: [String: Double]] = [:]
                for p in oldTeam.starters { beforeStats[p.id] = p.stats }

                var changes: [PlayerChange] = []
                for p in team.starters {
                    let key = "\(team.id)-\(p.id)"
                    let now = AlertBaseline(points: p.points, stats: p.stats)
                    guard let prev = before[p.id] else {           // lineup swap: no alert
                        baseline[key] = now
                        continue
                    }
                    let from = baseline[key] ?? AlertBaseline(points: prev, stats: beforeStats[p.id] ?? [:])
                    guard filter.allowsPlayer(p) else {
                        baseline[key] = now                         // filtered out: don't save up
                        continue
                    }
                    let d = (p.points - from.points).rounded(toPlaces: 2)
                    if abs(d) >= threshold {
                        let play = PlayType.label(before: from.stats, after: p.stats, position: p.position)
                        changes.append(PlayerChange(player: p, delta: d, play: play))
                        baseline[key] = now
                    } else if baseline[key] == nil {
                        baseline[key] = from
                    }
                }
                changes.sort { abs($0.delta) > abs($1.delta) }

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

            // Lead change = the favorite flips: ESPN's win probability crosses 50%.
            // (A team passing the other on live points alone doesn't count.)
            if Config.alertOnLeadChange,
               let was = Self.favorite(om), let now = Self.favorite(m), was != now,
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

    /// The team ESPN gives better than 50% to win (nil if unknown or exactly even).
    nonisolated static func favorite(_ m: MatchupScore) -> Int? {
        guard let p = m.homeWinProbability, let away = m.away else { return nil }
        if p > 0.5 { return m.home.id }
        if p < 0.5 { return away.id }
        return nil
    }

    /// Every player's point change gets its own card, shown in order, one after another.
    private func enqueue(_ events: [ScoreEvent]) {
        let ready = Date().addingTimeInterval(alertDelaySeconds)
        queue.append(contentsOf: events.map { var e = $0; e.readyAt = ready; return e })
    }

    /// How many alerts are waiting (shown in the app's status line).
    var queuedCount: Int { queue.count }

    private func showNextAlert() async {
        updateDisplaySnapshot()
        guard let next = queue.first, next.readyAt <= Date() else {
            // Nothing ready yet (empty, or still being held back by the alert delay).
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        let event = queue.removeFirst()
        currentEvent = event
        recent.insert(event.tickerText, at: 0)
        recent = Array(recent.prefix(5))

        // Hold the alert until just before its fade-out. If another alert is already waiting,
        // go straight to it (no fade, no idle tile in between); otherwise fade out and rest.
        let full = Config.alertSeconds(isLeadChange: event.isLeadChange)
        try? await Task.sleep(for: .seconds(full - Config.fadeOutSeconds))
        // Chain straight into the next alert if it's ready by the time this one would fade.
        if let next = queue.first, next.readyAt <= Date().addingTimeInterval(Config.fadeOutSeconds) { return }
        try? await Task.sleep(for: .seconds(Config.fadeOutSeconds))
        currentEvent = nil
        try? await Task.sleep(for: .milliseconds(400))
    }
}
