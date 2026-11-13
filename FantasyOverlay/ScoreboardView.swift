import SwiftUI

/// The frame that gets rendered into the PiP window.
/// A wide 3:1 banner, so the PiP window comes out short and covers less of the game.
/// Text is deliberately huge so it's readable in a small corner window.
struct ScoreboardView: View {
    static let size = CGSize(width: 960, height: 320)

    let snapshot: LeagueSnapshot?
    let event: ScoreEvent?
    let ticker: String?
    let status: String
    /// 0...1 progress of the alert's entrance animation (1 = fully shown).
    var appear: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.09, blue: 0.18),
                                    Color(red: 0.02, green: 0.03, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            if Config.showScoreboardWhenIdle {
                board
            } else {
                quietIdle
            }
            if let event {
                let e = Self.easeOutBack(appear)
                AlertCard(event: event, pop: e)
                    .offset(y: (1 - e) * Self.size.height)
                    .opacity(min(1, appear * 3))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// Slides in, overshoots slightly, settles.
    static func easeOutBack(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    /// Between alerts: almost black, one dim line, so the corner window stays out of the way.
    private var quietIdle: some View {
        ZStack {
            Color.black
            HStack(spacing: 20) {
                Text("🏈").font(.system(size: 56)).opacity(0.35)
                Text(ticker ?? status)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
            }
            .padding(30)
        }
    }

    /// Full league scoreboard: up to 6 matchups in a 3x2 grid.
    private var board: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.map { "WEEK \($0.week)" } ?? "FANTASY LIVE")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text(ticker ?? status)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.yellow.opacity(0.85))
                    .lineLimit(1)
            }

            if let matchups = snapshot?.matchups, !matchups.isEmpty {
                let shown = Array(matchups.prefix(6))
                let rows = stride(from: 0, to: shown.count, by: 3).map {
                    Array(shown[$0..<min($0 + 3, shown.count)])
                }
                VStack(spacing: 8) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            ForEach(rows[i]) { MatchupTile(matchup: $0) }
                            ForEach(0..<(3 - rows[i].count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text("Waiting for scores…")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(18)
    }
}

struct MatchupTile: View {
    let matchup: MatchupScore

    var body: some View {
        VStack(spacing: 2) {
            line(matchup.home)
            if let away = matchup.away {
                line(away)
            } else {
                Text("BYE").font(.system(size: 26, weight: .semibold)).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
    }

    private func line(_ t: TeamScore) -> some View {
        let leading = matchup.leaderId == t.id
        return HStack {
            Text(t.abbrev)
                .font(.system(size: 28, weight: leading ? .heavy : .semibold, design: .rounded))
                .lineLimit(1)
            Spacer()
            Text(t.points.formatted1)
                .font(.system(size: 30, weight: leading ? .heavy : .medium, design: .rounded).monospacedDigit())
        }
        .foregroundColor(leading ? Color(red: 0.35, green: 0.95, blue: 0.5) : .white.opacity(0.85))
    }
}

/// Alert: big change on the left, team + each player's change and new total on the right,
/// and a thin win-probability bar with both teams' scores stacked at each end.
struct AlertCard: View {
    let event: ScoreEvent
    /// Entrance animation progress (eased); drives the big number's pop.
    var pop: Double = 1

    var body: some View {
        ZStack {
            background
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 28) {
                    left
                        .frame(width: 250)
                        .scaleEffect(0.6 + 0.4 * pop)
                    VStack(alignment: .leading, spacing: 4) { details }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MatchupBar(team: event.team, opponent: event.opponent,
                           probability: event.winProbability)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .foregroundColor(.white)
        }
    }

    private var background: Color {
        switch event.kind {
        case .leadChange: return Color(red: 0.93, green: 0.52, blue: 0.08)
        case .scoring:
            return event.totalDelta >= 0
                ? Color(red: 0.07, green: 0.52, blue: 0.27)
                : Color(red: 0.74, green: 0.14, blue: 0.14)
        }
    }

    @ViewBuilder private var left: some View {
        switch event.kind {
        case .leadChange:
            Text("LEAD\nCHANGE")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
        case .scoring:
            Text(event.totalDelta.signedString)
                .font(.system(size: 96, weight: .black, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    @ViewBuilder private var details: some View {
        Text(event.team.name)
            .font(.system(size: 36, weight: .heavy, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.5)

        switch event.kind {
        case .scoring(let changes):
            ForEach(Array(changes.prefix(2)), id: \.player.id) { c in
                Text("\(c.player.shortName) \(c.player.position)  \(c.delta.signedString) → \(c.player.points.formatted1)")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if changes.count > 2 {
                Text("+\(changes.count - 2) more")
                    .font(.system(size: 20, weight: .medium))
                    .opacity(0.8)
            }
        case .leadChange:
            if let opp = event.opponent {
                Text("now leads \(opp.name)")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}

/// Team name / score / projection stacked at each end, thin probability bar between.
struct MatchupBar: View {
    let team: TeamScore
    let opponent: TeamScore?
    let probability: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            stack(team, alignment: .leading)

            if let opponent {
                if let p = probability {
                    Text(percent(p))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .opacity(0.85)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: max(6, geo.size.width * p))
                        }
                        .frame(height: 8)
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 20)
                    Text(percent(1 - p))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .opacity(0.85)
                } else {
                    Spacer()
                    Text("vs").font(.system(size: 20, weight: .semibold)).opacity(0.7)
                    Spacer()
                }
                stack(opponent, alignment: .trailing).opacity(0.85)
            } else {
                Spacer()
            }
        }
    }

    private func stack(_ t: TeamScore, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(t.abbrev)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .opacity(0.85)
            Text(t.points.formatted1)
                .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
            if let proj = t.projectedTotal {
                Text("proj \(proj.formatted1)")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .opacity(0.75)
            }
        }
        .lineLimit(1)
        .frame(minWidth: 110, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func percent(_ p: Double) -> String {
        "\(Int((p * 100).rounded()))%"
    }
}
