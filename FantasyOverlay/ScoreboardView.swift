import SwiftUI

/// The frame that gets rendered into the PiP window. tvOS keeps the floating window at its
/// normal width and derives the height from this frame's shape, so a wide, short banner
/// (Config.pipSize) gives the smallest window. Laid out for 960x240 and scaled to fit.
struct ScoreboardView: View {
    static let size = Config.pipSize
    /// Scale factor relative to the 960x240 design.
    static let k = min(size.width / 960, size.height / 240)

    let snapshot: LeagueSnapshot?
    let event: ScoreEvent?
    let ticker: String?
    let status: String

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
            if let event {
                AlertCard(event: event)   // static, fully settled (alerts normally animate via PiPController)
            } else if Config.showScoreboardWhenIdle {
                board
            } else {
                quietIdle
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

    /// Between alerts: almost black, so the corner window stays out of the way.
    private var quietIdle: some View {
        let k = Self.k
        return ZStack {
            Color.black
            HStack(spacing: 18 * k) {
                Text("🏈").font(.system(size: 56 * k)).opacity(0.3)
                Text(ticker ?? status)
                    .font(.system(size: 28 * k, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 30 * k)
        }
    }

    /// Full league scoreboard: up to 6 matchups in a 3x2 grid.
    private var board: some View {
        let k = Self.k
        return VStack(alignment: .leading, spacing: 8 * k) {
            HStack {
                Text(snapshot.map { "WEEK \($0.week)" } ?? "FANTASY LIVE")
                    .font(.system(size: 22 * k, weight: .heavy, design: .rounded))
                Spacer()
                Text(ticker ?? status)
                    .font(.system(size: 18 * k, weight: .semibold))
                    .foregroundColor(.yellow.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundColor(.white)

            if let matchups = snapshot?.matchups, !matchups.isEmpty {
                let shown = Array(matchups.prefix(6))
                let rows = stride(from: 0, to: shown.count, by: 3).map {
                    Array(shown[$0..<min($0 + 3, shown.count)])
                }
                VStack(spacing: 6 * k) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack(spacing: 6 * k) {
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
                    .font(.system(size: 30 * k, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14 * k)
    }
}

/// A stable, distinct color per fantasy team, so you can tell at a glance whose player scored.
enum TeamColors {
    private static let palette: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.88),  // blue
        Color(red: 0.82, green: 0.24, blue: 0.24),  // red
        Color(red: 0.56, green: 0.30, blue: 0.82),  // purple
        Color(red: 0.93, green: 0.52, blue: 0.10),  // orange
        Color(red: 0.08, green: 0.60, blue: 0.56),  // teal
        Color(red: 0.86, green: 0.30, blue: 0.62),  // pink
        Color(red: 0.32, green: 0.58, blue: 0.20),  // green
        Color(red: 0.74, green: 0.58, blue: 0.08),  // gold
        Color(red: 0.36, green: 0.42, blue: 0.54),  // slate
        Color(red: 0.62, green: 0.36, blue: 0.20),  // brown
        Color(red: 0.20, green: 0.32, blue: 0.70),  // navy
        Color(red: 0.66, green: 0.18, blue: 0.40),  // maroon
    ]

    static func color(for teamId: Int) -> Color {
        palette[((teamId % palette.count) + palette.count) % palette.count]
    }
}

struct MatchupTile: View {
    let matchup: MatchupScore
    private var k: CGFloat { ScoreboardView.k }

    var body: some View {
        VStack(spacing: 2 * k) {
            line(matchup.home)
            if let away = matchup.away {
                line(away)
            } else {
                Text("BYE").font(.system(size: 20 * k, weight: .semibold)).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 4 * k)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10 * k).fill(Color.white.opacity(0.08)))
    }

    private func line(_ t: TeamScore) -> some View {
        let leading = matchup.leaderId == t.id
        return HStack(spacing: 6 * k) {
            Circle().fill(TeamColors.color(for: t.id)).frame(width: 10 * k, height: 10 * k)
            Text(t.abbrev)
                .font(.system(size: 22 * k, weight: leading ? .heavy : .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 4 * k)
            Text(t.points.formatted1)
                .font(.system(size: 24 * k, weight: leading ? .heavy : .medium, design: .rounded).monospacedDigit())
        }
        .foregroundColor(leading ? .white : .white.opacity(0.7))
    }
}

/// Two-stage alert for a short, wide corner banner.
///
/// Stage 1, burst (morph = 0): the point change, huge, on a bright green/red/orange field.
/// Stage 2, details (morph = 1):
///   ┌────────────────┬──────────────────────┬──────────────────────┐
///   │ Double         │ J. Chase WR          │ ● GURU  98.2  p121.4 │
///   │ Dan-ger        │ +6.0  → 18.4 pts     │ ● BLTZ  91.0  p117.0 │
///   │ (team color)   │                      │ WIN 54% ▲6  ▓▓▓▓░░░  │
///   └────────────────┴──────────────────────┴──────────────────────┘
///
/// intro 0→1 pops the burst in; morph 0→1 swaps burst for details; settle 0→1 slides the
/// win probability and projections from their old values to the new ones; exit 0→1 fades out.
struct AlertCard: View {
    let event: ScoreEvent
    var intro: Double = 1
    var morph: Double = 1
    var settle: Double = 1
    var exit: Double = 0

    static let green = Color(red: 0.20, green: 0.72, blue: 0.30)
    static let red = Color(red: 0.86, green: 0.22, blue: 0.22)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.10)
    static let upGreen = Color(red: 0.45, green: 0.92, blue: 0.40)
    static let downRed = Color(red: 1.0, green: 0.42, blue: 0.42)

    private var k: CGFloat { ScoreboardView.k }
    private var W: CGFloat { ScoreboardView.size.width }
    private var H: CGFloat { ScoreboardView.size.height }

    private var accent: Color {
        switch event.kind {
        case .leadChange: return Self.orange
        case .scoring: return event.totalDelta >= 0 ? Self.green : Self.red
        }
    }

    private var change: PlayerChange? {
        if case .scoring(let changes) = event.kind { return changes.first }
        return nil
    }

    private var teamColor: Color { TeamColors.color(for: event.team.id) }

    var body: some View {
        let pop = ScoreboardView.easeOutBack(intro)
        let m = Self.easeInOut(morph)

        ZStack {
            // Stage 2 background + details
            Color(red: 0.06, green: 0.07, blue: 0.10)
            details
                .opacity(m)
                .offset(y: (1 - m) * 30 * k)

            // Stage 1: bright burst
            ZStack {
                accent
                burstText
                    .scaleEffect((0.3 + 0.7 * pop) * (1 - 0.35 * m))
            }
            .opacity(1 - m)
        }
        .frame(width: W, height: H)
        .opacity(min(1, intro * 3) * (1 - exit))
        .foregroundColor(.white)
    }

    // MARK: Stage 1

    private var burstText: some View {
        Group {
            if let c = change {
                Text(c.delta.signedString)
                    .font(.system(size: 200 * k, weight: .black, design: .rounded).monospacedDigit())
            } else {
                Text("LEAD CHANGE")
                    .font(.system(size: 130 * k, weight: .black, design: .rounded))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .frame(width: W - 20 * k, height: H)
        .shadow(color: .black.opacity(0.25), radius: 6 * k, y: 3 * k)
    }

    // MARK: Stage 2

    private var details: some View {
        HStack(spacing: 0) {
            // Whose fantasy team: a solid panel in that team's color.
            Text(event.team.name)
                .font(.system(size: 44 * k, weight: .heavy, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.45)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14 * k)
                .frame(width: 270 * k, height: H, alignment: .leading)
                .background(teamColor)

            playerBlock
                .padding(.horizontal, 14 * k)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2 * k) {
                teamRow(event.team, before: event.previousTeam, highlighted: true)
                if let opp = event.opponent {
                    teamRow(opp, before: event.previousOpponent, highlighted: false)
                }
                winProbability
            }
            .padding(.horizontal, 6 * k)
            .frame(width: 350 * k, height: H)
            .background(Color.white.opacity(0.05))
        }
        .frame(width: W, height: H)
    }

    @ViewBuilder private var playerBlock: some View {
        if let c = change {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(c.player.shortName) \(c.player.position)")
                    .font(.system(size: 52 * k, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(alignment: .firstTextBaseline, spacing: 12 * k) {
                    Text(c.delta.signedString)
                        .font(.system(size: 50 * k, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundColor(c.delta >= 0 ? Self.upGreen : Self.downRed)
                    Text("→ \(c.player.points.formatted1) pts")
                        .font(.system(size: 34 * k, weight: .semibold, design: .rounded).monospacedDigit())
                        .opacity(0.75)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        } else {
            VStack(alignment: .leading, spacing: 4 * k) {
                Text("TAKES THE LEAD")
                    .font(.system(size: 38 * k, weight: .black, design: .rounded))
                    .foregroundColor(Self.orange)
                if let opp = event.opponent {
                    Text("vs \(opp.name)")
                        .font(.system(size: 26 * k, weight: .semibold))
                        .opacity(0.75)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private func teamRow(_ t: TeamScore, before: TeamScore?, highlighted: Bool) -> some View {
        let s = Self.easeInOut(settle)
        let proj = t.projectedTotal.map { now in Self.lerp(before?.projectedTotal ?? now, now, s) }
        let projDelta = (t.projectedTotal ?? 0) - (before?.projectedTotal ?? t.projectedTotal ?? 0)

        return HStack(alignment: .center, spacing: 8 * k) {
            Circle().fill(TeamColors.color(for: t.id))
                .frame(width: 12 * k, height: 12 * k)
            Text(t.abbrev)
                .font(.system(size: 28 * k, weight: .heavy, design: .rounded))
                .frame(width: 78 * k, alignment: .leading)
            Text(t.points.formatted1)
                .font(.system(size: 36 * k, weight: .black, design: .rounded).monospacedDigit())
            Spacer(minLength: 4 * k)
            if let proj {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("proj \(proj.formatted1)")
                        .font(.system(size: 18 * k, weight: .semibold).monospacedDigit())
                        .opacity(0.75)
                    if abs(projDelta) >= 0.05 {
                        Text("\(projDelta >= 0 ? "▲" : "▼") \(abs(projDelta).formatted1)")
                            .font(.system(size: 17 * k, weight: .bold).monospacedDigit())
                            .foregroundColor(projDelta >= 0 ? Self.upGreen : Self.downRed)
                            .opacity(s)
                    }
                }
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .padding(.horizontal, 6 * k)
        .padding(.vertical, 1 * k)
        .background(
            RoundedRectangle(cornerRadius: 8 * k)
                .fill(highlighted ? TeamColors.color(for: t.id).opacity(0.28) : Color.clear)
        )
        .opacity(highlighted ? 1 : 0.85)
    }

    @ViewBuilder private var winProbability: some View {
        if let now = event.winProbability {
            let s = Self.easeInOut(settle)
            let before = event.previousWinProbability ?? now
            let shown = Self.lerp(before, now, s)
            let delta = Int(((now - before) * 100).rounded())

            HStack(spacing: 8 * k) {
                Text("WIN")
                    .font(.system(size: 18 * k, weight: .bold))
                    .opacity(0.7)
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.system(size: 30 * k, weight: .black, design: .rounded).monospacedDigit())
                if delta != 0 {
                    Text("\(delta > 0 ? "▲" : "▼")\(abs(delta))")
                        .font(.system(size: 22 * k, weight: .heavy).monospacedDigit())
                        .foregroundColor(delta > 0 ? Self.upGreen : Self.downRed)
                        .opacity(s)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(teamColor)
                            .frame(width: max(10 * k, geo.size.width * min(1, max(0, shown))))
                    }
                    .frame(height: 12 * k)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 30 * k)
            }
            .padding(.horizontal, 6 * k)
        }
    }

    // MARK: Helpers

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
