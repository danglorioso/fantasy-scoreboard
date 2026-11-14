import SwiftUI

/// Pick which fantasy teams and which NFL games trigger alerts, and give teams nicknames.
/// Nothing selected in a section = everything in that section.
struct SelectionView: View {
    @EnvironmentObject private var tracker: ScoreTracker
    @State private var exactText = ""

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
            Section {
                Picker("Minimum point change", selection: $tracker.minimumPointChange) {
                    ForEach(pickerOptions, id: \.self) { value in
                        Text(Self.label(for: value)).tag(value)
                    }
                }
                TextField("Exact amount, e.g. 0.25", text: $exactText)
                    .keyboardType(.decimalPad)
                    .onSubmit(applyExact)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Players only alert once their points move by at least this much. Smaller gains, like each yard a QB throws for, add up until they reach it. Pick a preset or type any amount from 0.01 up.")
            }

            Section {
                Button(tracker.selectedTeamIds.isEmpty ? "✓ All teams" : "All teams") {
                    tracker.selectedTeamIds = []
                }
                ForEach(tracker.snapshot?.allTeams ?? []) { team in
                    Toggle(isOn: teamBinding(team.id)) {
                        HStack {
                            Text(team.name)
                            Spacer()
                            Text(team.label).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Nickname for \(team.name) (ESPN: \(team.abbrev))", text: nicknameBinding(team))
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Fantasy teams")
            } footer: {
                Text("Only alert for these teams. Nothing selected = all teams. A nickname (up to \(Nicknames.maxLength) characters) replaces ESPN's abbreviation on the score rows.")
            }

            Section {
                Button(tracker.selectedGameIds.isEmpty ? "✓ All games" : "All games") {
                    tracker.selectedGameIds = []
                }
                ForEach(tracker.snapshot?.games ?? []) { game in
                    Toggle(isOn: gameBinding(game.id)) {
                        HStack {
                            Text(game.name)
                            Spacer()
                            Text(game.detail).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("NFL games this week")
            } footer: {
                Text("Only alert for players in these games. Nothing selected = all games.")
            }
        }
        .navigationTitle("Settings")
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

    private func teamBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { tracker.selectedTeamIds.contains(id) },
            set: { on in
                if on { tracker.selectedTeamIds.insert(id) } else { tracker.selectedTeamIds.remove(id) }
            }
        )
    }

    private func nicknameBinding(_ team: TeamScore) -> Binding<String> {
        Binding(
            get: { tracker.savedNickname(for: team) },
            set: { tracker.setNickname($0, for: team) }
        )
    }

    private func gameBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { tracker.selectedGameIds.contains(id) },
            set: { on in
                if on { tracker.selectedGameIds.insert(id) } else { tracker.selectedGameIds.remove(id) }
            }
        )
    }
}
