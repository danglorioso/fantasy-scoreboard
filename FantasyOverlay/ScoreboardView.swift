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
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.09, blue: 0.18),
                                    Color(red: 0.02, green: 0.03, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
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

/// Two-stage alert, built to be read from the couch in a corner window.
///
/// Stage 1 (morph = 0):           Stage 2 (morph = 1):
///          +6.0                    +6.0 │ J. Chase → 18.4
///      J. Chase WR                      │ GURU 98.2 – 91.0 BLTZ
///    Double Dan-ger                     │ 54% ██████████░░░░░
///
/// intro 0→1 pops the card in, morph 0→1 shrinks the number into the left column and
/// brings in the matchup details, exit 0→1 fades it out.
struct AlertCard: View {
    let event: ScoreEvent
    var intro: Double = 1
    var morph: Double = 1
    var exit: Double = 0

    static let green = Color(red: 0.42, green: 0.89, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.2)

    private static let W = ScoreboardView.size.width
    private static let H = ScoreboardView.size.height

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

    private var isLead: Bool { change == nil }

    var body: some View {
        let pop = ScoreboardView.easeOutBack(intro)
        let m = Self.easeInOut(morph)
        let bigScale = (0.4 + 0.6 * pop) * Self.lerp(1, isLead ? 0.6 : 0.55, m)
        let bigY = isLead ? 105.0 : 112.0

        ZStack {
            Color(red: 0.08, green: 0.085, blue: 0.1)
            HStack(spacing: 0) {
                accent.frame(width: 14)
                Spacer(minLength: 0)
            }

            // The big number (or LEAD CHANGE): center → left column
            bigText
                .scaleEffect(bigScale)
                .position(x: Self.lerp(Self.W / 2, 170, m), y: Self.lerp(bigY, Self.H / 2, m))

            // Stage 1 subtitles: player + fantasy team. Fade out as it shrinks.
            VStack(spacing: 4) { subtitles }
                .frame(width: Self.W - 80)
                .scaleEffect(1 - 0.25 * m)
                .opacity(min(1, intro * 1.5) * (1 - m))
                .position(x: Self.W / 2, y: 248 + 30 * m)

            // Stage 2 details: fade/slide in beside the number.
            VStack(alignment: .leading, spacing: 10) { details }
                .frame(width: 600, alignment: .leading)
                .opacity(m)
                .position(x: 640 + (1 - m) * 50, y: Self.H / 2)
        }
        .frame(width: Self.W, height: Self.H)
        .opacity(min(1, intro * 2) * (1 - exit))
        .foregroundColor(.white)
    }

    private var bigText: some View {
        Group {
            if let c = change {
                Text(c.delta.signedString)
                    .font(.system(size: 140, weight: .black, design: .rounded).monospacedDigit())
            } else {
                Text("LEAD\nCHANGE")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundColor(accent)
        .fixedSize()
    }

    @ViewBuilder private var subtitles: some View {
        if let c = change {
            Text("\(c.player.shortName) \(c.player.position)")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(event.team.name)
                .font(.system(size: 32, weight: .semibold))
                .opacity(0.75)
                .lineLimit(1).minimumScaleFactor(0.5)
        } else {
            Text(event.team.name)
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            if let opp = event.opponent {
                Text("takes the lead vs \(opp.name)")
                    .font(.system(size: 30, weight: .semibold))
                    .opacity(0.75)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
        }
    }

    @ViewBuilder private var details: some View {
        // Row 1: player and their new total (or who leads now)
        Group {
            if let c = change {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(c.player.shortName).fontWeight(.heavy)
                    Text("→ \(c.player.points.formatted1)").opacity(0.75)
                }
            } else {
                Text("\(event.team.abbrev) leads").fontWeight(.heavy)
            }
        }
        .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
        .lineLimit(1).minimumScaleFactor(0.5)

        // Row 2: where the matchup stands
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(event.team.abbrev).opacity(0.8)
            Text(event.team.points.formatted1).fontWeight(.black)
            if let opp = event.opponent {
                Text("–").opacity(0.5)
                Text(opp.points.formatted1).fontWeight(.black).opacity(0.85)
                Text(opp.abbrev).opacity(0.65)
            }
        }
        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
        .lineLimit(1).minimumScaleFactor(0.5)

        // Row 3: win chance for the alert's team
        if let p = event.winProbability {
            HStack(spacing: 14) {
                Text("\(Int((p * 100).rounded()))%")
                    .font(.system(size: 32, weight: .heavy, design: .rounded).monospacedDigit())
                    .frame(width: 90, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Self.green)
                            .frame(width: max(12, geo.size.width * min(1, max(0, p))))
                    }
                }
                .frame(height: 18)
            }
        }
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
