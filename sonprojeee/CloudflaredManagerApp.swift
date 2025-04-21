import SwiftUI

@main
struct CloudflaredManagerApp: App {
    // Use AppDelegateAdaptor to connect AppDelegate lifecycle
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Define the Settings scene, making TunnelManager available
        Settings {
            // Use Group to safely handle potential nil manager during startup
            Group {
                if let manager = appDelegate.tunnelManager {
                     SettingsView().environmentObject(manager)
                } else {
                     // Provide a fallback view if initialization fails
                     Text("Hata: Tunnel Manager Yüklenemedi.")
                         .padding()
                         .frame(width: 350, height: 100)
                }
            }
        }

        // NO WindowGroup scene here for a menu bar app (LSUIElement = true in Info.plist).
        // Windows are managed manually by AppDelegate's showWindow function.
    }
}
