import SwiftUI

@main
struct CloudflaredManagerApp: App {
    // Use AppDelegateAdaptor to connect AppDelegate lifecycle
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Define the Settings scene, making TunnelManager available
     

        // NO WindowGroup scene here for a menu bar app (LSUIElement = true in Info.plist).
        // Windows are managed manually by AppDelegate's showWindow function.
    }
}
