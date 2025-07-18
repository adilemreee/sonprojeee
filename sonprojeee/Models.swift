import Foundation // For UUID, pid_t

// Represents the possible states of a tunnel
enum TunnelStatus: String, CaseIterable {
    case running
    case stopped
    case starting
    case stopping
    case error

    var displayName: String {
        switch self {
        case .running:
            return NSLocalizedString("Running", comment: "Tunnel status: Running")
        case .stopped:
            return NSLocalizedString("Stopped", comment: "Tunnel status: Stopped")
        case .starting:
            return NSLocalizedString("Starting...", comment: "Tunnel status: Starting")
        case .stopping:
            return NSLocalizedString("Stopping...", comment: "Tunnel status: Stopping")
        case .error:
            return NSLocalizedString("Error", comment: "Tunnel status: Error")
        }
    }
}

// Represents a tunnel managed via a configuration file (~/.cloudflared)
struct TunnelInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String           // Config file name without extension OR Tunnel Name from cloudflared
    let configPath: String?    // Path to YML config file (might be nil for newly created tunnels before config exists)
    var status: TunnelStatus = .stopped
    var processIdentifier: pid_t? // PID of the running process (only for tunnels run via config)
    var lastError: String?        // Store last error message if any
    var isManaged: Bool = true   // True if associated with a config file found in ~/.cloudflared
    var uuidFromConfig: String? // Store UUID parsed from config if available
}

// Represents a temporary "quick tunnel" created via a URL
struct QuickTunnelData: Identifiable { // Identifiable is enough
    let id = UUID() // Unique ID for tracking this specific instance
    let process: Process // Reference to the running process
    var publicURL: String? // Initially nil, found by parsing output
    let localURL: String   // The local URL being tunneled (e.g., http://localhost:8000)
    var processIdentifier: pid_t? // Keep track of PID too
    var lastError: String? // Store errors for quick tunnels too
}
