import SwiftUI
import UIKit

@main
@MainActor
struct AokVMApp: App {
    @StateObject private var runtime = VMRuntime()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        if runtime.state == .paused { runtime.resume() }
                    case .inactive, .background:
                        // Suspend the guest rather than burn the battery on a
                        // machine nobody is looking at.
                        if runtime.state == .running { runtime.pause() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
