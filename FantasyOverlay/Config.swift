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
    static let pollSeconds: Double = 30
    static let demoPollSeconds: Double = 6

    // Alerts
    /// Smallest per-player change that triggers an alert. 0.01 = "any point change".
    /// Raise to e.g. 1.0 if QB passing-yard trickles get too chatty.
    static let minimumPointChange: Double = 0.01
    static let alertOnLeadChange = true
    /// false = PiP sits as a nearly blank dark tile between alerts (popup feel).
    /// true  = PiP shows the full league scoreboard between alerts.
    static let showScoreboardWhenIdle = false
    /// Stage 1: the quick, bright point-change burst.
    static let burstSeconds: Double = 1.0
    /// Stage 2: who scored, whose fantasy team, and where the matchup stands now.
    static let detailSeconds: Double = 5.0
    /// Total time each alert is on screen (burst + transition + details + fade out).
    static var alertSeconds: Double { burstSeconds + 0.35 + detailSeconds + 0.3 }

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
