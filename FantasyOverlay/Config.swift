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

    /// Pixel size of the PiP video. Its shape sets the shape of the floating window:
    /// square sits neatly over a network logo in a corner. Try 600x480 for a bit wider.
    static let pipSize = CGSize(width: 540, height: 540)

    /// Lets your streaming app keep its audio while our silent PiP runs.
    /// If PiP closes the moment the game starts playing, try flipping this.
    static let mixWithOtherAudio = true

    static var isConfigured: Bool {
        !leagueID.hasPrefix("YOUR") && !espnS2.hasPrefix("YOUR") && !swid.hasPrefix("{YOUR")
    }
}
