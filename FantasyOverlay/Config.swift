import Foundation
import CoreGraphics

/// App settings. Your ESPN league ID and cookies live in Secrets.swift, which is
/// git-ignored so they never get committed. See Secrets.swift.example / README.
enum Config {
    static let leagueID = Secrets.leagueID
    static let season = 2026

    // Browser cookies from fantasy.espn.com (see README). espn_s2 + SWID are
    // effectively your ESPN login — keep them out of git.
    static let espnS2 = Secrets.espnS2
    static let swid = Secrets.swid

    // Polling
    /// How often live scores are checked. ESPN's own updates lag the play by 30–60 s, so
    /// going much below 10 gains little and risks being throttled.
    static let pollSeconds: Double = 10
    static let demoPollSeconds: Double = 6
    /// League info (week, team names) barely changes, so it is refreshed less often.
    static let metaRefreshSeconds: Double = 300
    /// NFL game clocks (only used for projections and win %).
    static let clockRefreshSeconds: Double = 30
    /// Wait this long after a failed check, then after repeated failures.
    static let backoffSeconds: [Double] = [30, 60]

    /// Default short names for fantasy teams, shown on the score rows instead of ESPN's
    /// abbreviation. Key = the full team name as it appears in ESPN. A nickname typed on
    /// the Apple TV (Teams, nicknames & games) overrides the one here for that TV.
    /// Example: ["Double Dan-ger": "DAN", "Moizes's Monstrous Team": "MOIZ"]
    static let teamNicknames: [String: String] = [:]

    // Alerts
    /// Default for the "Minimum point change" setting on the Apple TV: the smallest change in
    /// a player's points that gets an alert. Smaller changes (like each yard a QB gains) add up
    /// quietly until they reach it.
    static let minimumPointChange: Double = 0.5
    /// Choices offered in the app's setting.
    static let pointChangeOptions: [Double] = [0.01, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
                                                1, 1.5, 2, 2.5, 3, 4, 5, 6]
    static let alertOnLeadChange = true
    /// false = PiP sits as a nearly blank dark tile between alerts (popup feel).
    /// true  = PiP shows the full league scoreboard between alerts.
    static let showScoreboardWhenIdle = false
    /// Stage 1: the quick, bright point-change burst.
    static let burstSeconds: Double = 2.5
    /// A lead change holds its (pulsing) burst longer, because it matters more.
    static let leadBurstSeconds: Double = 4.0
    /// The slide from the burst to the details screen.
    static let slideSeconds: Double = 0.45
    /// Stage 2: who scored, whose fantasy team, and where the matchup stands now.
    static let detailSeconds: Double = 8.0
    static let fadeOutSeconds: Double = 0.3
    /// Total time one alert is on screen.
    static func alertSeconds(isLeadChange: Bool) -> Double {
        (isLeadChange ? leadBurstSeconds : burstSeconds) + slideSeconds + detailSeconds + fadeOutSeconds
    }

    /// Pixel size of the PiP video. tvOS keeps the floating window at its normal width and
    /// sets the height from this shape, so a wider ratio = a shorter window covering less
    /// of the game. 960x240 (4:1) is about 45% of a normal PiP window; 960x192 (5:1) is
    /// about 35%. Narrower shapes (like a square) just get black bars, not a smaller window.
    static let pipSize = CGSize(width: 960, height: 240)

    /// Lets your streaming app keep its audio while our silent PiP runs.
    /// If PiP closes the moment the game starts playing, try flipping this.
    static let mixWithOtherAudio = true

    static var isConfigured: Bool {
        !leagueID.hasPrefix("YOUR") && !espnS2.hasPrefix("YOUR") && !swid.hasPrefix("{YOUR")
    }
}
