# Fantasy Overlay (tvOS)

This app floats a Picture-in-Picture window over whatever you're watching on Apple TV (YouTube TV, ESPN, Peacock, and so on). The window flashes an alert whenever a starter in your ESPN league scores or a matchup lead flips: a quick burst with the point change and the player's photo, then a details screen with both teams' scores and the win chance. Between alerts it shows every matchup side by side (scores and win chance), updating as the numbers change. There's no server: the Apple TV checks ESPN directly every 10 seconds, so it costs nothing.

## 1. Get your league info

1. **League ID**: open your league on fantasy.espn.com. It's the `leagueId=` number in the URL.
2. **Cookies** (needed because your league is private):
   - Log in to fantasy.espn.com in Chrome on a computer.
   - Open DevTools (⌥⌘I), go to **Application**, then **Cookies**, then `https://fantasy.espn.com`.
   - Copy the value of **`espn_s2`** (a long string) and **`SWID`** (it looks like `{ABCD-...}`; keep the braces).
3. Check that they work before you open Xcode:
   ```sh
   curl -s -b 'espn_s2=PASTE; SWID={PASTE}' \
     'https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/2026/segments/0/leagues/LEAGUE_ID?view=mTeam' | head -c 400
   ```
   If the cookies work, you'll see JSON with your team names. HTML or a 401 error means the cookies are wrong.
4. Copy the template and paste all three values into it:
   ```sh
   cp FantasyOverlay/Secrets.swift.example FantasyOverlay/Secrets.swift
   ```
   `Secrets.swift` is git-ignored, so your cookies never get committed. Never put them in `Config.swift` or any other tracked file: `espn_s2` is effectively your ESPN login.

## 2. Build it

**Option A: XcodeGen (fastest)**
```sh
brew install xcodegen
cd FantasyOverlay && xcodegen
open FantasyOverlay.xcodeproj
```
In the target's **Signing & Capabilities** tab, choose your Team and change the bundle ID.

**Option B: by hand**
1. In Xcode, go to **File → New → Project → tvOS → App** (SwiftUI, Swift) and name it FantasyOverlay.
2. Delete the template's `ContentView.swift` and `FantasyOverlayApp.swift`, then drag in every `.swift` file from `FantasyOverlay/`.
3. In **Signing & Capabilities**, click **+ Capability**, add **Background Modes**, and check **Audio, AirPlay, and Picture in Picture**.
4. Set the deployment target to tvOS 17.0 or later.

## 3. Put it on your Apple TV (no App Store needed)

**Straight from Xcode (easiest for one TV)**
1. Put the Mac and the Apple TV on the same Wi-Fi.
2. On the Apple TV, go to **Settings → Remotes and Devices → Remote App and Devices**.
3. On the Mac, open Xcode's **Window → Devices and Simulators**. The Apple TV appears there; click **Pair** and enter the code shown on the TV.
4. Pick the Apple TV as the run destination and press ⌘R.

With a paid developer account the install lasts about a year before you need to reinstall. The first wireless install can take a few minutes.

**TestFlight**
This works for tvOS too: use **Product → Archive**, upload, and add yourself as an *internal* tester. Internal testers don't need beta review. Install the TestFlight app on the Apple TV. Builds expire after 90 days.

## 4. Use it on game day

1. Open Fantasy Overlay on the Apple TV. It starts in **Demo mode** until `Secrets.swift` is filled in.
2. Press **Start floating scoreboard**.
3. Press the **TV/Home** button and open your streaming app. The window stays floating on top.
4. To move it to another corner, press the TV button while PiP is showing and use the PiP controls.

Before Sunday, turn on Demo mode and check that the window stays up over your streaming app while a game or replay is actually playing.

## Tuning (`Config.swift`)

| Setting | Default | What it does |
|---|---|---|
| `pollSeconds` | 10 | How often live scores are checked (it backs off automatically if ESPN errors) |
| `burstSeconds` / `leadBurstSeconds` | 2.5 / 4.0 | How long the burst holds for a point change / a lead change |
| `detailSeconds` | 8.0 | How long the details screen stays up |
| `pipSize` | 960x240 | Shape of the floating window (wider ratio = shorter window) |
| `teamNicknames` | empty | Default short names for teams, by full team name |
| `minimumPointChange` | 0.01 | Raise to around `1.0` if QB passing-yard ticks are too chatty |
| `alertOnLeadChange` | true | Shows the orange "LEAD CHANGE" card |
| `idleColumns` / `idlePageSeconds` | 4 / 8 | Matchups shown at once between alerts; more rotate in pages |
| `mixWithOtherAudio` | true | Flip this if PiP closes when the game's audio starts |

## How alerts behave

- Each check is compared with the previous one, player by player, across every starter in the league. Bench and IR players are ignored.
- Every player's point change is its own alert, and alerts play in order, one after another. **Minimum point change** in the app's Settings (default 0.5) skips tiny changes; they add up until they reach it. Raise it if the queue falls behind the live action.
- The burst names the play under the point change (TOUCHDOWN · 18 YDS, RECEPTION · 12 YDS, INTERCEPTION, FIELD GOAL · 40–49 YDS, SACK…), worked out from the change in the player's ESPN stats since their last alert. If several things happened between checks, it shows the most important one, with combined catches and yards.
- A lead change plays right after the alert that caused it. Going to or from a tie doesn't count.
- ESPN stat corrections show up as red, negative alerts.
- **Teams, nicknames & games** in the app picks which fantasy teams and NFL games alert, and sets a short nickname per team for the score rows.
- **Demo mode** uses your real league's teams and starters with made-up scoring (or an invented league if `Secrets.swift` isn't filled in).

## Known limits

- **The PiP window can't hide itself between alerts.** tvOS only lets an app *start* PiP while that app is open, so the window stays up and goes quiet when nothing is happening.
- ESPN's API is unofficial. If it stops working, check [cwendt94/espn-api](https://github.com/cwendt94/espn-api) issues for endpoint changes.
- Alerts are only as fast as ESPN's fantasy updates, which usually run 30 to 90 seconds behind the live play. Depending on how far behind your stream is, an alert can occasionally arrive *before* you see the play.
- Using PiP as an overlay is unusual, so App Review might reject it. That doesn't matter for Xcode or internal TestFlight installs.
