import SwiftUI

/// The app's settings, grouped: Alerts, Sound, and Teams & games (each team/game list has its
/// own screen).
struct SelectionView: View {
    @EnvironmentObject private var tracker: ScoreTracker
    @State private var exactText = ""

    private var delayOptions: [Double] {
        var options = Config.alertDelayOptions
        if !options.contains(tracker.alertDelaySeconds) {
            options.append(tracker.alertDelaySeconds)
            options.sort()
        }
        return options
    }

    /// The presets, plus a typed-in amount if it isn't one of them.
    private var pickerOptions: [Double] {
        var options = Config.pointChangeOptions
        if !options.contains(where: { abs($0 - tracker.minimumPointChange) < 0.0001 }) {
            options.append(tracker.minimumPointChange)
            options.sort()
        }
        return options
    }

    private func applyExact() {
        let cleaned = exactText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let value = Double(cleaned), value > 0 {
            tracker.minimumPointChange = max(0.01, (value * 100).rounded() / 100)
        }
        exactText = ""
    }

    var body: some View {
        List {
            // MARK: Alerts
            Section {
                Picker("Minimum point change", selection: $tracker.minimumPointChange) {
                    ForEach(pickerOptions, id: \.self) { value in
                        Text(Self.label(for: value)).tag(value)
                    }
                }
                TextField("Exact minimum, e.g. 0.25", text: $exactText)
                    .keyboardType(.decimalPad)
                    .onSubmit(applyExact)
                Picker("Alert delay", selection: $tracker.alertDelaySeconds) {
                    ForEach(delayOptions, id: \.self) { value in
                        Text(value == 0 ? "Off" : "\(Int(value)) seconds").tag(value)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Minimum point change: players alert once their points move by at least this much; smaller gains add up until they reach it. Alert delay: holds alerts and the between-alerts scores back so they don't get ahead of your stream. Note how many seconds early an alert shows up compared with the TV, and pick about that much.")
            }

            // MARK: Sound
            Section {
                Picker("Lead change sound", selection: $tracker.soundVolume) {
                    Text("Off").tag(0.0)
                    Text("Low").tag(0.3)
                    Text("Medium").tag(0.6)
                    Text("High").tag(1.0)
                }
                Button("Preview sound") {
                    SoundEffects.shared.play(.leadChange, volume: tracker.soundVolume)
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("A short fanfare when the favorite in a matchup flips. Other alerts are silent. It plays over your stream's audio.")
            }

            // MARK: Teams & games
            Section {
                NavigationLink {
                    TeamFilterView()
                } label: {
                    row("Fantasy teams", tracker.selectedTeamIds.isEmpty ? "All" : "\(tracker.selectedTeamIds.count) selected")
                }
                NavigationLink {
                    NicknamesView()
                } label: {
                    row("Team nicknames", nicknameSummary)
                }
                NavigationLink {
                    GameFilterView()
                } label: {
                    row("NFL games", selectedGameSummary)
                }
            } header: {
                Text("Teams & games")
            } footer: {
                Text("Choose which fantasy teams and NFL games alert, and set short team names for the score rows.")
            }
        }
        .navigationTitle("Settings")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var nicknameSummary: String {
        let teams = tracker.snapshot?.allTeams ?? []
        let set = teams.filter { Nicknames.nickname(for: $0.name) != nil }.count
        return set == 0 ? "None" : "\(set) of \(teams.count)"
    }

    private var selectedGameSummary: String {
        let live = (tracker.snapshot?.games ?? []).filter { tracker.selectedGameIds.contains($0.id) }.count
        return live == 0 ? "All" : "\(live) selected"
    }

    private static func label(for value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        var number = String(format: "%.2f", rounded)
        while number.hasSuffix("0") { number.removeLast() }   // 0.50 → 0.5, 2.00 → 2.
        if number.hasSuffix(".") { number.removeLast() }       // 2. → 2
        let unit = rounded == 1 ? "point" : "points"
        switch rounded {
        case ..<0.015: return "\(number) \(unit) (any change)"
        case 6: return "\(number) \(unit) (touchdowns)"
        default: return "\(number) \(unit)"
        }
    }



}

/// Which fantasy teams alert. Nothing selected = all teams.
private struct TeamFilterView: View {
    @EnvironmentObject private var tracker: ScoreTracker

    var body: some View {
        List {
            Section {
                Button(tracker.selectedTeamIds.isEmpty ? "✓ All teams" : "All teams") {
                    tracker.selectedTeamIds = []
                }
                ForEach(tracker.snapshot?.allTeams ?? []) { team in
                    Toggle(isOn: Binding(
                        get: { tracker.selectedTeamIds.contains(team.id) },
                        set: { on in
                            if on { tracker.selectedTeamIds.insert(team.id) } else { tracker.selectedTeamIds.remove(team.id) }
                        }
                    )) {
                        HStack {
                            Text(team.name)
                            Spacer()
                            Text(team.label).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Only alert for these teams. Nothing selected = all teams.")
            }
        }
        .navigationTitle("Fantasy teams")
    }
}

/// Short names shown on the score rows instead of ESPN's abbreviations.
private struct NicknamesView: View {
    @EnvironmentObject private var tracker: ScoreTracker

    var body: some View {
        List {
            Section {
                ForEach(tracker.snapshot?.allTeams ?? []) { team in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(team.name)
                        TextField("Nickname (ESPN: \(team.abbrev))", text: Binding(
                            get: { tracker.savedNickname(for: team) },
                            set: { tracker.setNickname($0, for: team) }
                        ))
                        .autocorrectionDisabled()
                    }
                }
            } footer: {
                Text("Up to \(Nicknames.maxLength) characters. Leave blank to use ESPN's abbreviation.")
            }
        }
        .navigationTitle("Team nicknames")
    }
}

/// Which NFL games alert. Nothing selected = all games.
private struct GameFilterView: View {
    @EnvironmentObject private var tracker: ScoreTracker

    var body: some View {
        List {
            Section {
                Button(tracker.selectedGameIds.isEmpty ? "✓ All games" : "All games") {
                    tracker.selectedGameIds = []
                }
                ForEach(tracker.snapshot?.games ?? []) { game in
                    Toggle(isOn: Binding(
                        get: { tracker.selectedGameIds.contains(game.id) },
                        set: { on in
                            if on { tracker.selectedGameIds.insert(game.id) } else { tracker.selectedGameIds.remove(game.id) }
                        }
                    )) {
                        HStack {
                            Text(game.name)
                            Spacer()
                            Text(game.detail).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("This week")
            } footer: {
                Text("Only alert for players in these games. Nothing selected = all games.")
            }
        }
        .navigationTitle("NFL games")
    }
}
