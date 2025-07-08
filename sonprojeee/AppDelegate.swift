import SwiftUI
import Cocoa // NSStatusItem, NSMenu, NSAlert, NSTextField, NSStackView etc.
import Combine // ObservableObject, @Published, AnyCancellable
import AppKit // Required for NSAlert, NSTextField, NSStackView etc.
import UserNotifications // For notifications
import ServiceManagement // For Launch At Login (macOS 13+)

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var tunnelManager: TunnelManager! // Should be initialized in applicationDidFinishLaunching
    private var cancellables = Set<AnyCancellable>()

    // Window references - weak to avoid retain cycles
    weak var settingsWindow: NSWindow?
    weak var createManagedTunnelWindow: NSWindow?
    weak var createFromMampWindow: NSWindow?

    // --- MAMP Control Constants ---
    private let mampBasePath = "/Applications/MAMP/bin" // Standard MAMP path
    private let mampStartScript = "start.sh"
    private let mampStopScript = "stop.sh"
    // --- End MAMP Control Constants ---
    
    // --- Python Script Constants (UPDATED) ---
    // ATTENTION: Adjust these paths according to YOUR system and project!
    private let pythonProjectDirectoryPath = "/Users/adilemre/Documents/PANEL-main" // MAIN DIRECTORY where your project is located
    private let pythonVenvName = "venv" // Name of the virtual environment folder (usually venv)
    private let pythonScriptPath = "app.py" // Path of the script RELATIVE TO THE PROJECT DIRECTORY OR FULL PATH
    // Old pythonInterpreterPath (e.g., /usr/bin/python3) will no longer be used directly; the one inside venv will be used.
    // --- END: Python Script Constants (UPDATED) ---

    // --- Tracking Running Python Process ---
    private var pythonAppProcess: Process?


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 1. Initialize the Tunnel Manager
        tunnelManager = TunnelManager()

        // 2. Observe notifications from TunnelManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSendUserNotification(_:)),
            name: .sendUserNotification,
            object: tunnelManager // Only listen to notifications from our tunnelManager instance
        )

        // 3. Request Notification Permissions & Set Delegate
        requestNotificationAuthorization()
        UNUserNotificationCenter.current().delegate = self

        // 4. Create the Status Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: NSLocalizedString("Cloudflared Tunnels", comment: "Accessibility description for status bar icon")) {
                button.image = image
                button.imagePosition = .imageLeading
            } else {
                button.title = NSLocalizedString("CfT", comment: "Fallback text for status bar button if icon fails") // Fallback text
                print(NSLocalizedString("⚠️ SF Symbol 'cloud.fill' not found. Using text.", comment: "Log message: SF Symbol for cloud icon not found"))
            }
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp]) // Handle both clicks
            button.target = self
        }

        // 5. Build the initial menu
        constructMenu()

        // 6. Observe changes in the TunnelManager's published properties
        observeTunnelManagerChanges()

        // Check executable status on launch
        tunnelManager.checkCloudflaredExecutable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        print(NSLocalizedString("Application is closing...", comment: "Log message: Application will terminate"))
        NotificationCenter.default.removeObserver(self) // Clean up observer
        tunnelManager?.stopMonitoringCloudflaredDirectory()
        // Stop all tunnels synchronously during shutdown
        tunnelManager?.stopAllTunnels(synchronous: true)
        print(NSLocalizedString("Shutdown procedures completed.", comment: "Log message: Application termination tasks finished"))
        Thread.sleep(forTimeInterval: 0.2) // Brief pause for async ops
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If dock icon (if shown) is clicked, open settings if no other window is visible
        if !flag {
            openSettingsWindowAction()
        }
        return true
    }

    // MARK: - Observation Setup
    private func observeTunnelManagerChanges() {
        guard let tunnelManager = tunnelManager else { return }

        // Observe managed tunnels
        tunnelManager.$tunnels
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main) // Slightly longer debounce
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.constructMenu() }
            .store(in: &cancellables)

        // Observe quick tunnels
        tunnelManager.$quickTunnels
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.constructMenu() }
            .store(in: &cancellables)

        // Observe cloudflared path changes
        tunnelManager.$cloudflaredExecutablePath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.constructMenu() } // Rebuild menu on path change
            .store(in: &cancellables)
    }

    // MARK: - Status Bar Click
    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // Show menu for left click, right click, or ctrl-click
        statusItem?.menu = statusItem?.menu // Ensure menu is attached
        statusItem?.button?.performClick(nil) // Programmatically open the menu
    }

    // MARK: - Notification Handling (Receiving from TunnelManager)
    @objc func handleSendUserNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let identifier = userInfo["identifier"] as? String,
              let title = userInfo["title"] as? String,
              let body = userInfo["body"] as? String else {
            print(NSLocalizedString("⚠️ Invalid user notification received.", comment: "Log message: Received a user notification with missing data"))
            return
        }
        sendUserNotification(identifier: identifier, title: title, body: body)
    }
    
    @objc func startPythonAppAction() {
        if let existingProcess = pythonAppProcess, existingProcess.isRunning {
            // ... (check for already running is the same) ...
            return
        }

        // --- START: Calculate Venv and Script Paths ---
        let expandedProjectDirPath = (pythonProjectDirectoryPath as NSString).expandingTildeInPath
        let venvPath = expandedProjectDirPath.appending("/").appending(pythonVenvName)
        let venvInterpreterPath = venvPath.appending("/bin/python") // Standard for macOS/Linux

        // Determine script path: if it contains "/", treat as full path, otherwise relative to project directory
        let finalScriptPath: String
        if pythonScriptPath.contains("/") { // Looks like a full path
             finalScriptPath = (pythonScriptPath as NSString).expandingTildeInPath
        } else { // Relative to project directory
             finalScriptPath = expandedProjectDirPath.appending("/").appending(pythonScriptPath)
        }

        // Check existence of necessary files
        guard FileManager.default.fileExists(atPath: expandedProjectDirPath) else {
            let errorMessage = String(format: NSLocalizedString("Python project directory not found:\n%@", comment: "Error message: Python project directory not found. Parameter is the path."), expandedProjectDirPath)
            print(String(format: NSLocalizedString("❌ Error: Python project directory not found: %@", comment: "Log message: Python project directory not found. Parameter is the path."), expandedProjectDirPath))
            showErrorAlert(message: errorMessage)
            return
        }
         guard FileManager.default.fileExists(atPath: finalScriptPath) else {
            let errorMessage = String(format: NSLocalizedString("Python script file not found:\n%@", comment: "Error message: Python script file not found. Parameter is the path."), finalScriptPath)
            print(String(format: NSLocalizedString("❌ Error: Python script not found: %@", comment: "Log message: Python script not found. Parameter is the path."), finalScriptPath))
            showErrorAlert(message: errorMessage)
            return
        }
        // --- END: Calculate Venv and Script Paths ---


        // --- START: Update Execution Logic (Venv Priority) ---
        print(String(format: NSLocalizedString("🚀 Starting Python script: %@", comment: "Log message: Starting Python script. Parameter is the script path."), finalScriptPath))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            var interpreterToUse = "" // Path to the interpreter to be used

            // Check venv interpreter
            if FileManager.default.isExecutableFile(atPath: venvInterpreterPath) {
                print(String(format: NSLocalizedString("   Virtual environment (venv) interpreter will be used: %@", comment: "Log message: Using venv interpreter. Parameter is the path."), venvInterpreterPath))
                interpreterToUse = venvInterpreterPath
                process.executableURL = URL(fileURLWithPath: interpreterToUse)
                process.arguments = [finalScriptPath] // Argument is just the script path
            } else {
                // Venv not found, use /usr/bin/env python3 as fallback
                interpreterToUse = "/usr/bin/env" // Fallback
                print(String(format: NSLocalizedString("⚠️ Warning: Virtual environment interpreter not found or not executable: %@. Using fallback: %@ python3", comment: "Log message: Venv interpreter not found or not executable. Parameters are venv path and fallback interpreter."), venvInterpreterPath, interpreterToUse))
                process.executableURL = URL(fileURLWithPath: interpreterToUse)
                process.arguments = ["python3", finalScriptPath] // Fallback arguments
            }

            // Set working directory (very important)
            process.currentDirectoryURL = URL(fileURLWithPath: expandedProjectDirPath)

            // Termination Handler (content is the same, we can update the log message)
            process.terminationHandler = { terminatedProcess in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    print(String(format: NSLocalizedString("🏁 Python script finished (%@). Interpreter: %@", comment: "Log message: Python script finished. Parameters are script name and interpreter path."), (finalScriptPath as NSString).lastPathComponent, interpreterToUse))
                    self.pythonAppProcess = nil
                    self.constructMenu()
                }
            }
            // --- END: Update Execution Logic ---

            do {
                try process.run()
                DispatchQueue.main.async {
                     print(String(format: NSLocalizedString("✅ Python script started: %@, PID: %d, Interpreter: %@", comment: "Log message: Python script started. Parameters are script path, PID, and interpreter path."), finalScriptPath, process.processIdentifier, interpreterToUse))
                     self.pythonAppProcess = process
                     self.constructMenu()
                    let notificationTitle = NSLocalizedString("Python Application Started", comment: "Notification title: Python app started")
                    let notificationBody = String(format: NSLocalizedString("%@ is running (PID: %d).", comment: "Notification body: Python script is running. Parameters are script name and PID."), (finalScriptPath as NSString).lastPathComponent, process.processIdentifier)
                    self.sendUserNotification(identifier: "python_app_started_\(UUID().uuidString)",
                                               title: notificationTitle,
                                               body: notificationBody)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    print(String(format: NSLocalizedString("❌ Error running Python script: %@", comment: "Log message: Error running Python script. Parameter is the error description."), error.localizedDescription))
                    let errorMessage = String(format: NSLocalizedString("An error occurred while running Python script '%@':\n%@", comment: "Error alert message: Python script execution failed. Parameters are script path and error description."), finalScriptPath, error.localizedDescription)
                    self.showErrorAlert(message: errorMessage)
                    self.pythonAppProcess = nil
                    self.constructMenu()
                }
            }
        }
    }
    // --- END: Python Application Start Action (Updated for Venv) ---

    // MARK: - User Notifications (Sending & Receiving System Notifications)
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error = error { print(String(format: NSLocalizedString("❌ Notification permission error: %@", comment: "Log message: Error requesting notification permission. Parameter is error description."), error.localizedDescription)) }
                else { print(granted ? NSLocalizedString("✅ Notification permission granted.", comment: "Log message: Notification permission granted.") : NSLocalizedString("🚫 Notification permission denied.", comment: "Log message: Notification permission denied.")) }
            }
        }
    }

    // Sends the actual system notification
    func sendUserNotification(identifier: String = UUID().uuidString, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DispatchQueue.main.async { print(String(format: NSLocalizedString("❌ Failed to send notification: %@ - %@", comment: "Log message: Failed to send notification. Parameters are identifier and error description."), identifier, error.localizedDescription)) }
            }
        }
    }

    // UNUserNotificationCenterDelegate: Handle user interaction with notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        print(String(format: NSLocalizedString("Notification response received: %@", comment: "Log message: Received response to a notification. Parameter is the identifier."), identifier))
        NSApp.activate(ignoringOtherApps: true) // Bring app to front

        if identifier == "cloudflared_not_found" {
            openSettingsWindowAction()
        } else if identifier.starts(with: "quick_url_") {
            let body = response.notification.request.content.body
            if let url = extractTryCloudflareURL(from: body) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                sendUserNotification(identifier: "url_copied_from_notif_\(UUID().uuidString)", title: NSLocalizedString("URL Copied", comment: "Notification title: URL copied to clipboard"), body: url)
            }
        } else if identifier.starts(with: "vhost_success_") {
            askToOpenMampConfigFolder()
        }
        // Add more handlers as needed...
        completionHandler()
    }

    // Helper to extract URL from notification body
    private func extractTryCloudflareURL(from text: String) -> String? {
        let pattern = #"(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
        if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
        return nil
    }
    
    // --- NEW ACTIONS TO OPEN SPECIFIC FILES ---
    @objc func openMampVHostFileAction() { // Opens vhost FILE
        guard let path = tunnelManager?.mampVHostConfPath, FileManager.default.fileExists(atPath: path) else {
            print(String(format: NSLocalizedString("⚠️ MAMP vHost file not found or path could not be retrieved: %@", comment: "Log message: MAMP vHost file not found. Parameter is the path or N/A."), tunnelManager?.mampVHostConfPath ?? "N/A"))
            // Optional: Show error to user if desired
            // showErrorAlert(message: NSLocalizedString("MAMP httpd-vhosts.conf file not found.", comment: "Error message: MAMP vhosts file not found"))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func openMampHttpdConfFileAction() { // Opens httpd.conf FILE
        guard let path = tunnelManager?.mampHttpdConfPath, FileManager.default.fileExists(atPath: path) else {
            print(String(format: NSLocalizedString("⚠️ MAMP httpd.conf file not found or path could not be retrieved: %@", comment: "Log message: MAMP httpd.conf file not found. Parameter is the path or N/A."), tunnelManager?.mampHttpdConfPath ?? "N/A"))
            // Optional: Show error to user if desired
            // showErrorAlert(message: NSLocalizedString("MAMP httpd.conf file not found.", comment: "Error message: MAMP httpd.conf file not found"))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    
 
    // --- END NEW ACTIONS ---
    
    // --- NEW: Stop Python Application Action ---
    @objc func stopPythonAppAction() {
        guard let process = pythonAppProcess, process.isRunning else {
            print(NSLocalizedString("ℹ️ No running Python script found to stop.", comment: "Log message: Python script not running, cannot stop."))
            // If reference exists but process is not running, clean up and update menu
            if pythonAppProcess != nil && !pythonAppProcess!.isRunning {
                 DispatchQueue.main.async {
                     self.pythonAppProcess = nil
                     self.constructMenu()
                 }
            }
            return
        }

        print(String(format: NSLocalizedString("🛑 Stopping Python script (PID: %d)...", comment: "Log message: Stopping Python script. Parameter is PID."), process.processIdentifier))
        process.terminate() // Sends SIGTERM

        // Termination handler will already set pythonAppProcess to nil and update the menu.
        // Optionally, we can send a notification here immediately:
        DispatchQueue.main.async {
            let notificationTitle = NSLocalizedString("Stopping Python Application", comment: "Notification title: Python app stopping")
            let notificationBody = String(format: NSLocalizedString("Stop signal sent for %@.", comment: "Notification body: Stop signal sent for Python script. Parameter is script name."), (self.pythonScriptPath as NSString).lastPathComponent)
            self.sendUserNotification(identifier: "python_app_stopping_\(UUID().uuidString)",
                                       title: notificationTitle,
                                       body: notificationBody)
             // Optionally: We can update the menu immediately for faster user feedback,
             // but waiting for the termination handler to run reflects the state more accurately.
             // self.constructMenu() // You can uncomment this line if desired.
        }
    }
    // --- END: Stop Python Application Action ---

    // MARK: - Menu Construction
    @objc func constructMenu() {
        guard let tunnelManager = tunnelManager else {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: NSLocalizedString("Error: Manager could not be initialized", comment: "Menu item: Error when tunnel manager fails to init"), action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: "Menu item: Quit application"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.menu = menu
            return
        }

        let menu = NSMenu()
        let isCloudflaredAvailable = FileManager.default.fileExists(atPath: tunnelManager.cloudflaredExecutablePath)

        // --- Cloudflared Status / Login ---
        if !isCloudflaredAvailable {
            let item = NSMenuItem(title: NSLocalizedString("❗️ cloudflared not found!", comment: "Menu item: cloudflared executable not found"), action: #selector(openSettingsWindowAction), keyEquivalent: "")
            item.target = self
            item.toolTip = NSLocalizedString("Please correct the cloudflared path in Settings.", comment: "Tooltip: Instructs user to fix cloudflared path in settings")
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: NSLocalizedString("Cloudflared Not Found", comment: "Accessibility description for cloudflared not found icon"))
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        } else {
            let loginItem = NSMenuItem(title: NSLocalizedString("Cloudflare Login / Check...", comment: "Menu item: Cloudflare login or check status"), action: #selector(cloudflareLoginAction), keyEquivalent: "")
            loginItem.target = self
            loginItem.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: NSLocalizedString("Cloudflare Login", comment: "Accessibility description for Cloudflare login icon"))
            menu.addItem(loginItem)
            menu.addItem(NSMenuItem.separator())
        }

        // --- Quick Tunnels Section ---
        let quickTunnels = tunnelManager.quickTunnels
        if !quickTunnels.isEmpty {
            let quickTunnelsHeader = NSMenuItem(title: NSLocalizedString("Quick Tunnels", comment: "Menu section header: Quick Tunnels"), action: nil, keyEquivalent: "")
            quickTunnelsHeader.isEnabled = false
            quickTunnelsHeader.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: NSLocalizedString("Quick Tunnels", comment: "Accessibility description for quick tunnels icon"))
            menu.addItem(quickTunnelsHeader)
            
            for quickTunnelData in quickTunnels {
                let displayTitle: String
                var toolTip = String(format: NSLocalizedString("Local: %@", comment: "Tooltip part: Local URL. Parameter is the URL."), quickTunnelData.localURL)
                if let url = quickTunnelData.publicURL {
                    displayTitle = url.replacingOccurrences(of: "https://", with: "")
                    toolTip += String(format: NSLocalizedString("\nPublic: %@\n(Click to copy)", comment: "Tooltip part: Public URL and instruction to copy. Parameter is the URL."), url)
                } else if let error = quickTunnelData.lastError {
                    displayTitle = String(format: NSLocalizedString("%@ (Error)", comment: "Menu item display for quick tunnel with error. Parameter is local URL."), quickTunnelData.localURL)
                    toolTip += String(format: NSLocalizedString("\nError: %@", comment: "Tooltip part: Error message. Parameter is the error."), error)
                } else {
                    displayTitle = String(format: NSLocalizedString("%@ (Starting/Waiting...)", comment: "Menu item display for quick tunnel starting/waiting. Parameter is local URL."), quickTunnelData.localURL)
                    toolTip += NSLocalizedString("\n(Waiting for URL...)", comment: "Tooltip part: Waiting for public URL.")
                }
                if let pid = quickTunnelData.processIdentifier { toolTip += String(format: NSLocalizedString("\nPID: %d", comment: "Tooltip part: Process ID. Parameter is the PID."), pid) }
                
                let quickItem = NSMenuItem(title: displayTitle, action: #selector(copyQuickTunnelURLAction(_:)), keyEquivalent: "")
                quickItem.target = self
                quickItem.representedObject = quickTunnelData
                quickItem.toolTip = toolTip
                quickItem.isEnabled = (quickTunnelData.publicURL != nil)
                quickItem.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: NSLocalizedString("Quick Tunnel", comment: "Accessibility description for quick tunnel icon"))
                
                let subMenu = NSMenu()
                let stopQuickItem = NSMenuItem(title: NSLocalizedString("Stop This Quick Tunnel", comment: "Menu item: Stop a specific quick tunnel"), action: #selector(stopQuickTunnelAction(_:)), keyEquivalent: "")
                stopQuickItem.target = self
                stopQuickItem.representedObject = quickTunnelData.id
                stopQuickItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: NSLocalizedString("Stop Quick Tunnel", comment: "Accessibility description for stop quick tunnel icon"))
                subMenu.addItem(stopQuickItem)
                quickItem.submenu = subMenu
                menu.addItem(quickItem)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // --- Managed Tunnels Section ---
        let managedTunnels = tunnelManager.tunnels
        if !managedTunnels.isEmpty {
            let managedTunnelsHeader = NSMenuItem(title: NSLocalizedString("Managed Tunnels (via Config)", comment: "Menu section header: Managed Tunnels"), action: nil, keyEquivalent: "")
            managedTunnelsHeader.isEnabled = false
            managedTunnelsHeader.image = NSImage(systemSymbolName: "network", accessibilityDescription: NSLocalizedString("Managed Tunnels", comment: "Accessibility description for managed tunnels icon"))
            menu.addItem(managedTunnelsHeader)
            
            for tunnel in managedTunnels {
                let titleText: String
                let statusIcon: String
                
                switch tunnel.status {
                case .running:
                    statusIcon = "checkmark.circle.fill"
                    titleText = tunnel.name
                case .stopped:
                    statusIcon = "stop.circle.fill"
                    titleText = tunnel.name
                case .starting:
                    statusIcon = "arrow.clockwise.circle"
                    titleText = String(format: NSLocalizedString("%@ (Starting...)", comment: "Menu item display for tunnel starting. Parameter is tunnel name."), tunnel.name)
                case .stopping:
                    statusIcon = "stop.circle"
                    titleText = String(format: NSLocalizedString("%@ (Stopping...)", comment: "Menu item display for tunnel stopping. Parameter is tunnel name."), tunnel.name)
                case .error:
                    statusIcon = "exclamationmark.circle.fill"
                    titleText = String(format: NSLocalizedString("%@ (Error)", comment: "Menu item display for tunnel with error. Parameter is tunnel name."), tunnel.name)
                }
                
                let mainMenuItem = NSMenuItem(title: titleText, action: nil, keyEquivalent: "")
                mainMenuItem.image = NSImage(systemSymbolName: statusIcon, accessibilityDescription: NSLocalizedString("Tunnel Status", comment: "Accessibility description for tunnel status icon"))
                
                var toolTipParts: [String] = [String(format: NSLocalizedString("Status: %@", comment: "Tooltip part: Tunnel status. Parameter is status display name."), tunnel.status.displayName)]
                if let uuid = tunnel.uuidFromConfig { toolTipParts.append(String(format: NSLocalizedString("UUID: %@", comment: "Tooltip part: Tunnel UUID. Parameter is the UUID."), uuid))}
                else { toolTipParts.append(NSLocalizedString("UUID: (Could not read from Config)", comment: "Tooltip part: Tunnel UUID could not be read from config.")) }
                if let path = tunnel.configPath { toolTipParts.append(String(format: NSLocalizedString("Config: %@", comment: "Tooltip part: Config file path. Parameter is the path."), (path as NSString).abbreviatingWithTildeInPath)) }
                if let pid = tunnel.processIdentifier { toolTipParts.append(String(format: NSLocalizedString("PID: %d", comment: "Tooltip part: Process ID. Parameter is PID."), pid)) }
                if let err = tunnel.lastError, !err.isEmpty { toolTipParts.append(String(format: NSLocalizedString("Last Error: %@", comment: "Tooltip part: Last error message. Parameter is the error."), err.split(separator: "\n").first ?? ""))}
                mainMenuItem.toolTip = toolTipParts.joined(separator: "\n")
                
                let subMenu = NSMenu()
                let canToggle = tunnel.isManaged && tunnel.status != .starting && tunnel.status != .stopping && isCloudflaredAvailable
                let toggleTitle = (tunnel.status == .running) ? NSLocalizedString("Stop", comment: "Menu item: Stop tunnel") : NSLocalizedString("Start", comment: "Menu item: Start tunnel")
                let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleManagedTunnelAction(_:)), keyEquivalent: "")
                toggleItem.target = self
                toggleItem.representedObject = tunnel
                toggleItem.isEnabled = canToggle
                toggleItem.image = NSImage(systemSymbolName: tunnel.status == .running ? "stop.circle" : "play.circle", accessibilityDescription: toggleTitle)
                subMenu.addItem(toggleItem)
                subMenu.addItem(NSMenuItem.separator())
                
                let canOpenConfig = tunnel.configPath != nil && FileManager.default.fileExists(atPath: tunnel.configPath!)
                let openConfigItem = NSMenuItem(title: NSLocalizedString("Open Config File (.yml)", comment: "Menu item: Open tunnel config file"), action: #selector(openConfigFileAction(_:)), keyEquivalent: "")
                openConfigItem.target = self
                openConfigItem.representedObject = tunnel
                openConfigItem.isEnabled = canOpenConfig
                openConfigItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: NSLocalizedString("Open Config", comment: "Accessibility description for open config icon"))
                subMenu.addItem(openConfigItem)
                
                let canRouteDns = tunnel.isManaged && isCloudflaredAvailable
                let routeDnsItem = NSMenuItem(title: NSLocalizedString("Route DNS Record...", comment: "Menu item: Route DNS record for tunnel"), action: #selector(routeDnsForTunnelAction(_:)), keyEquivalent: "")
                routeDnsItem.target = self
                routeDnsItem.representedObject = tunnel
                routeDnsItem.isEnabled = canRouteDns
                routeDnsItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: NSLocalizedString("Route DNS", comment: "Accessibility description for route DNS icon"))
                subMenu.addItem(routeDnsItem)
                subMenu.addItem(NSMenuItem.separator())
                
                let canDelete = tunnel.isManaged && tunnel.status != .stopping && tunnel.status != .starting && isCloudflaredAvailable
                let deleteItem = NSMenuItem(title: NSLocalizedString("Delete This Tunnel...", comment: "Menu item: Delete this tunnel"), action: #selector(deleteTunnelAction(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = tunnel
                deleteItem.isEnabled = canDelete
                deleteItem.toolTip = NSLocalizedString("Deletes the tunnel from Cloudflare and optionally local files. ATTENTION! Cannot be undone.", comment: "Tooltip: Delete tunnel warning")
                deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: NSLocalizedString("Delete Tunnel", comment: "Accessibility description for delete tunnel icon"))
                deleteItem.attributedTitle = NSAttributedString(string: deleteItem.title, attributes: [.foregroundColor: NSColor.systemRed])
                subMenu.addItem(deleteItem)
                
                mainMenuItem.submenu = subMenu
                menu.addItem(mainMenuItem)
            }
        }

        // --- Placeholder or Separator ---
        if managedTunnels.isEmpty && quickTunnels.isEmpty && isCloudflaredAvailable {
            let noTunnelsItem = NSMenuItem(title: NSLocalizedString("No tunnels found", comment: "Menu item: Displayed when no tunnels are available"), action: nil, keyEquivalent: "")
            noTunnelsItem.isEnabled = false
            noTunnelsItem.image = NSImage(systemSymbolName: "network.slash", accessibilityDescription: NSLocalizedString("No Tunnels", comment: "Accessibility description for no tunnels icon"))
            menu.addItem(noTunnelsItem)
        }
        if !managedTunnels.isEmpty || !quickTunnels.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        // --- Bulk Actions ---
        let canStartAnyManaged = isCloudflaredAvailable && managedTunnels.contains { $0.isManaged && ($0.status == .stopped || $0.status == .error) }
        let startAllItem = NSMenuItem(title: NSLocalizedString("Start All Managed", comment: "Menu item: Start all managed tunnels"), action: #selector(startAllManagedTunnelsAction), keyEquivalent: "")
        startAllItem.target = self
        startAllItem.isEnabled = canStartAnyManaged
        startAllItem.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: NSLocalizedString("Start All Managed", comment: "Accessibility description for start all managed icon"))
        menu.addItem(startAllItem)

        let canStopAny = isCloudflaredAvailable && (managedTunnels.contains { $0.isManaged && [.running, .stopping, .starting].contains($0.status) } || !quickTunnels.isEmpty)
        let stopAllItem = NSMenuItem(title: NSLocalizedString("Stop All Tunnels", comment: "Menu item: Stop all tunnels"), action: #selector(stopAllTunnelsAction), keyEquivalent: "")
        stopAllItem.target = self
        stopAllItem.isEnabled = canStopAny
        stopAllItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: NSLocalizedString("Stop All Tunnels", comment: "Accessibility description for stop all tunnels icon"))
        menu.addItem(stopAllItem)
        menu.addItem(NSMenuItem.separator())

        // --- Create Actions ---
        let createMenu = NSMenu()
        let createManagedItem = NSMenuItem(title: NSLocalizedString("New Managed Tunnel (with Config)...", comment: "Menu item: Create new managed tunnel"), action: #selector(openCreateManagedTunnelWindow), keyEquivalent: "n")
        createManagedItem.target = self
        createManagedItem.isEnabled = isCloudflaredAvailable
        createManagedItem.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: NSLocalizedString("New Managed Tunnel", comment: "Accessibility description for new managed tunnel icon"))
        createMenu.addItem(createManagedItem)

        let createMampItem = NSMenuItem(title: NSLocalizedString("Create from MAMP Site...", comment: "Menu item: Create tunnel from MAMP site"), action: #selector(openCreateFromMampWindow), keyEquivalent: "")
        createMampItem.target = self
        createMampItem.isEnabled = isCloudflaredAvailable && FileManager.default.fileExists(atPath: tunnelManager.mampSitesDirectoryPath)
        createMampItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: NSLocalizedString("Create from MAMP", comment: "Accessibility description for create from MAMP icon"))
        if !FileManager.default.fileExists(atPath: tunnelManager.mampSitesDirectoryPath) && isCloudflaredAvailable {
            createMampItem.toolTip = String(format: NSLocalizedString("MAMP site directory not found: %@", comment: "Tooltip: MAMP site directory not found. Parameter is the path."), tunnelManager.mampSitesDirectoryPath)
        }
        createMenu.addItem(createMampItem)

        let createMenuItem = NSMenuItem(title: NSLocalizedString("Create / Start", comment: "Menu section header: Create/Start tunnels"), action: nil, keyEquivalent: "")
        createMenuItem.submenu = createMenu
        createMenuItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: NSLocalizedString("Create/Start", comment: "Accessibility description for create/start icon"))
        menu.addItem(createMenuItem)
        menu.addItem(NSMenuItem.separator())

        // --- Folder Management ---
        let folderMenu = NSMenu()
        let openCloudflaredItem = NSMenuItem(title: NSLocalizedString("Open ~/.cloudflared Folder", comment: "Menu item: Open .cloudflared folder"), action: #selector(openCloudflaredFolderAction), keyEquivalent: "")
        openCloudflaredItem.target = self
        openCloudflaredItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.cloudflaredDirectoryPath)
        openCloudflaredItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: NSLocalizedString("Open Cloudflared Folder", comment: "Accessibility description for open cloudflared folder icon"))
        folderMenu.addItem(openCloudflaredItem)

        let openMampConfigItem = NSMenuItem(title: NSLocalizedString("Open MAMP Apache Conf Folder", comment: "Menu item: Open MAMP Apache config folder"), action: #selector(openMampConfigFolderAction), keyEquivalent: "")
        openMampConfigItem.target = self
        openMampConfigItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.mampConfigDirectoryPath)
        openMampConfigItem.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: NSLocalizedString("Open MAMP Config Folder", comment: "Accessibility description for open MAMP config folder icon"))
        folderMenu.addItem(openMampConfigItem)

        let folderMenuItem = NSMenuItem(title: NSLocalizedString("Folder Management", comment: "Menu section header: Folder Management"), action: nil, keyEquivalent: "")
        folderMenuItem.submenu = folderMenu
        folderMenuItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: NSLocalizedString("Folder Management", comment: "Accessibility description for folder management icon"))
        menu.addItem(folderMenuItem)
        menu.addItem(NSMenuItem.separator())

        // --- File Management ---
        let fileMenu = NSMenu()
        let openVHostFileItem = NSMenuItem(title: NSLocalizedString("Open File (httpd-vhosts.conf)", comment: "Menu item: Open MAMP vhosts file"), action: #selector(openMampVHostFileAction), keyEquivalent: "")
        openVHostFileItem.target = self
        openVHostFileItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.mampVHostConfPath)
        openVHostFileItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: NSLocalizedString("Open vHost File", comment: "Accessibility description for open vhost file icon"))
        openVHostFileItem.toolTip = NSLocalizedString("Opens MAMP's virtual host configuration file.", comment: "Tooltip: Explains what open vhost file does")
        fileMenu.addItem(openVHostFileItem)

        let openHttpdFileItem = NSMenuItem(title: NSLocalizedString("Open File (httpd.conf)", comment: "Menu item: Open MAMP httpd.conf file"), action: #selector(openMampHttpdConfFileAction), keyEquivalent: "")
        openHttpdFileItem.target = self
        openHttpdFileItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.mampHttpdConfPath)
        openHttpdFileItem.image = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: NSLocalizedString("Open httpd.conf File", comment: "Accessibility description for open httpd.conf file icon"))
        openHttpdFileItem.toolTip = NSLocalizedString("Opens MAMP's main Apache configuration file.", comment: "Tooltip: Explains what open httpd.conf file does")
        fileMenu.addItem(openHttpdFileItem)

        let fileMenuItem = NSMenuItem(title: NSLocalizedString("File Management", comment: "Menu section header: File Management"), action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        fileMenuItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: NSLocalizedString("File Management", comment: "Accessibility description for file management icon"))
        menu.addItem(fileMenuItem)
        menu.addItem(NSMenuItem.separator())

        // --- MAMP Server Control Section ---
        let mampMenu = NSMenu()
        let startMampItem = NSMenuItem(title: NSLocalizedString("Start MAMP Servers", comment: "Menu item: Start MAMP servers"), action: #selector(startMampServersAction), keyEquivalent: "")
        startMampItem.target = self
        startMampItem.isEnabled = isCloudflaredAvailable && FileManager.default.isExecutableFile(atPath: "\(mampBasePath)/\(mampStartScript)") && FileManager.default.isExecutableFile(atPath: "\(mampBasePath)/\(mampStopScript)")
        startMampItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: NSLocalizedString("Start MAMP Servers", comment: "Accessibility description for start MAMP servers icon"))
        if !startMampItem.isEnabled {
            startMampItem.toolTip = String(format: NSLocalizedString("MAMP start/stop scripts not found.\nPath: %@", comment: "Tooltip: MAMP scripts not found. Parameter is the path."), mampBasePath)
        }
        mampMenu.addItem(startMampItem)

        let stopMampItem = NSMenuItem(title: NSLocalizedString("Stop MAMP Servers", comment: "Menu item: Stop MAMP servers"), action: #selector(stopMampServersAction), keyEquivalent: "")
        stopMampItem.target = self
        stopMampItem.isEnabled = isCloudflaredAvailable && FileManager.default.isExecutableFile(atPath: "\(mampBasePath)/\(mampStartScript)") && FileManager.default.isExecutableFile(atPath: "\(mampBasePath)/\(mampStopScript)")
        stopMampItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: NSLocalizedString("Stop MAMP Servers", comment: "Accessibility description for stop MAMP servers icon"))
        if !stopMampItem.isEnabled {
            stopMampItem.toolTip = String(format: NSLocalizedString("MAMP start/stop scripts not found.\nPath: %@", comment: "Tooltip: MAMP scripts not found. Parameter is the path."), mampBasePath)
        }
        mampMenu.addItem(stopMampItem)

        let mampMenuItem = NSMenuItem(title: NSLocalizedString("MAMP Management", comment: "Menu section header: MAMP Management"), action: nil, keyEquivalent: "")
        mampMenuItem.submenu = mampMenu
        mampMenuItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: NSLocalizedString("MAMP Management", comment: "Accessibility description for MAMP management icon"))
        menu.addItem(mampMenuItem)
        menu.addItem(NSMenuItem.separator())

        // --- Python Panel Section ---
        let pythonMenu = NSMenu()
        let pythonAppItem = NSMenuItem(title: NSLocalizedString("Start Python Application", comment: "Menu item: Start Python application"), action: #selector(startPythonAppAction), keyEquivalent: "")
        pythonAppItem.target = self
        pythonAppItem.isEnabled = isCloudflaredAvailable && FileManager.default.fileExists(atPath: pythonScriptPath) && (pythonAppProcess == nil || !pythonAppProcess!.isRunning)
        pythonAppItem.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: NSLocalizedString("Start Python App", comment: "Accessibility description for start Python app icon"))
        if !FileManager.default.fileExists(atPath: pythonScriptPath) {
            pythonAppItem.toolTip = String(format: NSLocalizedString("Python script not found: %@", comment: "Tooltip: Python script not found. Parameter is path."), pythonScriptPath)
        } else if pythonAppProcess != nil && pythonAppProcess!.isRunning {
            pythonAppItem.toolTip = String(format: NSLocalizedString("Application is already running (PID: %d).", comment: "Tooltip: Python app already running. Parameter is PID."), pythonAppProcess!.processIdentifier)
        } else {
            pythonAppItem.toolTip = String(format: NSLocalizedString("Runs the script with venv: %@", comment: "Tooltip: Explains running Python script with venv. Parameter is path."), pythonScriptPath)
        }
        pythonMenu.addItem(pythonAppItem)

        let stopPythonItem = NSMenuItem(title: NSLocalizedString("Stop Python Application", comment: "Menu item: Stop Python application"), action: #selector(stopPythonAppAction), keyEquivalent: "")
        stopPythonItem.target = self
        stopPythonItem.isEnabled = isCloudflaredAvailable && pythonAppProcess != nil && pythonAppProcess!.isRunning
        stopPythonItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: NSLocalizedString("Stop Python App", comment: "Accessibility description for stop Python app icon"))
        if pythonAppProcess != nil && pythonAppProcess!.isRunning {
            stopPythonItem.toolTip = String(format: NSLocalizedString("Stops the running application (PID: %d).", comment: "Tooltip: Explains stopping Python app. Parameter is PID."), pythonAppProcess!.processIdentifier)
        } else {
            stopPythonItem.toolTip = NSLocalizedString("No running Python application.", comment: "Tooltip: No Python app is running.")
        }
        pythonMenu.addItem(stopPythonItem)

        let pythonMenuItem = NSMenuItem(title: NSLocalizedString("Python Panel", comment: "Menu section header: Python Panel"), action: nil, keyEquivalent: "")
        pythonMenuItem.submenu = pythonMenu
        pythonMenuItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: NSLocalizedString("Python Panel", comment: "Accessibility description for Python panel icon"))
        menu.addItem(pythonMenuItem)
        menu.addItem(NSMenuItem.separator())

        // --- Refresh, PDF Guide, Settings, Quit ---
        let refreshItem = NSMenuItem(title: NSLocalizedString("Refresh List (Managed)", comment: "Menu item: Refresh managed tunnel list"), action: #selector(refreshManagedTunnelListAction), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: NSLocalizedString("Refresh List", comment: "Accessibility description for refresh list icon"))
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())

        let setupPdfItem = NSMenuItem(title: NSLocalizedString("Open Setup Guide (PDF)", comment: "Menu item: Open setup guide PDF"), action: #selector(openSetupPdfAction), keyEquivalent: "")
        setupPdfItem.target = self
        setupPdfItem.image = NSImage(systemSymbolName: "book.fill", accessibilityDescription: NSLocalizedString("Open Setup Guide", comment: "Accessibility description for open setup guide icon"))
        menu.addItem(setupPdfItem)
        menu.addItem(NSMenuItem.separator())

        // --- Launch At Login (macOS 13+) ---
        if #available(macOS 13.0, *) {
            let launchAtLoginItem = NSMenuItem(title: NSLocalizedString("Launch at Login", comment: "Menu item: Toggle launch at login"), action: #selector(toggleLaunchAtLoginAction(_:)), keyEquivalent: "")
            launchAtLoginItem.target = self
            launchAtLoginItem.state = tunnelManager.isLaunchAtLoginEnabled() ? .on : .off
            launchAtLoginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: NSLocalizedString("Launch at Login", comment: "Accessibility description for launch at login icon"))
            menu.addItem(launchAtLoginItem)
        } else {
            let launchAtLoginItem = NSMenuItem(title: NSLocalizedString("Launch at Login (macOS 13+)", comment: "Menu item: Launch at login (disabled for older macOS)"), action: nil, keyEquivalent: "")
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: NSLocalizedString("Launch at Login", comment: "Accessibility description for launch at login icon"))
            menu.addItem(launchAtLoginItem)
        }

        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item: Open settings window"), action: #selector(openSettingsWindowAction), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: NSLocalizedString("Settings", comment: "Accessibility description for settings icon"))
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("Quit Cloudflared Manager", comment: "Menu item: Quit application with app name"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: NSLocalizedString("Quit", comment: "Accessibility description for quit icon"))
        menu.addItem(quitItem)

        // Update the status item's menu
        statusItem?.menu = menu
    }

    // MARK: - Menu Actions (@objc Wrappers)

    // Managed Tunnel Actions
    @objc func toggleManagedTunnelAction(_ sender: NSMenuItem) { guard let tunnel = sender.representedObject as? TunnelInfo else { return }; tunnelManager?.toggleManagedTunnel(tunnel) }
    @objc func startAllManagedTunnelsAction() { tunnelManager?.startAllManagedTunnels() }
    @objc func stopAllTunnelsAction() { tunnelManager?.stopAllTunnels(synchronous: false) } // Default async stop
    @objc func refreshManagedTunnelListAction() { tunnelManager?.findManagedTunnels() }
    @objc func openConfigFileAction(_ sender: NSMenuItem) {
        guard let tunnel = sender.representedObject as? TunnelInfo, let path = tunnel.configPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func deleteTunnelAction(_ sender: NSMenuItem) {
        guard let tunnel = sender.representedObject as? TunnelInfo, tunnel.isManaged else { return }
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Delete Tunnel '%@'", comment: "Alert title: Delete tunnel. Parameter is tunnel name."), tunnel.name)
        alert.informativeText = NSLocalizedString("This action will permanently delete the tunnel from Cloudflare.\n\n⚠️ THIS ACTION CANNOT BE UNDONE! ⚠️\n\nAre you sure?", comment: "Alert informative text: Warning about permanent deletion of tunnel.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("Yes, Permanently Delete", comment: "Alert button: Confirm permanent deletion"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button: Cancel action"))
        if alert.buttons.count > 0 { alert.buttons[0].hasDestructiveAction = true }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                print(String(format: NSLocalizedString("Deletion process starting for: %@", comment: "Log message: Starting tunnel deletion. Parameter is tunnel name."), tunnel.name))
                self.tunnelManager?.deleteTunnel(tunnelInfo: tunnel) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            let successTitle = NSLocalizedString("Tunnel Deleted", comment: "Notification title: Tunnel deleted successfully")
                            let successBody = String(format: NSLocalizedString("'%@' was deleted from Cloudflare.", comment: "Notification body: Tunnel deleted from Cloudflare. Parameter is tunnel name."), tunnel.name)
                            self.sendUserNotification(identifier:"deleted_\(tunnel.id)", title: successTitle, body: successBody)
                            self.askToDeleteLocalFiles(for: tunnel)
                            self.tunnelManager?.findManagedTunnels() // Refresh list
                        case .failure(let error):
                            let errorMessage = String(format: NSLocalizedString("Error deleting tunnel '%@':\n%@", comment: "Error alert: Failed to delete tunnel. Parameters are tunnel name and error description."), tunnel.name, error.localizedDescription)
                            self.showErrorAlert(message: errorMessage)
                        }
                    }
                }
            } else {
                print(NSLocalizedString("Deletion cancelled.", comment: "Log message: Tunnel deletion was cancelled by user."))
            }
        }
    }

    @objc func routeDnsForTunnelAction(_ sender: NSMenuItem) {
        guard let tunnel = sender.representedObject as? TunnelInfo, tunnel.isManaged, let tunnelManager = tunnelManager else { return }
        let suggestedHostname = tunnelManager.findHostname(for: tunnel.configPath ?? "") ?? "\(tunnel.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }).adilemre.xyz"

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Route DNS Record", comment: "Alert title: Route DNS record")
        alert.informativeText = String(format: NSLocalizedString("Enter the hostname to route to tunnel '%@' (UUID: %@):", comment: "Alert informative text: Prompt for hostname for DNS routing. Parameters are tunnel name and UUID."), tunnel.name, tunnel.uuidFromConfig ?? NSLocalizedString("N/A", comment: "Not Applicable short form"))
        alert.addButton(withTitle: NSLocalizedString("Route", comment: "Alert button: Route DNS"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button: Cancel action"))

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.stringValue = suggestedHostname
        inputField.placeholderString = NSLocalizedString("e.g., app.yourdomain.com", comment: "Placeholder for hostname input field")
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let hostname = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hostname.isEmpty && hostname.contains(".") else {
                self.showErrorAlert(message: NSLocalizedString("Invalid hostname format.", comment: "Error message: Invalid hostname format for DNS routing"))
                return
            }
            self.tunnelManager.routeDns(tunnelInfo: tunnel, hostname: hostname) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let output):
                        let successTitle = NSLocalizedString("DNS Routing Successful", comment: "Info alert title: DNS routing successful")
                        let successMessage = String(format: NSLocalizedString("DNS record for '%@' was successfully created or updated.\n\n%@", comment: "Info alert message: DNS record created/updated. Parameters are hostname and output from command."), hostname, output)
                        self.showInfoAlert(title: successTitle, message: successMessage)
                        let notificationTitle = NSLocalizedString("DNS Routed", comment: "Notification title: DNS record routed")
                        let notificationBody = String(format: NSLocalizedString("%@ -> %@", comment: "Notification body: DNS routed from hostname to tunnel name. Parameters are hostname and tunnel name."), hostname, tunnel.name)
                        self.sendUserNotification(identifier:"dns_routed_\(tunnel.id)_\(hostname)", title: notificationTitle, body: notificationBody)
                    case .failure(let error):
                        let errorMessage = String(format: NSLocalizedString("DNS routing error for '%@':\n%@", comment: "Error alert: DNS routing failed. Parameters are hostname and error description."), hostname, error.localizedDescription)
                        self.showErrorAlert(message: errorMessage)
                    }
                }
            }
        } else {
            print(NSLocalizedString("DNS routing cancelled.", comment: "Log message: DNS routing was cancelled by user."))
        }
    }

    // Quick Tunnel Actions (startQuickTunnelAction uses beginSheetModal, could be changed to runModal if preferred)
    @objc func startQuickTunnelAction(_ sender: Any) {
        guard let tunnelManager = tunnelManager else { return }
        let alert = NSAlert();
        alert.messageText = NSLocalizedString("Start Quick Tunnel", comment: "Alert title: Start a quick tunnel");
        alert.informativeText = NSLocalizedString("Enter the local URL to expose:", comment: "Alert informative text: Prompt for local URL for quick tunnel");
        alert.addButton(withTitle: NSLocalizedString("Start", comment: "Alert button: Start action"));
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button: Cancel action"))
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24));
        inputField.placeholderString = NSLocalizedString("http://localhost:8000", comment: "Placeholder for local URL input field");
        alert.accessoryView = inputField;

        // Using runModal for consistency, replace if sheet is strongly preferred for this one case
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = inputField
            let response = alert.runModal() // Changed to runModal

            if response == .alertFirstButtonReturn {
                let localURL = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !localURL.isEmpty, let url = URL(string: localURL), url.scheme != nil, url.host != nil else {
                    self.showErrorAlert(message: NSLocalizedString("Invalid local URL format.\n(e.g., http://localhost:8000)", comment: "Error message: Invalid local URL format for quick tunnel")); return
                }
                tunnelManager.startQuickTunnel(localURL: localURL) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let tunnelID):
                            print(String(format: NSLocalizedString("Quick tunnel start process submitted, ID: %@", comment: "Log message: Quick tunnel start submitted. Parameter is tunnel ID."), tunnelID.uuidString))
                        case .failure(let error):
                            let errorMessage = String(format: NSLocalizedString("Could not start quick tunnel:\n%@", comment: "Error alert: Failed to start quick tunnel. Parameter is error description."), error.localizedDescription)
                            self.showErrorAlert(message: errorMessage)
                        }
                    }
                }
            } else { print(NSLocalizedString("Quick tunnel start cancelled.", comment: "Log message: Quick tunnel start cancelled by user.")) }
        }
    }

    @objc func stopQuickTunnelAction(_ sender: NSMenuItem) {
        guard let tunnelID = sender.representedObject as? UUID, let tunnelManager = tunnelManager else { return }
        tunnelManager.stopQuickTunnel(id: tunnelID)
    }
    @objc func copyQuickTunnelURLAction(_ sender: NSMenuItem) {
        guard let tunnelData = sender.representedObject as? QuickTunnelData, let urlString = tunnelData.publicURL else {
            sendUserNotification(identifier: "copy_fail_\(UUID().uuidString)", title: NSLocalizedString("Could Not Copy", comment: "Notification title: Failed to copy URL"), body: NSLocalizedString("Tunnel URL is not available yet.", comment: "Notification body: Tunnel URL not yet available for copying"))
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlString, forType: .string)
        sendUserNotification(identifier: "url_copied_\(tunnelData.id)", title: NSLocalizedString("URL Copied", comment: "Notification title: URL copied to clipboard"), body: urlString)
    }

    // Folder Actions
    @objc func openCloudflaredFolderAction() { guard let path = tunnelManager?.cloudflaredDirectoryPath else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    @objc func openMampConfigFolderAction() { guard let path = tunnelManager?.mampConfigDirectoryPath else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: path)) }


    // Cloudflare Login Action
    @objc func cloudflareLoginAction() {
        tunnelManager?.cloudflareLogin { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.sendUserNotification(identifier: "login_check_complete", title: NSLocalizedString("Cloudflare Login Check", comment: "Notification title: Cloudflare login check"), body: NSLocalizedString("Process started or status checked. Check browser if needed.", comment: "Notification body: Cloudflare login process started or status checked."))
                case .failure(let error):
                    let errorMessage = String(format: NSLocalizedString("Error during Cloudflare login process:\n%@", comment: "Error alert: Cloudflare login failed. Parameter is error description."), error.localizedDescription)
                    self?.showErrorAlert(message: errorMessage)
                }
            }
        }
    }

    // Launch At Login Action (macOS 13+)
    @objc func toggleLaunchAtLoginAction(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *), let tunnelManager = tunnelManager else {
            showErrorAlert(message: NSLocalizedString("This feature requires macOS 13 or later.", comment: "Error message: Feature requires macOS 13+"))
            return
        }
        tunnelManager.toggleLaunchAtLogin { result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let newStateEnabled):
                    sender.state = newStateEnabled ? .on : .off
                    let title = NSLocalizedString("Launch at Login", comment: "Notification title: Launch at login status changed")
                    let body = newStateEnabled ? NSLocalizedString("Enabled", comment: "Notification body: Launch at login enabled") : NSLocalizedString("Disabled", comment: "Notification body: Launch at login disabled")
                    self.sendUserNotification(identifier: "launch_toggle", title: title, body: body)
                case .failure(let error):
                    let errorMessage = String(format: NSLocalizedString("Error changing launch at login setting:\n%@", comment: "Error alert: Failed to change launch at login setting. Parameter is error description."), error.localizedDescription)
                    self.showErrorAlert(message: errorMessage)
                    sender.state = tunnelManager.isLaunchAtLoginEnabled() ? .on : .off // Revert UI
                }
            }
        }
    }

    // Action to Open Setup PDF
     @objc func openSetupPdfAction() {
         guard let pdfURL = Bundle.main.url(forResource: "kullanım", withExtension: "pdf") else {
             print(NSLocalizedString("❌ Error: Setup PDF not found in app bundle ('kullanım.pdf').", comment: "Log message: Setup PDF file not found in bundle."))
             showErrorAlert(message: NSLocalizedString("Setup guide PDF file not found.", comment: "Error message: Setup guide PDF not found."))
             return
         }
         print(String(format: NSLocalizedString("Opening Setup PDF: %@", comment: "Log message: Opening setup PDF. Parameter is path."), pdfURL.path))
         NSWorkspace.shared.open(pdfURL)
     }

     // --- [NEW] MAMP Control @objc Actions ---
     @objc func startMampServersAction() {
         executeMampCommand(
             scriptName: mampStartScript,
             successMessage: NSLocalizedString("Start command sent for MAMP servers (Apache & MySQL).", comment: "Success message for starting MAMP servers"),
             failureMessage: NSLocalizedString("Error starting MAMP servers.", comment: "Error message when starting MAMP servers fails")
         )
     }

     @objc func stopMampServersAction() {
         executeMampCommand(
             scriptName: mampStopScript,
             successMessage: NSLocalizedString("Stop command sent for MAMP servers (Apache & MySQL).", comment: "Success message for stopping MAMP servers"),
             failureMessage: NSLocalizedString("Error stopping MAMP servers.", comment: "Error message when stopping MAMP servers fails")
         )
     }
     // --- [END NEW] ---

    // MARK: - Window Management
    private func showWindow<Content: View>(
        _ windowPropertySetter: @escaping (NSWindow?) -> Void,
        _ existingWindowGetter: @escaping () -> NSWindow?,
        title: String,
        view: Content
    ) {
        DispatchQueue.main.async {
            guard let manager = self.tunnelManager else {
                print(NSLocalizedString("❌ Error: showWindow called but TunnelManager is not available.", comment: "Log message: Error in showWindow, TunnelManager is nil."))
                self.showErrorAlert(message: NSLocalizedString("Cannot open window: Tunnel Manager not found.", comment: "Error message: Cannot open window due to missing TunnelManager."))
                return
            }
            NSApp.activate(ignoringOtherApps: true)

            if let existingWindow = existingWindowGetter(), existingWindow.isVisible {
                existingWindow.center()
                existingWindow.makeKeyAndOrderFront(nil)
                print(String(format: NSLocalizedString("Existing window brought to front: %@", comment: "Log message: Existing window brought to front. Parameter is window title."), title))
                return
            }

            print(String(format: NSLocalizedString("Creating new window: %@", comment: "Log message: Creating new window. Parameter is window title."), title))
            let hostingController = NSHostingController(rootView: view.environmentObject(manager))
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable]
            newWindow.level = .normal
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            windowPropertySetter(newWindow)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openSettingsWindowAction() {
        // THIS LINE OPENS THE SYSTEM-MANAGED SETTINGS WINDOW
        // It shows the content of the Settings { ... } block in the @main App.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        // Ensure the app comes to the front (optional but good practice)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        // --- WRONG METHOD ---
        // NEVER DO THIS:
        // let settingsView = SettingsView()
        // showWindow(..., view: settingsView) // THIS WILL CAUSE AN ERROR!
        // OR:
        // let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(self.tunnelManager)))
        // window.makeKeyAndOrderFront(nil) // THIS WILL ALSO CAUSE AN ERROR!
    }

    @objc func openCreateManagedTunnelWindow() {
        let createView = CreateManagedTunnelView()
        showWindow(
            { newWindow in self.createManagedTunnelWindow = newWindow },
            { self.createManagedTunnelWindow },
            title: NSLocalizedString("Create New Managed Tunnel", comment: "Window title: Create new managed tunnel"),
            view: createView
        )
    }

    @objc func openCreateFromMampWindow() {
        let createView = CreateFromMampView()
        showWindow(
            { newWindow in self.createFromMampWindow = newWindow },
            { self.createFromMampWindow },
            title: NSLocalizedString("Create Tunnel from MAMP Site", comment: "Window title: Create tunnel from MAMP site"),
            view: createView
        )
    }

    // MARK: - Alert Helpers
    private func showInfoAlert(title: String, message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .informational; alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert button: OK"));
            alert.runModal()
        }
    }
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = NSLocalizedString("Error", comment: "Alert title: Error"); alert.informativeText = message; alert.alertStyle = .critical; alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert button: OK"));
            alert.runModal()
        }
    }

    // Ask helper for local file deletion
    func askToDeleteLocalFiles(for tunnel: TunnelInfo) {
        guard let configPath = tunnel.configPath else { return }
        let credentialPath = tunnelManager?.findCredentialPath(for: configPath)
        var filesToDelete: [String] = []
        var fileNames: [String] = []

        if FileManager.default.fileExists(atPath: configPath) {
            filesToDelete.append(configPath)
            fileNames.append((configPath as NSString).lastPathComponent)
        }
        if let credPath = credentialPath, credPath != configPath, FileManager.default.fileExists(atPath: credPath) {
            filesToDelete.append(credPath)
            fileNames.append((credPath as NSString).lastPathComponent)
        }
        guard !filesToDelete.isEmpty else { return }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert();
            alert.messageText = NSLocalizedString("Delete Local Files?", comment: "Alert title: Ask to delete local files");
            alert.informativeText = String(format: NSLocalizedString("Tunnel '%@' was deleted from Cloudflare.\nWould you also like to delete the associated local files?\n\n- %@", comment: "Alert informative text: Ask to delete local files. Parameters are tunnel name and list of files."), tunnel.name, fileNames.joined(separator: "\n- "));
            alert.alertStyle = .warning;
            alert.addButton(withTitle: NSLocalizedString("Yes, Delete Local Files", comment: "Alert button: Confirm delete local files"));
            alert.addButton(withTitle: NSLocalizedString("No, Keep Files", comment: "Alert button: Keep local files"))
            if alert.buttons.count > 0 { alert.buttons[0].hasDestructiveAction = true }

            if alert.runModal() == .alertFirstButtonReturn {
                print(String(format: NSLocalizedString("Deleting local files: %@", comment: "Log message: Deleting local files. Parameter is list of files."), filesToDelete.description))
                var errors: [String] = []
                filesToDelete.forEach { path in
                    do { try FileManager.default.removeItem(atPath: path); print(String(format: NSLocalizedString("   Deleted: %@", comment: "Log message: Deleted file. Parameter is path."), path)) }
                    catch { print(String(format: NSLocalizedString("❌ Local file deletion error: %@ - %@", comment: "Log message: Error deleting local file. Parameters are path and error."), path, error.localizedDescription)); errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)") }
                }
                if errors.isEmpty {
                    let successTitle = NSLocalizedString("Local Files Deleted", comment: "Notification title: Local files deleted")
                    let successBody = String(format: NSLocalizedString("Files associated with '%@' were deleted.", comment: "Notification body: Local files deleted for tunnel. Parameter is tunnel name."), tunnel.name)
                    self.sendUserNotification(identifier:"local_deleted_\(tunnel.id)", title: successTitle, body: successBody)
                }
                else {
                    let errorMessage = String(format: NSLocalizedString("Error deleting some local files:\n%@", comment: "Error alert: Failed to delete some local files. Parameter is list of errors."), errors.joined(separator: "\n"))
                    self.showErrorAlert(message: errorMessage)
                }
                self.tunnelManager?.findManagedTunnels() // Refresh list
            } else { print(NSLocalizedString("Local files are being kept.", comment: "Log message: Local files were kept.")) }
        }
    }

    // Ask helper for opening MAMP config
    func askToOpenMampConfigFolder() {
        guard let configPath = tunnelManager?.mampConfigDirectoryPath else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("MAMP Configuration Updated", comment: "Alert title: MAMP configuration updated")
            alert.informativeText = NSLocalizedString("MAMP vHost file has been updated. You may need to restart MAMP servers for the changes to take effect.\n\nWould you like to open the MAMP Apache configuration folder?", comment: "Alert informative text: MAMP vHost updated, ask to open folder.")
            alert.addButton(withTitle: NSLocalizedString("Open Folder", comment: "Alert button: Open folder"))
            alert.addButton(withTitle: NSLocalizedString("No", comment: "Alert button: No"))
            alert.alertStyle = .informational

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
            }
        }
    }

    // --- [NEW] MAMP Command Execution Helper ---
    /// Runs the specified MAMP command-line script.
    /// - Parameters:
    ///   - scriptName: Name of the script to run (e.g., "start.sh").
    ///   - successMessage: Notification message to show on success.
    ///   - failureMessage: Error title to show on failure.
    private func executeMampCommand(scriptName: String, successMessage: String, failureMessage: String) {
        let scriptPath = "\(mampBasePath)/\(scriptName)"

        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            let errorMessage = String(format: NSLocalizedString("Script '%@' not found or not executable.\nPath: %@\nCheck your MAMP installation.", comment: "Error message: MAMP script not found or executable. Parameters are script name and path."), scriptName, scriptPath)
            print(String(format: NSLocalizedString("❌ MAMP Script Error: %@", comment: "Log message: MAMP script error. Parameter is error message."), errorMessage))
            // Ensure error is shown on the main thread
            DispatchQueue.main.async {
                self.showErrorAlert(message: errorMessage)
            }
            return
        }

        // Run off the main thread to prevent UI freezing
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh") // Run script with shell
            process.arguments = [scriptPath]

            // If you want to capture output (can be useful for debugging):
            // let outputPipe = Pipe()
            // let errorPipe = Pipe()
            // process.standardOutput = outputPipe
            // process.standardError = errorPipe

            do {
                print(String(format: NSLocalizedString("🚀 Running MAMP command: %@", comment: "Log message: Running MAMP command. Parameter is script path."), scriptPath))
                try process.run()
                process.waitUntilExit() // Wait for the process to finish

                // Read output (optional)
                // let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                // let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                // let outputString = String(data: outputData, encoding: .utf8) ?? ""
                // let errorString = String(data: errorData, encoding: .utf8) ?? ""
                // if !outputString.isEmpty { print("MAMP Output [\(scriptName)]: \(outputString)") }
                // if !errorString.isEmpty { print("MAMP Error [\(scriptName)]: \(errorString)") }


                // Return to main thread to update UI
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        print(String(format: NSLocalizedString("✅ MAMP command completed successfully: %@", comment: "Log message: MAMP command successful. Parameter is script name."), scriptName))
                        self.sendUserNotification(identifier: "mamp_action_\(scriptName)_\(UUID().uuidString)", title: NSLocalizedString("MAMP Action", comment: "Notification title: MAMP action performed"), body: successMessage)
                    } else {
                        let errorDetail = String(format: NSLocalizedString("MAMP script '%@' failed with Exit Code: %d.", comment: "Error detail: MAMP script failed. Parameters are script name and exit code."), scriptName, process.terminationStatus) // \nError Output: \(errorString)"
                        print(String(format: NSLocalizedString("❌ MAMP Script Error: %@", comment: "Log message: MAMP script error. Parameter is error detail."), errorDetail))
                        self.showErrorAlert(message: String(format: NSLocalizedString("%@\nDetail: %@", comment: "Error alert: MAMP command failed. Parameters are general failure message and specific detail."), failureMessage, errorDetail))
                    }
                }
            } catch {
                // Return to main thread to update UI
                DispatchQueue.main.async {
                    let errorDetail = String(format: NSLocalizedString("Error running MAMP script '%@': %@", comment: "Error detail: Failed to run MAMP script. Parameters are script name and error description."), scriptName, error.localizedDescription)
                    print(String(format: NSLocalizedString("❌ MAMP Script Error: %@", comment: "Log message: MAMP script error. Parameter is error detail."), errorDetail))
                    self.showErrorAlert(message: String(format: NSLocalizedString("%@\nDetail: %@", comment: "Error alert: MAMP command failed. Parameters are general failure message and specific detail."), failureMessage, errorDetail))
                }
            }
        }
    }
    // --- [END NEW] ---

    // End AppDelegate
}





