import Foundation

/// Fill these in before building. Don't commit this file anywhere public:
/// espn_s2 + SWID are effectively your ESPN login.
enum Config {
    // From your league URL: https://fantasy.espn.com/football/league?leagueId=XXXXXXX
    static let leagueID = "YOUR_LEAGUE_ID"
    static let season = 2026

    // Browser cookies from fantasy.espn.com (see README).
    static let espnS2 = "YOUR_ESPN_S2_COOKIE"
    static let swid = "{YOUR-SWID-INCLUDING-CURLY-BRACES}"

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
    /// Alerts share the time between polls; each one stays up between these bounds.
    static let alertSeconds: Double = 5

    /// Lets your streaming app keep its audio while our silent PiP runs.
    /// If PiP closes the moment the game starts playing, try flipping this.
    static let mixWithOtherAudio = true

    static var isConfigured: Bool {
        !leagueID.hasPrefix("YOUR") && !espnS2.hasPrefix("YOUR") && !swid.hasPrefix("{YOUR")
    }
}
