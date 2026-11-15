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
    /// Which page of matchup columns to show when idle (for leagues with more than 4 matchups).
    var idlePage: Int = 0

    var body: some View {
        ZStack {
            AlertCard.ground
            if let event {
                AlertCard(event: event)   // static, fully settled (alerts normally animate via PiPController)
            } else if let matchups = snapshot?.matchups, !matchups.isEmpty {
                MatchupColumns(matchups: Self.page(of: matchups, idlePage))
            } else {
                quietIdle
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The matchups shown on one idle page.
    static func page(of matchups: [MatchupScore], _ index: Int) -> [MatchupScore] {
        let per = max(1, Config.idleColumns)
        let pages = max(1, Int((Double(matchups.count) / Double(per)).rounded(.up)))
        let start = (((index % pages) + pages) % pages) * per
        return Array(matchups[start..<min(start + per, matchups.count)])
    }

    static func pageCount(_ matchups: [MatchupScore]) -> Int {
        max(1, Int((Double(matchups.count) / Double(max(1, Config.idleColumns))).rounded(.up)))
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
            AlertCard.ground   // same near-black as the details screen, so alerts fade straight into it
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
    private static let palette: [(Double, Double, Double)] = [
        (0.16, 0.45, 0.88),  // blue
        (0.82, 0.24, 0.24),  // red
        (0.56, 0.30, 0.82),  // purple
        (0.93, 0.52, 0.10),  // orange
        (0.08, 0.60, 0.56),  // teal
        (0.86, 0.30, 0.62),  // pink
        (0.32, 0.58, 0.20),  // green
        (0.74, 0.58, 0.08),  // gold
        (0.36, 0.42, 0.54),  // slate
        (0.62, 0.36, 0.20),  // brown
        (0.20, 0.32, 0.70),  // navy
        (0.66, 0.18, 0.40),  // maroon
    ]

    private static func rgb(_ teamId: Int) -> (Double, Double, Double) {
        palette[((teamId % palette.count) + palette.count) % palette.count]
    }

    static func color(for teamId: Int) -> Color {
        let c = rgb(teamId)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    /// A pale tint of the team color, readable as text on a dark background.
    static func light(for teamId: Int) -> Color {
        let c = rgb(teamId), w = 0.55
        return Color(red: c.0 + (1 - c.0) * w, green: c.1 + (1 - c.1) * w, blue: c.2 + (1 - c.2) * w)
    }
}

/// Between alerts: one column per matchup. Each column has both teams (color bar, nickname,
/// score; the trailing team dimmed) with a two-color win-chance bar between them.
struct MatchupColumns: View {
    let matchups: [MatchupScore]
    private var k: CGFloat { ScoreboardView.k }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(matchups.enumerated()), id: \.element.id) { i, m in
                column(m)
                if i < matchups.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                }
            }
        }
        .frame(width: ScoreboardView.size.width, height: ScoreboardView.size.height)
        .foregroundColor(.white)
    }

    private func column(_ m: MatchupScore) -> some View {
        let a = m.home
        let pa = m.homeWinProbability
        return VStack(spacing: 0) {
            row(a, leading: m.away.map { a.points >= $0.points } ?? true)
            if let b = m.away {
                HStack(spacing: 6 * k) {
                    pct(pa.map { Double(Self.percent($0)) / 100 })
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            if let pa {
                                Rectangle().fill(TeamColors.color(for: a.id))
                                    .frame(width: geo.size.width * min(1, max(0, pa)))
                                Rectangle().fill(TeamColors.color(for: b.id))
                            } else {
                                Rectangle().fill(Color.white.opacity(0.12))
                            }
                        }
                        .frame(height: 10 * k)
                        .clipShape(Capsule())
                        .frame(maxHeight: .infinity)
                    }
                    pct(pa.map { Double(100 - Self.percent($0)) / 100 })   // the two sides always add to 100
                }
                .frame(height: 34 * k)
                row(b, leading: b.points > a.points)
            } else {
                Text("BYE")
                    .font(.system(size: 22 * k, weight: .bold))
                    .opacity(0.5)
                    .frame(height: 96 * k)
            }
        }
        .padding(.horizontal, 16 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ t: TeamScore, leading: Bool) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4 * k)
                .fill(TeamColors.color(for: t.id))
                .frame(width: 8 * k)
            Text(t.label)
                .font(.system(size: 28 * k, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.leading, 10 * k)
            Spacer(minLength: 6 * k)
            Text(t.points.formatted1)
                .font(.system(size: 36 * k, weight: .black, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .layoutPriority(1)
        }
        .frame(height: 62 * k)
        .opacity(leading ? 1 : 0.72)
    }

    private static func percent(_ p: Double) -> Int { Int((min(1, max(0, p)) * 100).rounded()) }

    private func pct(_ p: Double?) -> some View {
        Text(p.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            .font(.system(size: 16 * k, weight: .bold).monospacedDigit())
            .opacity(0.85)
            .frame(width: 40 * k)
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
            Text(t.label)
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
/// Stage 1, burst: the point change, huge, on solid green/red with a soft glow, and the
/// player's photo with their name under it. A lead change shows the team's name
/// over a pulsing "LEAD CHANGE" on orange, and holds longer.
///
/// Stage 2, details (slides in from the right as the burst slides out left):
///   ┌───────────────────┬──────────────────────────────┐
///   │▌DAN         98.2  │ DOUBLE DAN-GER               │
///   │                   │ J. Chase                     │
///   │▌MOIZ        91.0  │ +6.0 → 18.4 pts              │
///   │                   │ WIN 54% ▲6 ▓▓▓▓▓▓░░░░        │
///   └───────────────────┴──────────────────────────────┘
///
/// intro 0→1 grows the burst in; pulse −1…1 throbs the lead-change burst; morph 0→1 is the
/// slide; settle 0→1 moves the win % from its old value to the new one; exit 0→1 fades out.
struct AlertCard: View {
    let event: ScoreEvent
    var intro: Double = 1
    var morph: Double = 1
    var settle: Double = 1
    var exit: Double = 0
    var pulse: Double = 0

    static let green = Color(red: 0.20, green: 0.72, blue: 0.30)
    static let red = Color(red: 0.86, green: 0.22, blue: 0.22)
    static let upGreen = Color(red: 0.45, green: 0.92, blue: 0.40)
    static let downRed = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let leadText = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let gold = Color(red: 0.96, green: 0.72, blue: 0.24)
    static let ground = Color(red: 0.043, green: 0.051, blue: 0.071)

    private var k: CGFloat { ScoreboardView.k }
    private var W: CGFloat { ScoreboardView.size.width }
    private var H: CGFloat { ScoreboardView.size.height }

    private var change: PlayerChange? {
        if case .scoring(let changes) = event.kind { return changes.first }
        return nil
    }

    private var teamColor: Color { TeamColors.color(for: event.team.id) }
    private var flash: Double { event.isLeadChange ? max(0, pulse) : 0 }

    var body: some View {
        let m = Self.easeInOut(morph)

        ZStack {
            Self.ground
            // Fade only the content: the ground stays, so a fade-out looks like the text
            // disappearing into the idle tile (which uses the same color).
            ZStack {
                details.offset(x: (1 - m) * W)
                burst.offset(x: -m * W)
            }
            .opacity(min(1, intro * 3) * (1 - exit))
        }
        .frame(width: W, height: H)
        .clipped()
        .foregroundColor(.white)
    }

    // MARK: Stage 1: burst

    private var burstColor: Color {
        if event.isLeadChange {
            // Orange that flashes brighter with each pulse.
            return Color(red: (242 + 13 * flash) / 255, green: (140 + 70 * flash) / 255, blue: (26 + 90 * flash) / 255)
        }
        return event.totalDelta >= 0 ? Self.green : Self.red
    }

    private var burst: some View {
        let grow = 0.3 + 0.7 * ScoreboardView.easeOutBack(intro)
        let throb = 1 + 0.06 * flash

        return ZStack {
            burstColor
            // Soft glow behind the main text, and slightly darker edges.
            EllipticalGradient(colors: [.white.opacity(0.34 + 0.2 * flash), .white.opacity(0)],
                               center: UnitPoint(x: event.isLeadChange ? 0.5 : 0.32, y: 0.5),
                               startRadiusFraction: 0, endRadiusFraction: event.isLeadChange ? 0.5 : 0.45)
            EllipticalGradient(colors: [.black.opacity(0), .black.opacity(0.22)],
                               center: .center, startRadiusFraction: 0.4, endRadiusFraction: 0.75)

            if let c = change {
                HStack(spacing: 0) {
                    // The point change, with what happened ("TOUCHDOWN · 18 YDS") under it.
                    VStack(spacing: c.play == nil ? 0 : -8 * k) {
                        Text(c.delta.displaySigned)
                            .font(.system(size: (c.play == nil ? 170 : 146) * k, weight: .black, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .shadow(color: .black.opacity(0.25), radius: 6 * k, y: 3 * k)
                        if let play = c.play {
                            Text(play)
                                .font(.system(size: (play.count > 16 ? 24 : 28) * k, weight: .bold))
                                .tracking(2.6 * k)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 16 * k)
                                .padding(.vertical, 7 * k)
                                .background(Capsule().fill(Color.black.opacity(0.36)))
                        }
                    }
                    // Place the label midway between the bottom of the digits and the bottom edge.
                    // (SF Rounded at 146 pt: the text box is ~174 tall with the digits' baseline
                    // ~139 down; the pill is ~47 tall. These put the number's top ~37 from the
                    // top edge and leave ~27 under the label.)
                    .offset(y: c.play == nil ? 0 : -13.5 * k)
                    Spacer(minLength: 16 * k)
                    VStack(spacing: 6 * k) {
                        headshot(for: c.player, size: 160 * k)
                        Text(c.player.shortName)
                            .font(.system(size: Self.nameSize(c.player.shortName) * k, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .shadow(color: .black.opacity(0.25), radius: 4 * k, y: 2 * k)
                    }
                    .frame(width: 160 * k)
                }
                // Left margin = 1/8 of the banner; the photo sits a little further in on the right.
                .padding(.leading, W / 8)
                .padding(.trailing, 172 * k)
                .scaleEffect(grow)
            } else {
                VStack(spacing: 10 * k) {
                    // Team name on a darker-orange pill, so it stands apart from the headline.
                    Text(event.team.name)
                        .font(.system(size: 46 * k, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 24 * k)
                        .padding(.vertical, 6 * k)
                        .background(Capsule().fill(Color(red: 150 / 255, green: 62 / 255, blue: 0).opacity(0.42)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 2 * k))
                        .scaleEffect(grow)

                    Text("LEAD CHANGE")
                        .font(.system(size: 104 * k, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.25), radius: 6 * k, y: 3 * k)
                        .scaleEffect(grow * throb)
                }
                .padding(.horizontal, 30 * k)
            }
        }
        .frame(width: W, height: H)
        .clipped()
    }

    /// Name under the photo: sized to span the photo's width (shorter names get bigger).
    private static func nameSize(_ name: String) -> CGFloat {
        min(42, 180 / max(1, CGFloat(name.count) * 0.58))
    }

    /// The player's ESPN photo in a white ring, or a silhouette until it has loaded.
    private func headshot(for player: PlayerScore, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.22))
            if let cg = HeadshotCache.shared.image(for: player.headshotURL) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.56, height: size * 0.56)
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 6 * k))
        .shadow(color: .black.opacity(0.3), radius: 6 * k, y: 4 * k)
    }

    // MARK: Stage 2: details

    private var details: some View {
        HStack(spacing: 0) {
            // Both teams as big score rows; the alert's team is highlighted.
            VStack(spacing: 0) {
                scoreRow(event.team, highlighted: true)
                if let opp = event.opponent {
                    scoreRow(opp, highlighted: false)
                }
            }
            .frame(width: 380 * k, height: H)

            VStack(alignment: .leading, spacing: 4 * k) {
                Text(event.team.name.uppercased())
                    .font(.system(size: 22 * k, weight: .bold))
                    .tracking(1.8 * k)
                    .foregroundColor(TeamColors.light(for: event.team.id))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let c = change {
                    Text(c.player.shortName)
                        .font(.system(size: 54 * k, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 12 * k) {
                        Text(c.delta.displaySigned)
                            .font(.system(size: 46 * k, weight: .black, design: .rounded).monospacedDigit())
                            .foregroundColor(c.delta >= 0 ? Self.upGreen : Self.downRed)
                        Text("→ \(c.player.points.formatted1) pts")
                            .font(.system(size: 30 * k, weight: .bold, design: .rounded).monospacedDigit())
                            .opacity(0.75)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                } else {
                    Text("LEADS")
                        .font(.system(size: 54 * k, weight: .black, design: .rounded))
                        .foregroundColor(Self.leadText)
                        .lineLimit(1)
                    if let opp = event.opponent {
                        Text(opp.name)
                            .font(.system(size: 32 * k, weight: .bold, design: .rounded))
                            .opacity(0.9)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: 46 * k)
                    }
                }

                winProbability
                    .padding(.top, 4 * k)
            }
            .padding(.leading, 32 * k)
            .padding(.trailing, 28 * k)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                // Lead change: a warm gold wash and a gold underline so it stands out.
                if event.isLeadChange {
                    ZStack(alignment: .bottom) {
                        LinearGradient(colors: [Self.gold.opacity(0.30), Self.gold.opacity(0.10)],
                                       startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(Self.gold).frame(height: 6 * k)
                    }
                }
            }
        }
        .frame(width: W, height: H)
    }

    private func scoreRow(_ t: TeamScore, highlighted: Bool) -> some View {
        let color = TeamColors.color(for: t.id)
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 14 * k)
            Text(t.label)
                .font(.system(size: 44 * k, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .padding(.leading, 18 * k)
            Spacer(minLength: 8 * k)
            Text(t.points.formatted1)
                .font(.system(size: 68 * k, weight: .black, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.trailing, 20 * k)
        }
        .foregroundColor(.white.opacity(highlighted ? 1 : 0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(highlighted ? color.opacity(0.30) : Color.white.opacity(0.05))
    }

    @ViewBuilder private var winProbability: some View {
        if let now = event.winProbability {
            let s = Self.easeInOut(settle)
            let before = event.previousWinProbability ?? now
            let shown = Self.lerp(before, now, s)
            let delta = Int(((now - before) * 100).rounded())

            HStack(spacing: 12 * k) {
                Text("WIN")
                    .font(.system(size: 20 * k, weight: .bold))
                    .opacity(0.75)
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.system(size: 30 * k, weight: .black, design: .rounded).monospacedDigit())
                if delta != 0 {
                    Text("\(delta > 0 ? "▲" : "▼")\(abs(delta))")
                        .font(.system(size: 22 * k, weight: .bold).monospacedDigit())
                        .foregroundColor(delta > 0 ? Self.upGreen : Self.downRed)
                        .opacity(s)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(teamColor)
                            .frame(width: max(14 * k, geo.size.width * min(1, max(0, shown))))
                    }
                    .frame(height: 14 * k)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 30 * k)
            }
            .lineLimit(1)
        }
    }

    // MARK: Helpers

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
