import SwiftUI

@main
struct FantasyOverlayApp: App {
    @StateObject private var tracker = ScoreTracker()
    @StateObject private var pip = PiPController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tracker)
                .environmentObject(pip)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var tracker: ScoreTracker
    @EnvironmentObject private var pip: PiPController

    var body: some View {
        NavigationStack {
            main
        }
    }

    private var main: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Fantasy Overlay").font(.largeTitle).bold()
                Text(tracker.statusLine).foregroundStyle(.secondary)

                if let err = tracker.errorMessage {
                    Text(err).foregroundStyle(.red).font(.callout)
                }
                if let err = pip.lastError {
                    Text(err).foregroundStyle(.orange).font(.callout)
                }

                Button(pip.isActive ? "Stop floating scoreboard" : "Start floating scoreboard") {
                    pip.toggle()
                }

                Text(pip.debugStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    SelectionView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose teams & games")
                        Text(tracker.selectionSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Toggle("Demo mode (fake scores)", isOn: $tracker.demoMode)

                Button("Send test alert") { tracker.sendTestAlert() }

                Button("Refresh now") { Task { await tracker.pollOnce() } }

                Text("Start the scoreboard, then press the TV button and open your streaming app. The scoreboard keeps floating on top. To move it, hold the TV button and use the PiP controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 640)

            PiPLayerView(layer: pip.playerLayer)
                .frame(width: ScoreboardView.size.width, height: ScoreboardView.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(60)
        .task {
            tracker.start()
            pip.setUp(tracker: tracker)
        }
    }
}
