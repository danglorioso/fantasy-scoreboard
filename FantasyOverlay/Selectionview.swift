import SwiftUI

/// Pick which fantasy teams and which NFL games trigger alerts, and give teams nicknames.
/// Nothing selected in a section = everything in that section.
struct SelectionView: View {
    @EnvironmentObject private var tracker: ScoreTracker

    var body: some View {
        List {
            Section {
                Picker("Minimum point change", selection: $tracker.minimumPointChange) {
                    ForEach(Config.pointChangeOptions, id: \.self) { value in
                        Text(Self.label(for: value)).tag(value)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Players only alert once their points move by at least this much. Smaller gains, like each yard a QB throws for, add up until they reach it.")
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
        switch value {
        case ..<0.1: return "Any change"
        case 6: return "6 points (touchdowns)"
        case 1: return "1 point"
        default:
            let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return "\(number) points"
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
