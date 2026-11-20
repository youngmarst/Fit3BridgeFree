import SwiftUI

@main
struct Fit3BridgeFreeApp: App {
    init() {
        // Create the Bluetooth manager immediately so iOS state restoration works
        // even when the app is relaunched in the background.
        _ = BandManager.shared
        CallMonitor.shared.start()
        KeepAlive.shared.startIfEnabled()
        _ = HealthSyncManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(BandManager.shared)
                .environmentObject(Logbook.shared)
                .environmentObject(HealthSyncManager.shared)
        }
    }
}
