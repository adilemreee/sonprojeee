import Foundation
import ServiceManagement
import Combine // ObservableObject, @Published, AnyCancellable
import System // For errno, O_EVTONLY
import AppKit // For FileManager checks related to paths/executables

// Notification Name for when the manager requests a notification to be sent
extension Notification.Name {
    static let sendUserNotification = Notification.Name("com.cloudflaredmanager.sendUserNotification")
}


class TunnelManager: ObservableObject {

    @Published var tunnels: [TunnelInfo] = [] // Managed tunnels (config based)
    @Published var quickTunnels: [QuickTunnelData] = [] // Quick tunnels (URL based)

    // Maps configPath -> Process object for active tunnels managed by this app VIA CONFIG FILE
    private var runningManagedProcesses: [String: Process] = [:]
    // Maps QuickTunnelData.id -> Process object for quick tunnels
    private var runningQuickProcesses: [UUID: Process] = [:]

    // Store Combine cancellables
    var cancellables = Set<AnyCancellable>()

    // --- CONFIGURATION (UserDefaults) ---
    @Published var cloudflaredExecutablePath: String = UserDefaults.standard.string(forKey: "cloudflaredPath") ?? "/opt/homebrew/bin/cloudflared" {
        didSet {
            UserDefaults.standard.set(cloudflaredExecutablePath, forKey: "cloudflaredPath")
            print(String(format: NSLocalizedString("New cloudflared path set: %@", comment: "Log message: New cloudflared path set. Parameter is the path."), cloudflaredExecutablePath))
            checkCloudflaredExecutable() // Validate the new path
        }
    }
    @Published var checkInterval: TimeInterval = UserDefaults.standard.double(forKey: "checkInterval") > 0 ? UserDefaults.standard.double(forKey: "checkInterval") : 30.0 {
         didSet {
             if checkInterval < 5 { checkInterval = 5 } // Minimum interval 5s
             UserDefaults.standard.set(checkInterval, forKey: "checkInterval")
             setupStatusCheckTimer() // Restart timer with new interval
             print(String(format: NSLocalizedString("New check interval set: %.1f seconds", comment: "Log message: New check interval set. Parameter is interval in seconds."), checkInterval))
         }
     }

    let cloudflaredDirectoryPath: String
    let mampConfigDirectoryPath: String // MAMP Apache config file DIRECTORY
    let mampSitesDirectoryPath: String // MAMP Sites (or htdocs) DIRECTORY
    let mampVHostConfPath: String      // Full path to MAMP vHost file
    let mampHttpdConfPath: String
    // MAMP Apache default port
    let defaultMampPort = 8888

    // ---------------------

    
    private var statusCheckTimer: Timer?
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var monitorDebounceTimer: Timer?

    // Replaced direct callback with NotificationCenter
    // var sendNotificationCallback: ((String, String, String?) -> Void)?


    init() {
        cloudflaredDirectoryPath = ("~/.cloudflared" as NSString).expandingTildeInPath
        // MAMP Paths (Adjust if MAMP is installed elsewhere or different version)
        mampConfigDirectoryPath = "/Applications/MAMP/conf/apache"
        mampSitesDirectoryPath = "/Applications/MAMP/sites" // Default MAMP htdocs
        mampVHostConfPath = "/Applications/MAMP/conf/apache/extra/httpd-vhosts.conf"
        mampHttpdConfPath = "/Applications/MAMP/conf/apache/httpd.conf" // <<< Assign NEW CONSTANT >>>
        print(String(format: NSLocalizedString("Cloudflared directory path: %@", comment: "Log message: Cloudflared directory path. Parameter is path."), cloudflaredDirectoryPath))
        print(String(format: NSLocalizedString("Mamp Config directory path: %@", comment: "Log message: MAMP config directory path. Parameter is path."), mampConfigDirectoryPath))
        print(String(format: NSLocalizedString("Mamp Sites directory path: %@", comment: "Log message: MAMP sites directory path. Parameter is path."), mampSitesDirectoryPath))
        print(String(format: NSLocalizedString("Mamp vHost path: %@", comment: "Log message: MAMP vHost file path. Parameter is path."), mampVHostConfPath))
        print(String(format: NSLocalizedString("Mamp httpd.conf path: %@", comment: "Log message: MAMP httpd.conf file path. Parameter is path."), mampHttpdConfPath)) // <<< ADD LOG (optional) >>>
        // Initial check for cloudflared executable
        checkCloudflaredExecutable()

        // Start timer for periodic status checks (Managed tunnels only)
        setupStatusCheckTimer()

        // Perform initial scan for tunnels with config files
        findManagedTunnels()

        // Start monitoring the config directory
        startMonitoringCloudflaredDirectory()
    }

    deinit {
        statusCheckTimer?.invalidate()
        stopMonitoringCloudflaredDirectory()
    }

    // Helper to send notification via NotificationCenter
    internal func postUserNotification(identifier: String, title: String, body: String?) {
        let userInfo: [String: Any] = [
            "identifier": identifier,
            "title": title,
            "body": body ?? ""
        ]
        // Post notification for AppDelegate to handle
        NotificationCenter.default.post(name: .sendUserNotification, object: self, userInfo: userInfo)
    }

    func checkCloudflaredExecutable() {
         if !FileManager.default.fileExists(atPath: cloudflaredExecutablePath) {
             print(String(format: NSLocalizedString("⚠️ WARNING: cloudflared not found at: %@", comment: "Log message: cloudflared executable not found warning. Parameter is path."), cloudflaredExecutablePath))
             let errorTitle = NSLocalizedString("Cloudflared Not Found", comment: "Notification title: cloudflared executable not found")
             let errorBody = String(format: NSLocalizedString("Not found at '%@'. Please correct the path in Settings.", comment: "Notification body: cloudflared not found at path, instruct to fix in settings. Parameter is path."), cloudflaredExecutablePath)
             postUserNotification(identifier:"cloudflared_not_found", title: errorTitle, body: errorBody)
         }
     }

    // MARK: - Timer Setup
    func setupStatusCheckTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
             self?.checkAllManagedTunnelStatuses()
        }
        RunLoop.current.add(statusCheckTimer!, forMode: .common)
        print(String(format: NSLocalizedString("Managed tunnel status check timer set up with %.1f second interval.", comment: "Log message: Status check timer setup. Parameter is interval in seconds."), checkInterval))
    }

    // MARK: - Tunnel Discovery (Managed Tunnels from Config Files)
    func findManagedTunnels() {
        print(String(format: NSLocalizedString("Searching for managed tunnels (config files): %@", comment: "Log message: Searching for managed tunnels. Parameter is directory path."), cloudflaredDirectoryPath))
        var discoveredTunnelsDict: [String: TunnelInfo] = [:]
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: cloudflaredDirectoryPath, isDirectory: &isDirectory) {
            print(String(format: NSLocalizedString("ℹ️ Directory %@ not found, creating...", comment: "Log message: Directory not found, creating it. Parameter is path."), cloudflaredDirectoryPath))
            do {
                try fileManager.createDirectory(atPath: cloudflaredDirectoryPath, withIntermediateDirectories: true, attributes: nil)
                print(NSLocalizedString("   ✅ Directory created.", comment: "Log message: Directory created successfully."))
                isDirectory = true // Set local variable after successful creation
            } catch {
                print(String(format: NSLocalizedString("❌ Error: Could not create directory %@: %@", comment: "Log message: Error creating directory. Parameters are path and error."), cloudflaredDirectoryPath, error.localizedDescription))
                DispatchQueue.main.async { self.tunnels.removeAll { $0.isManaged } }
                let errorTitle = NSLocalizedString("Cloudflared Directory Error", comment: "Notification title: Error with cloudflared directory")
                let errorBody = String(format: NSLocalizedString("Could not create or access '%@'.", comment: "Notification body: Failed to create/access cloudflared directory. Parameter is path."), cloudflaredDirectoryPath)
                postUserNotification(identifier:"cf_dir_create_error", title: errorTitle, body: errorBody)
                return
            }
        } else if !isDirectory.boolValue {
             print(String(format: NSLocalizedString("❌ Error: %@ is not a directory.", comment: "Log message: Path is not a directory. Parameter is path."), cloudflaredDirectoryPath))
             DispatchQueue.main.async { self.tunnels.removeAll { $0.isManaged } }
             let errorTitle = NSLocalizedString("Cloudflared Path Error", comment: "Notification title: Error with cloudflared path")
             let errorBody = String(format: NSLocalizedString("'%@' is not a directory.", comment: "Notification body: Path is not a directory. Parameter is path."), cloudflaredDirectoryPath)
             postUserNotification(identifier:"cf_dir_not_dir", title: errorTitle, body: errorBody)
             return
        }

        do {
            let items = try fileManager.contentsOfDirectory(atPath: cloudflaredDirectoryPath)
            for item in items {
                if item.lowercased().hasSuffix(".yml") || item.lowercased().hasSuffix(".yaml") {
                    let configPath = "\(cloudflaredDirectoryPath)/\(item)"
                    let tunnelName = (item as NSString).deletingPathExtension
                    let tunnelUUID = parseValueFromYaml(key: "tunnel", filePath: configPath)

                    if let existingProcess = runningManagedProcesses[configPath], existingProcess.isRunning {
                         discoveredTunnelsDict[configPath] = TunnelInfo(name: tunnelName, configPath: configPath, status: .running, processIdentifier: existingProcess.processIdentifier, uuidFromConfig: tunnelUUID)
                    } else {
                        discoveredTunnelsDict[configPath] = TunnelInfo(name: tunnelName, configPath: configPath, uuidFromConfig: tunnelUUID)
                    }
                }
            }
        } catch {
            print(String(format: NSLocalizedString("❌ Error: Error reading directory %@: %@", comment: "Log message: Error reading directory. Parameters are path and error."), cloudflaredDirectoryPath, error.localizedDescription))
            let errorTitle = NSLocalizedString("Directory Read Error", comment: "Notification title: Error reading directory")
            let errorBody = String(format: NSLocalizedString("Error reading '%@'.", comment: "Notification body: Error reading directory. Parameter is path."), cloudflaredDirectoryPath)
            postUserNotification(identifier:"cf_dir_read_error", title: errorTitle, body: errorBody)
            // Don't clear tunnels here, could be temporary.
        }

        // Merge discovered tunnels with the current list on the main thread
        DispatchQueue.main.async {
             let existingManagedTunnels = self.tunnels.filter { $0.isManaged }
             let existingManagedTunnelsDict = Dictionary(uniqueKeysWithValues: existingManagedTunnels.compactMap { $0.configPath != nil ? ($0.configPath!, $0) : nil })
             var updatedManagedTunnels: [TunnelInfo] = []

             for (configPath, discoveredTunnel) in discoveredTunnelsDict {
                 if var existingTunnel = existingManagedTunnelsDict[configPath] {
                     if ![.starting, .stopping, .error].contains(existingTunnel.status) {
                         existingTunnel.status = discoveredTunnel.status
                         existingTunnel.processIdentifier = discoveredTunnel.processIdentifier
                     }
                     existingTunnel.uuidFromConfig = discoveredTunnel.uuidFromConfig
                     updatedManagedTunnels.append(existingTunnel)
                 } else {
                     print(String(format: NSLocalizedString("New managed tunnel found: %@", comment: "Log message: New managed tunnel discovered. Parameter is tunnel name."), discoveredTunnel.name))
                     updatedManagedTunnels.append(discoveredTunnel)
                 }
             }

             let existingConfigFiles = Set(discoveredTunnelsDict.keys)
             let removedTunnels = existingManagedTunnels.filter {
                 guard let configPath = $0.configPath else { return false }
                 return !existingConfigFiles.contains(configPath)
             }

             if !removedTunnels.isEmpty {
                 print(String(format: NSLocalizedString("Removed config files: %@", comment: "Log message: Config files removed. Parameter is list of names."), removedTunnels.map { $0.name }.joined(separator: ", ")))
                 for removedTunnel in removedTunnels {
                      if let configPath = removedTunnel.configPath, self.runningManagedProcesses[configPath] != nil {
                           print(String(format: NSLocalizedString("   Auto-stopping: %@", comment: "Log message: Auto-stopping tunnel. Parameter is tunnel name."), removedTunnel.name))
                           self.stopManagedTunnel(removedTunnel, synchronous: true) // Stop synchronously on file removal
                      }
                 }
             }

             self.tunnels = updatedManagedTunnels.sorted { $0.name.lowercased() < $1.name.lowercased() }
             print(String(format: NSLocalizedString("Updated managed tunnel list: %@", comment: "Log message: Updated list of managed tunnels. Parameter is list of names."), self.tunnels.map { $0.name }.joined(separator: ", ")))
             self.checkAllManagedTunnelStatuses(forceCheck: true)
         }
    }

    // MARK: - Tunnel Control (Start/Stop/Toggle - Managed Only)
    func toggleManagedTunnel(_ tunnel: TunnelInfo) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else {
            print(String(format: NSLocalizedString("❌ Error: Only managed tunnels with a config file can be toggled: %@", comment: "Log message: Error toggling tunnel without config. Parameter is tunnel name."), tunnel.name))
            return
        }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
             print(String(format: NSLocalizedString("❌ Error: Tunnel not found: %@", comment: "Log message: Error, tunnel not found for toggle. Parameter is tunnel name."), tunnel.name))
             return
        }
        let currentStatus = tunnels[index].status
        print(String(format: NSLocalizedString("Toggling managed tunnel: %@, Current status: %@", comment: "Log message: Toggling managed tunnel. Parameters are tunnel name and current status."), tunnel.name, currentStatus.displayName))
        switch currentStatus {
        case .running, .starting: stopManagedTunnel(tunnels[index])
        case .stopped, .error: startManagedTunnel(tunnels[index])
        case .stopping: print(String(format: NSLocalizedString("%@ is already stopping.", comment: "Log message: Tunnel is already in the process of stopping. Parameter is tunnel name."), tunnel.name))
        }
    }

    func startManagedTunnel(_ tunnel: TunnelInfo) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else { return }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }

        guard runningManagedProcesses[configPath] == nil, tunnels[index].status != .running, tunnels[index].status != .starting else {
             print(String(format: NSLocalizedString("ℹ️ %@ is already running or starting.", comment: "Log message: Tunnel already running/starting. Parameter is tunnel name."), tunnel.name))
             return
        }
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
             DispatchQueue.main.async {
                 if self.tunnels.indices.contains(index) {
                     self.tunnels[index].status = .error
                     self.tunnels[index].lastError = String(format: NSLocalizedString("cloudflared executable not found: %@", comment: "Error message: cloudflared executable not found. Parameter is path."), self.cloudflaredExecutablePath)
                 }
             }
            let errorTitle = String(format: NSLocalizedString("Start Error: %@", comment: "Notification title: Error starting tunnel. Parameter is tunnel name."), tunnel.name)
            let errorBody = NSLocalizedString("cloudflared executable not found.", comment: "Notification body: cloudflared executable not found for starting tunnel.")
            postUserNotification(identifier:"start_fail_noexec_\(tunnel.id)", title: errorTitle, body: errorBody)
            return
        }

        print(String(format: NSLocalizedString("▶️ Starting managed tunnel %@...", comment: "Log message: Starting managed tunnel. Parameter is tunnel name."), tunnel.name))
        DispatchQueue.main.async {
            if self.tunnels.indices.contains(index) {
                self.tunnels[index].status = .starting
                self.tunnels[index].lastError = nil
                self.tunnels[index].processIdentifier = nil
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        let tunnelIdentifier = tunnel.uuidFromConfig ?? tunnel.name
        process.arguments = ["tunnel", "--config", configPath, "run", tunnelIdentifier]

        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe
        var stdOutputData = Data()
        var stdErrorData = Data()
        let outputQueue = DispatchQueue(label: "com.cloudflaredmanager.stdout-\(tunnel.id)")
        let errorQueue = DispatchQueue(label: "com.cloudflaredmanager.stderr-\(tunnel.id)")

        outputPipe.fileHandleForReading.readabilityHandler = { pipe in
            let data = pipe.availableData
            if data.isEmpty { pipe.readabilityHandler = nil } else { outputQueue.async { stdOutputData.append(data) } }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { pipe in
            let data = pipe.availableData
            if data.isEmpty { pipe.readabilityHandler = nil } else { errorQueue.async { stdErrorData.append(data) } }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
             outputPipe.fileHandleForReading.readabilityHandler = nil // Nil handlers on termination
             errorPipe.fileHandleForReading.readabilityHandler = nil

             let finalOutputString = outputQueue.sync { String(data: stdOutputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
             let finalErrorString = errorQueue.sync { String(data: stdErrorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

             DispatchQueue.main.async {
                 guard let self = self else { return }
                 guard let idx = self.tunnels.firstIndex(where: { $0.configPath == configPath }) else {
                     print(String(format: NSLocalizedString("Termination handler: Tunnel not found in list anymore: %@", comment: "Log message: Tunnel not found in list during termination. Parameter is config path."), configPath))
                     self.runningManagedProcesses.removeValue(forKey: configPath); return
                 }

                 let status = terminatedProcess.terminationStatus
                 let reason = terminatedProcess.terminationReason
                 print(String(format: NSLocalizedString("⏹️ Managed tunnel %@ finished. Code: %d, Reason: %@", comment: "Log message: Managed tunnel finished. Parameters are tunnel name, exit code, exit reason."), self.tunnels[idx].name, status, (reason == .exit ? "Exit" : "Signal")))
                 // if !finalOutputString.isEmpty { /* print("   Output: \(finalOutputString)") */ } // Usually logs only
                 if !finalErrorString.isEmpty { print(String(format: NSLocalizedString("   Error: %@", comment: "Log message: Error output from finished process. Parameter is error string."), finalErrorString)) }

                 let wasStopping = self.tunnels[idx].status == .stopping
                 let wasStoppedIntentionally = self.runningManagedProcesses[configPath] == nil // If not in map, assume intentional stop

                 if self.runningManagedProcesses[configPath] != nil {
                     print(String(format: NSLocalizedString("   Termination handler removing %@ from running map (unexpected termination).", comment: "Log message: Removing tunnel from running map due to unexpected termination. Parameter is tunnel name."), self.tunnels[idx].name))
                     self.runningManagedProcesses.removeValue(forKey: configPath)
                 }

                 if self.tunnels.indices.contains(idx) {
                     self.tunnels[idx].processIdentifier = nil

                     if wasStoppedIntentionally {
                         self.tunnels[idx].status = .stopped
                         self.tunnels[idx].lastError = nil
                         if !wasStopping { // Notify only if stop wasn't already in progress UI-wise
                             print(NSLocalizedString("   Tunnel stopped (termination handler).", comment: "Log message: Tunnel stopped via termination handler."))
                            let notificationTitle = NSLocalizedString("Tunnel Stopped", comment: "Notification title: Tunnel has been stopped")
                            let notificationBody = String(format: NSLocalizedString("'%@' was successfully stopped.", comment: "Notification body: Tunnel successfully stopped. Parameter is tunnel name."), self.tunnels[idx].name)
                            self.postUserNotification(identifier:"stopped_\(self.tunnels[idx].id)", title: notificationTitle, body: notificationBody)
                         }
                     } else { // Unintentional termination
                         self.tunnels[idx].status = .error
                         let errorMessage = finalErrorString.isEmpty ? String(format: NSLocalizedString("Process terminated unexpectedly (Code: %d).", comment: "Error message: Process terminated unexpectedly. Parameter is exit code."), status) : finalErrorString
                         self.tunnels[idx].lastError = errorMessage.split(separator: "\n").prefix(3).joined(separator: "\n")

                         print(NSLocalizedString("   Error: Tunnel terminated unexpectedly.", comment: "Log message: Tunnel terminated unexpectedly."))
                         let errorTitle = String(format: NSLocalizedString("Tunnel Error: %@", comment: "Notification title: Tunnel error. Parameter is tunnel name."), self.tunnels[idx].name)
                         let errorBody = self.tunnels[idx].lastError ?? NSLocalizedString("Unknown error.", comment: "Default unknown error message.")
                         self.postUserNotification(identifier:"error_\(self.tunnels[idx].id)", title: errorTitle, body: errorBody)
                     }
                 }
            } // End DispatchQueue.main.async
        } // End terminationHandler

        do {
            try process.run()
            runningManagedProcesses[configPath] = process
            let pid = process.processIdentifier
             DispatchQueue.main.async {
                 if let index = self.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                    self.tunnels[index].processIdentifier = pid
                 }
             }
            print(String(format: NSLocalizedString("   Started. PID: %d", comment: "Log message: Tunnel process started. Parameter is PID."), pid))
             DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                 guard let self = self else { return }
                 if let index = self.tunnels.firstIndex(where: { $0.id == tunnel.id }), self.tunnels[index].status == .starting {
                     if let runningProcess = self.runningManagedProcesses[configPath], runningProcess.isRunning {
                         self.tunnels[index].status = .running
                         print(String(format: NSLocalizedString("   Status updated -> Running (%@)", comment: "Log message: Tunnel status updated to running. Parameter is tunnel name."), self.tunnels[index].name))
                         let notificationTitle = NSLocalizedString("Tunnel Started", comment: "Notification title: Tunnel has been started")
                         let notificationBody = String(format: NSLocalizedString("'%@' was successfully started.", comment: "Notification body: Tunnel successfully started. Parameter is tunnel name."), tunnel.name)
                         self.postUserNotification(identifier:"started_\(tunnel.id)", title: notificationTitle, body: notificationBody)
                     } else {
                         print(String(format: NSLocalizedString("   Tunnel terminated during startup (%@). Status -> Error.", comment: "Log message: Tunnel terminated during startup. Parameter is tunnel name."), self.tunnels[index].name))
                         self.tunnels[index].status = .error
                         if self.tunnels[index].lastError == nil {
                             self.tunnels[index].lastError = NSLocalizedString("Process terminated during startup.", comment: "Error message: Process terminated during startup.")
                         }
                         self.runningManagedProcesses.removeValue(forKey: configPath) // Ensure removed
                     }
                 }
             }
        } catch {
             DispatchQueue.main.async {
                 if let index = self.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                    self.tunnels[index].status = .error;
                    self.tunnels[index].processIdentifier = nil
                    self.tunnels[index].lastError = String(format: NSLocalizedString("Failed to start process: %@", comment: "Error message: Failed to start process. Parameter is error description."), error.localizedDescription)
                 }
                 outputPipe.fileHandleForReading.readabilityHandler = nil // Cleanup handlers on failure
                 errorPipe.fileHandleForReading.readabilityHandler = nil
             }
            runningManagedProcesses.removeValue(forKey: configPath) // Remove if run fails
            let errorTitle = String(format: NSLocalizedString("Start Error: %@", comment: "Notification title: Error starting tunnel. Parameter is tunnel name."), tunnel.name)
            let errorBody = String(format: NSLocalizedString("Failed to start process: %@", comment: "Notification body: Failed to start tunnel process. Parameter is error description."), error.localizedDescription)
            postUserNotification(identifier:"start_fail_run_\(tunnel.id)", title: errorTitle, body: errorBody)
        }
    }

    // Helper function for synchronous stop with timeout
    private func stopProcessAndWait(_ process: Process, timeout: TimeInterval) -> Bool {
        process.terminate() // Send SIGTERM
        let deadline = DispatchTime.now() + timeout
        while process.isRunning && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Cannot send SIGKILL easily with Foundation's Process. Rely on SIGTERM.
        return !process.isRunning
    }

    func stopManagedTunnel(_ tunnel: TunnelInfo, synchronous: Bool = false) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else { return }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }

        guard let process = runningManagedProcesses[configPath] else {
             DispatchQueue.main.async {
                 if self.tunnels.indices.contains(index) && [.running, .stopping, .starting].contains(self.tunnels[index].status) {
                     print(String(format: NSLocalizedString("⚠️ Stopping: %@ process not in map, correcting status -> Stopped", comment: "Log message: Correcting status for tunnel process not in map. Parameter is tunnel name."), tunnel.name))
                     self.tunnels[index].status = .stopped
                     self.tunnels[index].processIdentifier = nil
                     self.tunnels[index].lastError = nil
                 }
             }
            return
        }

        if tunnels[index].status == .stopping {
            print(String(format: NSLocalizedString("ℹ️ %@ is already stopping.", comment: "Log message: Tunnel is already in the process of stopping. Parameter is tunnel name."), tunnel.name))
            return
        }

        print(String(format: NSLocalizedString("🛑 Stopping managed tunnel %@...", comment: "Log message: Stopping managed tunnel. Parameter is tunnel name."), tunnel.name))
        DispatchQueue.main.async {
            if self.tunnels.indices.contains(index) {
                self.tunnels[index].status = .stopping
                self.tunnels[index].lastError = nil
            }
        }

        // Remove from map *before* terminating to signal intent
        runningManagedProcesses.removeValue(forKey: configPath)

        if synchronous {
            let timeoutInterval: TimeInterval = 2.5 // Slightly adjusted timeout
            let didExit = stopProcessAndWait(process, timeout: timeoutInterval)

            // Update status immediately after waiting *if* it exited
             DispatchQueue.main.async {
                 if let idx = self.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                      if self.tunnels[idx].status == .stopping { // Check if still marked as stopping
                           self.tunnels[idx].status = .stopped
                           self.tunnels[idx].processIdentifier = nil
                           if didExit {
                               print(String(format: NSLocalizedString("   %@ stopped synchronously (with SIGTERM). Status -> Stopped.", comment: "Log message: Tunnel stopped synchronously. Parameter is tunnel name."), tunnel.name))
                           } else {
                               print(String(format: NSLocalizedString("   ⚠️ %@ could not be stopped synchronously (%.1fs timeout). Status -> Stopped (waiting for termination handler).", comment: "Log message: Tunnel synchronous stop timed out. Parameters are tunnel name and timeout duration."), tunnel.name, timeoutInterval))
                               // Termination handler should eventually fire and confirm.
                           }
                           // Termination handler will still fire, potentially sending a notification, but we update UI state here for sync case.
                      }
                 }
             }
        } else {
             process.terminate() // Sends SIGTERM asynchronously
             print(NSLocalizedString("   Stop signal sent (asynchronously).", comment: "Log message: Asynchronous stop signal sent."))
             // Termination handler will update status and potentially send notification.
        }
    }

    // MARK: - Tunnel Creation & Config
    func createTunnel(name: String, completion: @escaping (Result<(uuid: String, jsonPath: String), Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("cloudflared executable not found at: %@", comment: "Error message in createTunnel: cloudflared not found. Parameter is path."), cloudflaredExecutablePath)])))
            return
        }
        if name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || name.isEmpty {
             completion(.failure(NSError(domain: "InputError", code: 11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Tunnel name cannot contain spaces and cannot be empty.", comment: "Error message: Invalid tunnel name.")])))
             return
         }

        print(String(format: NSLocalizedString("🏗️ Creating new tunnel: %@...", comment: "Log message: Creating new tunnel. Parameter is tunnel name."), name))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        process.arguments = ["tunnel", "create", name]

        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe

        process.terminationHandler = { [weak self] terminatedProcess in
            guard self != nil else { return } // Weak self check removed, not needed in closure
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = terminatedProcess.terminationStatus
            print(String(format: NSLocalizedString("   'tunnel create %@' finished. Status: %d", comment: "Log message: 'tunnel create' command finished. Parameters are tunnel name and status code."), name, status))
            if !outputString.isEmpty { print(String(format: NSLocalizedString("   Output:\n%@", comment: "Log message: Output from command. Parameter is output string."), outputString)) }
            if !errorString.isEmpty { print(String(format: NSLocalizedString("   Error:\n%@", comment: "Log message: Error output from command. Parameter is error string."), errorString)) }

            if status == 0 {
                var tunnelUUID: String?; var jsonPath: String?
                let uuidPattern = "([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})"
                let jsonPathPattern = "(/[^ ]+\\.json)" // Path starting with / ending in .json

                if let uuidRange = outputString.range(of: uuidPattern, options: [.regularExpression, .caseInsensitive]) {
                    tunnelUUID = String(outputString[uuidRange])
                }

                // Find JSON path after the line confirming creation
                 if let range = outputString.range(of: #"Created tunnel .+ with id \S+"#, options: .regularExpression) {
                     let remainingOutput = outputString[range.upperBound...]
                     if let pathRange = remainingOutput.range(of: jsonPathPattern, options: .regularExpression) {
                         jsonPath = String(remainingOutput[pathRange])
                     }
                 }
                 if jsonPath == nil, let pathRange = outputString.range(of: jsonPathPattern, options: .regularExpression) {
                      jsonPath = String(outputString[pathRange]) // Fallback search anywhere
                 }

                if let uuid = tunnelUUID, let path = jsonPath {
                    // Use the path directly as given by cloudflared (it should be absolute)
                    let absolutePath = (path as NSString).standardizingPath // Clean path
                    if FileManager.default.fileExists(atPath: absolutePath) {
                        print(String(format: NSLocalizedString("   ✅ Tunnel created: %@ (UUID: %@, JSON: %@)", comment: "Log message: Tunnel created successfully. Parameters are name, UUID, JSON path."), name, uuid, absolutePath))
                        completion(.success((uuid: uuid, jsonPath: absolutePath)))
                    } else {
                         print(String(format: NSLocalizedString("   ❌ Tunnel created but JSON file not found: %@ (Original Output Path: %@)", comment: "Log message: Tunnel created but JSON file not found. Parameters are absolute path and original path from output."), absolutePath, path))
                         completion(.failure(NSError(domain: "CloudflaredManagerError", code: 2, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Tunnel created but JSON credential file not found at:\n%@\n\nCheck cloudflared output:\n%@", comment: "Error message: Tunnel created but JSON file not found, with output. Parameters are path and cloudflared output."), absolutePath, outputString)])))
                    }
                 } else {
                     completion(.failure(NSError(domain: "CloudflaredManagerError", code: 2, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Tunnel created but UUID (%@) or JSON path (%@) not found in output:\n%@", comment: "Error message: Tunnel created but UUID or JSON path missing from output. Parameters are UUID (or 'none'), JSON path (or 'none'), and output string."), tunnelUUID ?? "none", jsonPath ?? "none", outputString)])))
                 }
            } else {
                let errorMsg = errorString.isEmpty ? String(format: NSLocalizedString("Unknown error creating tunnel (Code: %d). Are you logged into your Cloudflare account?", comment: "Error message: Unknown error creating tunnel. Parameter is exit code."), status) : errorString
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }

    // createConfigFile fonksiyonunu bulun ve içini aşağıdaki gibi düzenleyin:
    func createConfigFile(configName: String, tunnelUUID: String, credentialsPath: String, hostname: String, port: String, documentRoot: String?, completion: @escaping (Result<String, Error>) -> Void) {
         print(String(format: NSLocalizedString("📄 Creating configuration file: %@.yml", comment: "Log message: Creating config file. Parameter is config name."), configName))
            let fileManager = FileManager.default

            // Ensure ~/.cloudflared directory exists
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: cloudflaredDirectoryPath, isDirectory: &isDir) || !isDir.boolValue {
                 do {
                     try fileManager.createDirectory(atPath: cloudflaredDirectoryPath, withIntermediateDirectories: true, attributes: nil)
                 } catch {
                     completion(.failure(NSError(domain: "FileSystemError", code: 4, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Could not create ~/.cloudflared directory: %@", comment: "Error message: Failed to create .cloudflared directory. Parameter is error description."), error.localizedDescription)]))); return
                 }
             }

             var cleanConfigName = configName.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
             cleanConfigName = cleanConfigName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
             if cleanConfigName.isEmpty {
                  completion(.failure(NSError(domain: "InputError", code: 12, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid config file name.", comment: "Error message: Invalid config file name.")]))); return
             }
             let targetPath = "\(cloudflaredDirectoryPath)/\(cleanConfigName).yml"
             if fileManager.fileExists(atPath: targetPath) {
                 completion(.failure(NSError(domain: "CloudflaredManagerError", code: 3, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Configuration file already exists: %@", comment: "Error message: Config file already exists. Parameter is path."), targetPath)]))); return
             }

             // Use the absolute path for credentials-file as provided by `tunnel create`
             let absoluteCredentialsPath = (credentialsPath as NSString).standardizingPath

             let yamlContent = """
             # Tunnel Configuration managed by Cloudflared Manager App
             # Tunnel UUID: \(tunnelUUID)
             # Config File: \(targetPath)

             tunnel: \(tunnelUUID)
             credentials-file: \(absoluteCredentialsPath) # Use absolute path

             ingress:
               - hostname: \(hostname)
                 service: http://localhost:\(port)
               # Catch-all rule MUST be last
               - service: http_status:404
             """

        do {
            try yamlContent.write(toFile: targetPath, atomically: true, encoding: .utf8)
            print(String(format: NSLocalizedString("   ✅ Configuration file created: %@", comment: "Log message: Config file created successfully. Parameter is path."), targetPath))

            // --- MAMP Updates (Concurrent with DispatchGroup) ---
            var vhostUpdateError: Error? = nil
            var listenUpdateError: Error? = nil
            let mampUpdateGroup = DispatchGroup() // For concurrency

            // Only perform MAMP updates if documentRoot is provided
            if let docRoot = documentRoot, !docRoot.isEmpty {
                // 1. vHost Update
                mampUpdateGroup.enter()
                updateMampVHost(serverName: hostname, documentRoot: docRoot, port: port) { result in
                    if case .failure(let error) = result {
                        vhostUpdateError = error // Store error
                        print(String(format: NSLocalizedString("⚠️ MAMP vHost update error: %@", comment: "Log message: MAMP vHost update error. Parameter is error description."), error.localizedDescription))
                        // (Notification is already sent within updateMampVHost)
                    } else {
                        print(NSLocalizedString("✅ MAMP vHost file updated successfully (or already existed).", comment: "Log message: MAMP vHost updated successfully."))
                    }
                    mampUpdateGroup.leave()
                }

                // 2. httpd.conf Listen Update
                mampUpdateGroup.enter()
                updateMampHttpdConfListen(port: port) { result in
                    if case .failure(let error) = result {
                        listenUpdateError = error // Store error
                        print(String(format: NSLocalizedString("⚠️ MAMP httpd.conf Listen update error: %@", comment: "Log message: MAMP httpd.conf Listen update error. Parameter is error description."), error.localizedDescription))
                        // (Notification sent in updateMampHttpdConfListen, but can resend here)
                        let errorTitle = NSLocalizedString("MAMP httpd.conf Error", comment: "Notification title: MAMP httpd.conf error")
                        let errorBody = String(format: NSLocalizedString("'Listen %@' could not be added. Check permissions or add manually.\n%@", comment: "Notification body: Failed to add Listen directive to httpd.conf. Parameters are port and error."), port, error.localizedDescription)
                        self.postUserNotification(identifier: "mamp_httpd_update_fail_\(port)", title: errorTitle, body: errorBody)
                    } else {
                        print(NSLocalizedString("✅ MAMP httpd.conf Listen directive updated successfully (or already existed).", comment: "Log message: MAMP httpd.conf Listen updated successfully."))
                    }
                    mampUpdateGroup.leave()
                }
            } else {
                 print(NSLocalizedString("ℹ️ DocumentRoot not specified or empty, MAMP configuration files not updated.", comment: "Log message: DocumentRoot not provided, MAMP files not updated."))
            }

            // Wait for MAMP updates to finish and report result
            mampUpdateGroup.notify(queue: .main) { [weak self] in
                 guard let self = self else { return }
                 self.findManagedTunnels() // Refresh list

                 // Report overall result
                 if vhostUpdateError == nil && listenUpdateError == nil {
                      // Both MAMP updates successful (or not needed)
                      let successTitle = NSLocalizedString("Config Created", comment: "Notification title: Config file created")
                      var successBody = String(format: NSLocalizedString("'%@.yml' file created.", comment: "Notification body: Config file created. Parameter is config name."), cleanConfigName)
                      if documentRoot != nil { successBody += NSLocalizedString(" MAMP configuration updated.", comment: "Notification body suffix: MAMP config updated.") }
                      self.postUserNotification(identifier: "config_created_\(cleanConfigName)", title: successTitle, body: successBody)
                      completion(.success(targetPath))
                 } else {
                      // Config successful but MAMP updates had errors
                      let combinedErrorDesc = [
                          vhostUpdateError != nil ? "vHost: \(vhostUpdateError!.localizedDescription)" : nil,
                          listenUpdateError != nil ? "httpd.conf: \(listenUpdateError!.localizedDescription)" : nil
                      ].compactMap { $0 }.joined(separator: "\n")

                      print(NSLocalizedString("❌ Config created, but MAMP update(s) failed.", comment: "Log message: Config created, but MAMP updates failed."))
                      // Notify user that config is successful but warn about MAMP
                      let warningTitle = NSLocalizedString("Config Created (MAMP Warning)", comment: "Notification title: Config created with MAMP warning")
                      let warningBody = String(format: NSLocalizedString("'%1$@.yml' created, but error(s) occurred while updating MAMP configuration:\n%2$@\nPlease check MAMP settings manually.", comment: "Notification body: Config created, but MAMP update errors. Parameters are config name and combined error description."), cleanConfigName, combinedErrorDesc)
                      self.postUserNotification(identifier: "config_created_mamp_warn_\(cleanConfigName)", title: warningTitle, body: warningBody)
                      // Can still return success, as tunnel and config are done.
                      completion(.success(targetPath))
                      // OR if you want to return an error:
                      // let error = NSError(domain: "PartialSuccessError", code: 99, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Config file created, but MAMP update(s) failed:\n%@", comment: "Error message for partial success with MAMP errors. Parameter is combined error description."), combinedErrorDesc)])
                      // completion(.failure(error))
                 }
            }
        } catch {
            // If .yml file couldn't be written
            print(String(format: NSLocalizedString("❌ Error: Could not write configuration file: %@ - %@", comment: "Log message: Error writing config file. Parameters are path and error."), targetPath, error.localizedDescription))
            completion(.failure(error))
        }
    } // End of createConfigFile

    // MARK: - Tunnel Deletion (Revised - Removing --force temporarily)
    func deleteTunnel(tunnelInfo: TunnelInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cloudflared executable not found.", comment: "Error message in deleteTunnel: cloudflared not found.")]))); return
        }

        // STRONGLY prefer UUID for deletion
        let identifierToDelete: String
        let idType: String
        if let uuid = tunnelInfo.uuidFromConfig, !uuid.isEmpty {
            identifierToDelete = uuid
            idType = "UUID"
        } else {
            identifierToDelete = tunnelInfo.name // Fallback to name
            idType = "Name"
            print(String(format: NSLocalizedString("   ⚠️ Warning: Could not read tunnel UUID from config, attempting deletion by name ('%@').", comment: "Log message: Warning, deleting tunnel by name as UUID not found. Parameter is tunnel name."), identifierToDelete))
        }

        // !!! TEMPORARILY REMOVING --force flag !!!
        print(String(format: NSLocalizedString("🗑️ Deleting tunnel (Identifier: %@, Type: %@) [--force NOT USED]...", comment: "Log message: Deleting tunnel without --force. Parameters are identifier and type (UUID/Name)."), identifierToDelete, idType))

        // Step 1: Stop the tunnel (Synchronously)
        if let configPath = tunnelInfo.configPath, runningManagedProcesses[configPath] != nil {
            print(String(format: NSLocalizedString("   Stopping tunnel before deletion: %@", comment: "Log message: Stopping tunnel before deletion. Parameter is tunnel name."), tunnelInfo.name))
            stopManagedTunnel(tunnelInfo, synchronous: true)
            Thread.sleep(forTimeInterval: 0.5) // Brief pause
            print(NSLocalizedString("   Continuing after stop attempt...", comment: "Log message: Continuing after tunnel stop attempt."))
        } else {
             print(NSLocalizedString("   Tunnel not running or not managed by this app.", comment: "Log message: Tunnel not running or not managed by app, skipping stop for deletion."))
        }


        // Step 2: Run delete command (WITHOUT --force)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        // process.arguments = ["tunnel", "delete", identifierToDelete, "--force"] // OLD WAY
        process.arguments = ["tunnel", "delete", identifierToDelete] // NEW WAY (no --force)
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe

        process.terminationHandler = { terminatedProcess in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = terminatedProcess.terminationStatus

            print(String(format: NSLocalizedString("   'tunnel delete %@' [--force NOT USED] finished. Exit Code: %d", comment: "Log message: 'tunnel delete' command finished without --force. Parameters are identifier and exit code."), identifierToDelete, status))
            if !outputString.isEmpty { print(String(format: NSLocalizedString("   Output: %@", comment: "Log message: Output from command. Parameter is output string."), outputString)) }
            if !errorString.isEmpty { print(String(format: NSLocalizedString("   Error: %@", comment: "Log message: Error output from command. Parameter is error string."), errorString)) }

            // Evaluate Result
            let lowerError = errorString.lowercased()
            let specificAmbiguityError = NSLocalizedString("there should only be 1 non-deleted tunnel named", comment: "Substring in error message indicating tunnel name ambiguity").lowercased()

            if status == 0 {
                print(String(format: NSLocalizedString("   ✅ Tunnel deleted successfully (Exit Code 0): %@", comment: "Log message: Tunnel deleted successfully. Parameter is identifier."), identifierToDelete))
                completion(.success(()))
            }
            else if lowerError.contains(NSLocalizedString("tunnel not found", comment: "Substring in error message for tunnel not found").lowercased()) || lowerError.contains(NSLocalizedString("could not find tunnel", comment: "Substring in error message for could not find tunnel").lowercased()) {
                print(String(format: NSLocalizedString("   ℹ️ Tunnel already deleted or not found (Error message): %@", comment: "Log message: Tunnel already deleted or not found by error message. Parameter is identifier."), identifierToDelete))
                completion(.success(())) // Treat as success
            }
            // If the same "named" error occurs even without --force, the issue is deeper.
            else if lowerError.contains(specificAmbiguityError) {
                 // This error occurring without --force would be much stranger.
                 print(NSLocalizedString("   ❌ Tunnel deletion error: Name/UUID conflict or other inconsistency on Cloudflare side (did not use --force).", comment: "Log message: Tunnel deletion error due to Cloudflare inconsistency, --force not used."))
                 let errorMsg = String(format: NSLocalizedString("Tunnel could not be deleted due to an inconsistency on Cloudflare's side (did not use --force).\n\nError Message: '%@'\n\nPlease check and manually delete this tunnel via the Cloudflare Dashboard.", comment: "Error message: Tunnel deletion failed due to Cloudflare inconsistency, --force not used. Parameters are error string."), errorString)
                 completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
            // All other errors
            else {
                let errorMsg = errorString.isEmpty ? String(format: NSLocalizedString("Unknown error deleting tunnel (Exit Code: %d).", comment: "Error message: Unknown error deleting tunnel. Parameter is exit code."), status) : errorString
                print(String(format: NSLocalizedString("   ❌ Tunnel deletion error (did not use --force): %@", comment: "Log message: Tunnel deletion error without --force. Parameter is error message."), errorMsg))
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        } // End Termination Handler

        // Start Process
        do {
            try process.run()
        } catch {
            print(String(format: NSLocalizedString("❌ Failed to start 'tunnel delete' process: %@", comment: "Log message: Failed to start 'tunnel delete' process. Parameter is error."), error.localizedDescription))
            completion(.failure(error))
        }
    }


    // MARK: - Config File Parsing
    func parseValueFromYaml(key: String, filePath: String) -> String? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

            let keyWithColon = "\(key):"
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.starts(with: "#") { continue }
                if trimmedLine.starts(with: keyWithColon) {
                    return extractYamlValue(from: trimmedLine.dropFirst(keyWithColon.count))
                }
            }

            // Specifically check for 'hostname' within 'ingress'
            if key == "hostname" {
                var inIngressSection = false; var ingressIndentLevel = -1; var serviceIndentLevel = -1
                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    let currentIndentLevel = line.prefix(while: { $0.isWhitespace }).count
                    if trimmedLine.starts(with: "#") { continue }
                    if trimmedLine == "ingress:" { inIngressSection = true; ingressIndentLevel = currentIndentLevel; serviceIndentLevel = -1; continue }
                    if inIngressSection && currentIndentLevel <= ingressIndentLevel && !trimmedLine.isEmpty { inIngressSection = false; continue }
                    if inIngressSection && trimmedLine.starts(with: "-") { if serviceIndentLevel == -1 { serviceIndentLevel = currentIndentLevel } }
                    if inIngressSection && currentIndentLevel > serviceIndentLevel && trimmedLine.starts(with: "hostname:") { return extractYamlValue(from: trimmedLine.dropFirst("hostname:".count)) }
                }
            }
        } catch { print(String(format: NSLocalizedString("⚠️ Config read error: %@, %@", comment: "Log message: Error reading config file. Parameters are file path and error."), filePath, error.localizedDescription)) }
        return nil
    }

    private func extractYamlValue(from valueSubstring: Substring) -> String {
        let trimmedValue = valueSubstring.trimmingCharacters(in: .whitespaces)
        if trimmedValue.hasPrefix("\"") && trimmedValue.hasSuffix("\"") { return String(trimmedValue.dropFirst().dropLast()) }
        if trimmedValue.hasPrefix("'") && trimmedValue.hasSuffix("'") { return String(trimmedValue.dropFirst().dropLast()) }
        return String(trimmedValue)
    }

    // Finds the absolute path to the credentials file referenced in a config
        func findCredentialPath(for configPath: String) -> String? {
            guard let credentialsPathValue = parseValueFromYaml(key: "credentials-file", filePath: configPath) else {
                print(String(format: NSLocalizedString("   Warning: 'credentials-file' key not found in config: %@", comment: "Log message: 'credentials-file' key not found in config. Parameter is config path."), configPath))
                return nil
            }

            // Step 1: Expand tilde (~) if present
            let expandedPathString = (credentialsPathValue as NSString).expandingTildeInPath

            // Step 2: Standardize the expanded path (e.g., cleans up unnecessary /../ parts)
            // Convert expandedPathString (Swift String) back to NSString for standardization.
            let standardizedPath = (expandedPathString as NSString).standardizingPath

            // Step 3: Check if the standardized absolute path exists
            if standardizedPath.hasPrefix("/") && FileManager.default.fileExists(atPath: standardizedPath) {
                // If found, return the standardized path
                return standardizedPath
            } else {
                print(String(format: NSLocalizedString("   Credential file not found at path specified in config: %@ (Original: '%@', Config: %@)", comment: "Log message: Credential file not found at specified path. Parameters are standardized path, original path, config path."), standardizedPath, credentialsPathValue, configPath))

                // --- Fallback (rarely needed if absolute path doesn't work) ---
                // Check path relative to ~/.cloudflared directory
                let pathInCloudflaredDir = cloudflaredDirectoryPath.appending("/").appending(credentialsPathValue)
                let standardizedRelativePath = (pathInCloudflaredDir as NSString).standardizingPath // Standardize this too
                if FileManager.default.fileExists(atPath: standardizedRelativePath) {
                    print(String(format: NSLocalizedString("   Fallback: Credential file found in ~/.cloudflared: %@", comment: "Log message: Fallback, credential file found in .cloudflared directory. Parameter is path."), standardizedRelativePath))
                    return standardizedRelativePath
                }
                // --- End Fallback ---

                return nil // Not found anywhere
            }
        }


    // Finds the first hostname listed in the ingress rules
    func findHostname(for configPath: String) -> String? {
         return parseValueFromYaml(key: "hostname", filePath: configPath)
    }

    // MARK: - DNS Routing
    func routeDns(tunnelInfo: TunnelInfo, hostname: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cloudflared not found.", comment: "Error message in routeDns: cloudflared not found.")]))); return
        }
        guard !hostname.isEmpty && hostname.contains(".") && hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
             completion(.failure(NSError(domain: "InputError", code: 13, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid hostname format.", comment: "Error message: Invalid hostname format for DNS routing.")])))
             return
        }

        let tunnelIdentifier = tunnelInfo.uuidFromConfig ?? tunnelInfo.name
        print(String(format: NSLocalizedString("🔗 Routing DNS: %@ -> %@...", comment: "Log message: Routing DNS. Parameters are tunnel identifier and hostname."), tunnelIdentifier, hostname))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        process.arguments = ["tunnel", "route", "dns", tunnelIdentifier, hostname]
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe

        process.terminationHandler = { terminatedProcess in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = terminatedProcess.terminationStatus

            print(String(format: NSLocalizedString("   'tunnel route dns' finished. Status: %d", comment: "Log message: 'tunnel route dns' command finished. Parameter is status code."), status))
            if !outputString.isEmpty { print(String(format: NSLocalizedString("   Output: %@", comment: "Log message: Output from command. Parameter is output string."), outputString)) }
            if !errorString.isEmpty { print(String(format: NSLocalizedString("   Error: %@", comment: "Log message: Error output from command. Parameter is error string."), errorString)) }

            if status == 0 {
                if errorString.lowercased().contains(NSLocalizedString("already exists", comment: "Substring in error message for DNS record already exists").lowercased()) || outputString.lowercased().contains(NSLocalizedString("already exists", comment: "Substring in output message for DNS record already exists").lowercased()) {
                     completion(.success(String(format: NSLocalizedString("Success: DNS record already exists or was updated.\n%@", comment: "Success message: DNS record already exists or updated. Parameter is command output."), outputString)))
                } else {
                     completion(.success(outputString.isEmpty ? NSLocalizedString("DNS route added/updated successfully.", comment: "Success message: DNS route added/updated.") : outputString))
                }
            } else {
                let errorMsg = errorString.isEmpty ? String(format: NSLocalizedString("DNS routing error (Code: %d). Is your domain on Cloudflare?", comment: "Error message: DNS routing error. Parameter is exit code."), status) : errorString
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }
    
    
    
    // Add inside TunnelManager class, preferably near updateMampVHost function:
    private func updateMampHttpdConfListen(port: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let portInt = Int(port), (1...65535).contains(portInt) else {
            completion(.failure(NSError(domain: "HttpdConfError", code: 30, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Invalid Port Number: %@", comment: "Error message: Invalid port number for httpd.conf Listen. Parameter is port."), port)])))
            return
        }
        let listenDirective = "Listen \(port)" // e.g., "Listen 8080"
        let httpdPath = mampHttpdConfPath

        guard FileManager.default.fileExists(atPath: httpdPath) else {
            completion(.failure(NSError(domain: "HttpdConfError", code: 31, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("MAMP httpd.conf file not found: %@", comment: "Error message: MAMP httpd.conf not found. Parameter is path."), httpdPath)])))
            return
        }

        // Check write permission (at least for the parent directory)
        guard FileManager.default.isWritableFile(atPath: httpdPath) else {
             completion(.failure(NSError(domain: "HttpdConfError", code: 32, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Write permission error: MAMP httpd.conf file could not be updated (%@). Check permissions.", comment: "Error message: Write permission error for httpd.conf. Parameter is path."), httpdPath)])))
             return
        }

        do {
            var currentContent = try String(contentsOfFile: httpdPath, encoding: .utf8)

            // Check if the directive already exists (excluding commented lines)
            // Regex: Start of line, optional whitespace, "Listen", whitespace, port number, whitespace or end of line.
            let pattern = #"^\s*Listen\s+\#(portInt)\s*(?:#.*)?$"#
            if currentContent.range(of: pattern, options: .regularExpression) != nil {
                print(String(format: NSLocalizedString("ℹ️ MAMP httpd.conf already contains '%@'.", comment: "Log message: httpd.conf already contains Listen directive. Parameter is the directive."), listenDirective))
                completion(.success(()))
                return
            }

            // Find insertion point: target after the last "Listen" line
            var insertionPoint = currentContent.endIndex
            // Pattern: Start of line, optional whitespace, "Listen", whitespace, DIGITS.
            let lastListenPattern = #"^\s*Listen\s+\d+"#
            // Search from the end
            if let lastListenMatchRange = currentContent.range(of: lastListenPattern, options: [.regularExpression, .backwards]) {
                // Find the end of the found line
                if let lineEndRange = currentContent.range(of: "\n", options: [], range: lastListenMatchRange.upperBound..<currentContent.endIndex) {
                    insertionPoint = lineEndRange.upperBound // Start of the next line
                } else {
                    // If it's the last line of the file, add a newline before appending
                    if !currentContent.hasSuffix("\n") { currentContent += "\n" }
                    insertionPoint = currentContent.endIndex
                }
            } else {
                // If no "Listen" found (very rare), append to the end of the file
                print(NSLocalizedString("⚠️ No 'Listen' directive found in MAMP httpd.conf. Appending to end.", comment: "Log message: No Listen directive found, appending to end."))
                if !currentContent.hasSuffix("\n") { currentContent += "\n" }
                insertionPoint = currentContent.endIndex
            }

            // Prepare content to insert
            let contentToInsert = "\n# Added by Cloudflared Manager App for port \(port)\n\(listenDirective)\n"
            currentContent.insert(contentsOf: contentToInsert, at: insertionPoint)

            // Write modified content to file
            try currentContent.write(toFile: httpdPath, atomically: true, encoding: .utf8)
            print(String(format: NSLocalizedString("✅ MAMP httpd.conf updated: '%@' directive added.", comment: "Log message: httpd.conf updated with Listen directive. Parameter is the directive."), listenDirective))

            // Inform user (MAMP restart reminder)
            let notificationTitle = NSLocalizedString("MAMP httpd.conf Updated", comment: "Notification title: MAMP httpd.conf updated")
            let notificationBody = String(format: NSLocalizedString("'%@' directive added. MAMP servers may need to be restarted for changes to take effect.", comment: "Notification body: Listen directive added to httpd.conf, MAMP restart may be needed. Parameter is the directive."), listenDirective)
            postUserNotification(
                identifier: "mamp_httpd_listen_added_\(port)",
                title: notificationTitle,
                body: notificationBody
            )
            completion(.success(()))

        } catch {
            print(String(format: NSLocalizedString("❌ ERROR updating MAMP httpd.conf: %@", comment: "Log message: Error updating httpd.conf. Parameter is error."), error.localizedDescription))
            // Pass error details to completion
            completion(.failure(NSError(domain: "HttpdConfError", code: 33, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("MAMP httpd.conf read/write error: %@", comment: "Error message: httpd.conf read/write error. Parameter is error description."), error.localizedDescription)])))
        }
    }

    // MARK: - Cloudflare Login
    func cloudflareLogin(completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cloudflared not found.", comment: "Error message in cloudflareLogin: cloudflared not found.")]))); return
        }
        print(NSLocalizedString("🔑 Initializing Cloudflare login (browser will open)...", comment: "Log message: Initializing Cloudflare login."))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        process.arguments = ["login"]
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe

        process.terminationHandler = { terminatedProcess in
             let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
             let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
             let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
             let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
             let status = terminatedProcess.terminationStatus
             print(String(format: NSLocalizedString("   'cloudflared login' finished. Status: %d", comment: "Log message: 'cloudflared login' command finished. Parameter is status code."), status))
             if !outputString.isEmpty { print(String(format: NSLocalizedString("   Output:\n%@", comment: "Log message: Output from command. Parameter is output string."), outputString)) }
             if !errorString.isEmpty { print(String(format: NSLocalizedString("   Error:\n%@", comment: "Log message: Error output from command. Parameter is error string."), errorString)) }

             if status == 0 {
                 if outputString.contains(NSLocalizedString("You have successfully logged in", comment: "Substring in login success message")) || outputString.contains(NSLocalizedString("already logged in", comment: "Substring in already logged in message")) {
                     print(NSLocalizedString("   ✅ Login successful or already logged in.", comment: "Log message: Login successful or already done."))
                     completion(.success(()))
                 } else {
                     print(NSLocalizedString("   Login process initiated, continue in browser.", comment: "Log message: Login process started, user to continue in browser."))
                     completion(.success(())) // Assume user needs to interact with browser
                 }
             } else {
                 let errorMsg = errorString.isEmpty ? String(format: NSLocalizedString("Unknown Cloudflare login error (Code: %d)", comment: "Error message: Unknown Cloudflare login error. Parameter is exit code."), status) : errorString
                 completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
             }
         }
        do {
             try process.run()
             print(NSLocalizedString("   Cloudflare login page should open in browser, or you are already logged in.", comment: "Log message: Cloudflare login page should open or user already logged in."))
         } catch {
             print(String(format: NSLocalizedString("❌ Failed to start Cloudflare login process: %@", comment: "Log message: Failed to start Cloudflare login process. Parameter is error."), error.localizedDescription))
             completion(.failure(error))
         }
    }

     // MARK: - Quick Tunnel Management (Revised URL Detection)
    func startQuickTunnel(localURL: String, completion: @escaping (Result<UUID, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("cloudflared not found: %@", comment: "Error message: cloudflared not found for quick tunnel. Parameter is path."), cloudflaredExecutablePath)]))); return
        }
        guard let url = URL(string: localURL), url.scheme != nil, url.host != nil else {
            completion(.failure(NSError(domain: "InputError", code: 10, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid local URL format. (e.g., http://localhost:8000)", comment: "Error message: Invalid local URL format for quick tunnel.")]))); return
        }

        print(String(format: NSLocalizedString("🚀 Starting quick tunnel (Simple Arg): %@...", comment: "Log message: Starting quick tunnel with simple argument. Parameter is local URL."), localURL))
        let process = Process()
        let tunnelID = UUID()

        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        process.arguments = ["tunnel", "--url", localURL] // Simple arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let bufferLock = NSLock()
        let pipeQueue = DispatchQueue(label: "com.cloudflaredmanager.quicktunnel.pipe-\(tunnelID)", qos: .utility)
        var combinedOutputBuffer = ""

        let processOutput: (Data, String) -> Void = { [weak self] data, streamName in
            guard let self = self else { return }
            if let line = String(data: data, encoding: .utf8) {
                pipeQueue.async {
                    bufferLock.lock()
                    combinedOutputBuffer += line
                    // Only try to parse URL, no error searching here.
                    self.parseQuickTunnelOutput(outputBuffer: combinedOutputBuffer, tunnelID: tunnelID)
                    bufferLock.unlock()
                }
            }
        }

        // Set up handlers
        outputPipe.fileHandleForReading.readabilityHandler = { pipe in
            let data = pipe.availableData
            if data.isEmpty { pipe.readabilityHandler = nil } else { processOutput(data, "stdout") }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { pipe in
            let data = pipe.availableData
            if data.isEmpty { pipe.readabilityHandler = nil } else { processOutput(data, "stderr") }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
                     outputPipe.fileHandleForReading.readabilityHandler = nil
                     errorPipe.fileHandleForReading.readabilityHandler = nil

                     bufferLock.lock()
                     let finalCombinedOutput = combinedOutputBuffer
                     bufferLock.unlock()

                     DispatchQueue.main.async {
                         guard let self = self else { return }
                         let status = terminatedProcess.terminationStatus
                         let reason = terminatedProcess.terminationReason
                         print(String(format: NSLocalizedString("🏁 Quick tunnel (%1$@ - %2$@) finished. Code: %3$d, Reason: %4$@", comment: "Log message: Quick tunnel finished. Parameters are tunnel ID, local URL, exit code, exit reason."), tunnelID.uuidString, localURL, status, (reason == .exit ? "Exit" : "Signal")))
                        // if !finalCombinedOutput.isEmpty { print("   🏁 Son Buffer [\(tunnelID)]:\n---\n\(finalCombinedOutput)\n---") }

                         guard let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }) else {
                             print(String(format: NSLocalizedString("   Termination handler: Quick tunnel %@ not found in list.", comment: "Log message: Quick tunnel not found in list during termination. Parameter is tunnel ID."), tunnelID.uuidString))
                             self.runningQuickProcesses.removeValue(forKey: tunnelID)
                             return
                         }

                         var tunnelData = self.quickTunnels[index]
                         let urlWasFound = tunnelData.publicURL != nil
                         let wasStoppedIntentionally = self.runningQuickProcesses[tunnelID] == nil || (reason == .exit && status == 0) || (reason == .uncaughtSignal && status == SIGTERM)

                         // Error State: Only if URL was NOT found AND terminated unexpectedly
                         if !urlWasFound && !wasStoppedIntentionally && !(reason == .exit && status == 0) {
                             print(String(format: NSLocalizedString("   ‼️ Quick Tunnel: URL not found and terminated unexpectedly [%@].", comment: "Log message: Quick tunnel URL not found and terminated unexpectedly. Parameter is tunnel ID."), tunnelID.uuidString))
                             let errorLines = finalCombinedOutput.split(separator: "\n").filter {
                                 $0.lowercased().contains("error") || $0.lowercased().contains("fail") || $0.lowercased().contains("fatal")
                             }.map(String.init)
                             var finalError = errorLines.prefix(3).joined(separator: "\n")
                             if finalError.isEmpty {
                                 finalError = String(format: NSLocalizedString("Process terminated before URL was found (Code: %d). Check output.", comment: "Error message: Process terminated before URL found. Parameter is exit code."), status)
                             }
                             tunnelData.lastError = finalError // Set error
                             print(String(format: NSLocalizedString("   Error message set: %@", comment: "Log message: Error message set for quick tunnel. Parameter is error message."), finalError))
                             // Error notification
                             let errorTitle = NSLocalizedString("Quick Tunnel Error", comment: "Notification title: Quick tunnel error")
                             let errorBody = String(format: NSLocalizedString("%1$@\n%2$@...", comment: "Notification body: Quick tunnel error. Parameters are local URL and truncated error message."), localURL, finalError.prefix(100))
                             self.postUserNotification(identifier: "quick_fail_\(tunnelID)", title: errorTitle, body: errorBody)
                         } else if wasStoppedIntentionally {
                              print(String(format: NSLocalizedString("   Quick tunnel stopped or finished normally (%@).", comment: "Log message: Quick tunnel stopped or finished normally. Parameter is tunnel ID."), tunnelID.uuidString))
                              // Successful stop notification (if URL was found or clean exit)
                              if urlWasFound || (reason == .exit && status == 0) {
                                  let notificationTitle = NSLocalizedString("Quick Tunnel Stopped", comment: "Notification title: Quick tunnel stopped")
                                  self.postUserNotification(identifier: "quick_stopped_\(tunnelID)", title: notificationTitle, body: localURL)
                              }
                         }
                         // else: URL was found and it was running normally (until close signal) - no error.

                         // Remove from list and map
                         self.quickTunnels.remove(at: index)
                         self.runningQuickProcesses.removeValue(forKey: tunnelID)
                     }
                 }



        // --- Start process part ---
              do {
                  DispatchQueue.main.async {
                       // lastError should be nil initially
                       let tunnelData = QuickTunnelData(process: process, publicURL: nil, localURL: localURL, processIdentifier: nil, lastError: nil)
                       self.quickTunnels.append(tunnelData)
                       self.runningQuickProcesses[tunnelID] = process
                  }
                  try process.run()
                  let pid = process.processIdentifier
                  DispatchQueue.main.async {
                       if let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }) {
                           self.quickTunnels[index].processIdentifier = pid
                       }
                       print(String(format: NSLocalizedString("   Quick tunnel process started (PID: %1$d, ID: %2$@). Waiting for output...", comment: "Log message: Quick tunnel process started. Parameters are PID and tunnel ID."), pid, tunnelID.uuidString))
                       completion(.success(tunnelID))
                  }

        } catch {
            print(String(format: NSLocalizedString("❌ Failed to start quick tunnel process (try process.run() error): %@", comment: "Log message: Failed to start quick tunnel process. Parameter is error."), error.localizedDescription))
            // Clean up if start fails
            DispatchQueue.main.async {
                     self.quickTunnels.removeAll { $0.id == tunnelID }
                     self.runningQuickProcesses.removeValue(forKey: tunnelID)
                     let errorTitle = NSLocalizedString("Quick Tunnel Start Error", comment: "Notification title: Error starting quick tunnel")
                     let errorBody = String(format: NSLocalizedString("Failed to start process: %@", comment: "Notification body: Failed to start quick tunnel process. Parameter is error description."), error.localizedDescription)
                     self.postUserNotification(identifier: "quick_start_run_fail_\(tunnelID)", title: errorTitle, body: errorBody)
                     completion(.failure(error))
                }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
           }
       } /// End of startQuickTunnel


    // Only searches for URL, not errors. Updates status if URL is found.
    private func parseQuickTunnelOutput(outputBuffer: String, tunnelID: UUID) {
        var urlAlreadyFound = false
        DispatchQueue.main.sync {
            urlAlreadyFound = self.quickTunnels.first(where: { $0.id == tunnelID })?.publicURL != nil
        }
        guard !urlAlreadyFound else { return } // Exit if already found

        // URL Search
               let urlPattern = #"(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
               let establishedPattern = #"Tunnel established at\s+(\S+)"# // Or "Visit it at ... URL" line
               let visitPattern = #"Visit it at.*(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
               var foundURL: String? = nil

               // First search for "established at" or "Visit it at" lines
               if let establishedMatch = outputBuffer.range(of: establishedPattern, options: .regularExpression) {
                    if let urlRange = outputBuffer.range(of: urlPattern, options: .regularExpression, range: establishedMatch) {
                        foundURL = String(outputBuffer[urlRange])
                    }
               } else if let visitMatch = outputBuffer.range(of: visitPattern, options: .regularExpression) {
                    // Regex's 1st capture group is the URL
                    let matchString = String(outputBuffer[visitMatch])
                    if let urlRange = matchString.range(of: urlPattern, options: .regularExpression) {
                         foundURL = String(matchString[urlRange])
                    }
               }

        // If URL Found -> Update Status (on Main Thread)
        if let theURL = foundURL {
            DispatchQueue.main.async {
                if let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }), self.quickTunnels[index].publicURL == nil {
                    self.quickTunnels[index].publicURL = theURL
                    self.quickTunnels[index].lastError = nil // Ensure no error
                    print(String(format: NSLocalizedString("   ☁️ Quick Tunnel URL (%@): %@", comment: "Log message: Quick tunnel URL found. Parameters are tunnel ID and URL."), tunnelID.uuidString, theURL))
                    let notificationTitle = NSLocalizedString("Quick Tunnel Ready", comment: "Notification title: Quick tunnel is ready")
                    let notificationBody = String(format: NSLocalizedString("%1$@\n⬇️\n%2$@", comment: "Notification body: Quick tunnel ready. Parameters are local URL and public URL."), self.quickTunnels[index].localURL, theURL)
                    self.postUserNotification(identifier: "quick_url_\(tunnelID)", title: notificationTitle, body: notificationBody)
                }
            }
            // Exit this function after URL is found (no need to parse further)
        }

        // --- Error Search (Only come here if URL not found yet) ---
        let errorPatterns = [
            "error", "fail", "fatal", "cannot", "unable", "could not", "refused", "denied",
            "address already in use", "invalid tunnel credentials", "dns record creation failed"
        ].map { NSLocalizedString($0, comment: "Error keyword for parsing quick tunnel output: \($0)") } // Localize keywords if necessary, though likely stable
        var detectedError: String? = nil
        for errorPattern in errorPatterns {
             // Search for error pattern in the whole buffer
             if outputBuffer.lowercased().range(of: errorPattern.lowercased()) != nil {
                 // Try to find the *last* relevant line in the buffer (might be more meaningful)
                 let errorLine = outputBuffer.split(separator: "\n").last(where: { $0.lowercased().contains(errorPattern.lowercased()) })
                 detectedError = String(errorLine ?? Substring(String(format: NSLocalizedString("Error detected: %@", comment: "Generic error detected message. Parameter is the error pattern."), errorPattern)))
                                    .prefix(150).trimmingCharacters(in: .whitespacesAndNewlines)
                 // print("   ‼️ Hata Deseni Algılandı [\(tunnelID)]: '\(errorPattern)' -> Mesaj: \(detectedError!)") // Optional debug log
                 break // Take the first error found and exit
             }
        }

        // If an error was detected, update status on main thread
        if let finalError = detectedError {
            DispatchQueue.main.async {
                // Ensure URL is still not found
                if let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }), self.quickTunnels[index].publicURL == nil {
                    // Only update if current error is nil or "Starting..."
                    if self.quickTunnels[index].lastError == nil || self.quickTunnels[index].lastError == NSLocalizedString("Starting...", comment: "Initial status for quick tunnel error before specific error is found") {
                         self.quickTunnels[index].lastError = finalError
                         print(String(format: NSLocalizedString("   Quick Tunnel Start Error Updated (%@): %@", comment: "Log message: Quick tunnel start error updated. Parameters are tunnel ID and error message."), tunnelID.uuidString, finalError))
                    }
                }
            }
        }
    } 

     func stopQuickTunnel(id: UUID) {
         DispatchQueue.main.async { // Ensure access to quickTunnels and runningQuickProcesses is synchronized
              guard let process = self.runningQuickProcesses[id] else {
                  print(String(format: NSLocalizedString("❓ Quick tunnel process to stop not found: %@", comment: "Log message: Quick tunnel process to stop not found. Parameter is tunnel ID."), id.uuidString))
                  if let index = self.quickTunnels.firstIndex(where: { $0.id == id }) {
                      print(NSLocalizedString("   Also removing from list.", comment: "Log message suffix: Also removing from quick tunnel list."))
                      self.quickTunnels.remove(at: index) // Remove lingering data if process gone
                  }
                  return
              }

              guard let tunnelData = self.quickTunnels.first(where: { $0.id == id }) else {
                   print(String(format: NSLocalizedString("❓ Quick tunnel data to stop not found (process exists but data missing): %@", comment: "Log message: Quick tunnel data to stop not found. Parameter is tunnel ID."), id.uuidString))
                   self.runningQuickProcesses.removeValue(forKey: id)
                   process.terminate() // Terminate process anyway
                   return
              }

              print(String(format: NSLocalizedString("🛑 Stopping quick tunnel: %@ (%@) PID: %d", comment: "Log message: Stopping quick tunnel. Parameters are local URL, tunnel ID, PID."), tunnelData.localURL, id.uuidString, process.processIdentifier))
              // Remove from map *before* terminating to signal intent
              self.runningQuickProcesses.removeValue(forKey: id)
              process.terminate() // Send SIGTERM
              // Termination handler will remove it from the `quickTunnels` array and send notification.
          }
     }

    // MARK: - Bulk Actions
    func startAllManagedTunnels() {
        print(NSLocalizedString("--- Start All Managed ---", comment: "Log section header: Start All Managed Tunnels"))
         DispatchQueue.main.async {
             let tunnelsToStart = self.tunnels.filter { $0.isManaged && ($0.status == .stopped || $0.status == .error) }
             if tunnelsToStart.isEmpty { print(NSLocalizedString("   No managed tunnels to start.", comment: "Log message: No managed tunnels to start.")); return }
             print(String(format: NSLocalizedString("   Tunnels to start: %@", comment: "Log message: List of tunnels to start. Parameter is list of names."), tunnelsToStart.map { $0.name }.joined(separator: ", ")))
             tunnelsToStart.forEach { self.startManagedTunnel($0) }
         }
    }

    func stopAllTunnels(synchronous: Bool = false) {
        print(String(format: NSLocalizedString("--- Stop All Tunnels (%@) ---", comment: "Log section header: Stop All Tunnels. Parameter is sync/async."), (synchronous ? NSLocalizedString("Synchronous", comment: "Synchronous mode for stopping tunnels") : NSLocalizedString("Asynchronous", comment: "Asynchronous mode for stopping tunnels"))))
        var didStopSomething = false

        DispatchQueue.main.async { // Ensure array/dict access is safe
            // Stop Managed Tunnels
            let configPathsToStop = Array(self.runningManagedProcesses.keys)
            if !configPathsToStop.isEmpty {
                print(NSLocalizedString("   Stopping managed tunnels...", comment: "Log message: Stopping managed tunnels."))
                for configPath in configPathsToStop {
                    if let tunnelInfo = self.tunnels.first(where: { $0.configPath == configPath }) {
                        self.stopManagedTunnel(tunnelInfo, synchronous: synchronous)
                        didStopSomething = true
                    } else {
                        print(String(format: NSLocalizedString("⚠️ Running process (%@) not in list, stopping anyway...", comment: "Log message: Running process not in list, stopping it. Parameter is config path."), configPath))
                        if let process = self.runningManagedProcesses.removeValue(forKey: configPath) {
                            if synchronous { _ = self.stopProcessAndWait(process, timeout: 2.0) } else { process.terminate() }
                            didStopSomething = true
                        }
                    }
                }
                if synchronous { print(NSLocalizedString("--- Synchronous managed stops complete (or signal sent) ---", comment: "Log message: Synchronous managed tunnel stops complete.")) }
            } else {
                print(NSLocalizedString("   No running managed tunnels.", comment: "Log message: No running managed tunnels."))
                 // Ensure UI consistency
                 self.tunnels.indices.filter{ self.tunnels[$0].isManaged && [.running, .stopping, .starting].contains(self.tunnels[$0].status) }
                                   .forEach { idx in
                                       self.tunnels[idx].status = .stopped; self.tunnels[idx].processIdentifier = nil; self.tunnels[idx].lastError = nil
                                   }
            }

            // Stop Quick Tunnels (Always Asynchronous via stopQuickTunnel)
            let quickTunnelIDsToStop = Array(self.runningQuickProcesses.keys)
            if !quickTunnelIDsToStop.isEmpty {
                print(NSLocalizedString("   Stopping quick tunnels...", comment: "Log message: Stopping quick tunnels."))
                for id in quickTunnelIDsToStop {
                    self.stopQuickTunnel(id: id)
                    didStopSomething = true
                }
            } else {
                 print(NSLocalizedString("   No running quick tunnels.", comment: "Log message: No running quick tunnels."))
                 // Ensure UI consistency
                 if !self.quickTunnels.isEmpty {
                     print(NSLocalizedString("   ⚠️ No running quick tunnel processes but list is not empty, clearing.", comment: "Log message: Quick tunnel list not empty but no processes running, clearing list."))
                     self.quickTunnels.removeAll()
                 }
            }

            if didStopSomething {
                 // Send notification after a brief delay to allow termination handlers to potentially run
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                      let title = NSLocalizedString("All Tunnels Stopped", comment: "Notification title: All tunnels stopped")
                      let body = synchronous ? NSLocalizedString("(Synchronous stop attempted)", comment: "Notification body suffix: Synchronous stop attempted") : nil
                      self?.postUserNotification(identifier: "all_stopped", title: title, body: body)
                 }
            }
        } // End DispatchQueue.main.async
    }


    // MARK: - Status Checking (Managed Tunnels Only)
    func checkManagedTunnelStatus(tunnel: TunnelInfo) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else { return }

        DispatchQueue.main.async {
             guard let index = self.tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
             let currentTunnelState = self.tunnels[index]

             if let process = self.runningManagedProcesses[configPath] {
                 if process.isRunning {
                     if currentTunnelState.status != .running && currentTunnelState.status != .starting {
                         print(String(format: NSLocalizedString("🔄 Status corrected (Check): %@ (%@) -> Running", comment: "Log message: Corrected tunnel status to Running. Parameters are tunnel name and old status."), currentTunnelState.name, currentTunnelState.status.displayName))
                         self.tunnels[index].status = .running
                         self.tunnels[index].processIdentifier = process.processIdentifier
                         self.tunnels[index].lastError = nil
                     } else if currentTunnelState.status == .running && currentTunnelState.processIdentifier != process.processIdentifier {
                          print(String(format: NSLocalizedString("🔄 PID corrected (Check): %@ %d -> %d", comment: "Log message: Corrected tunnel PID. Parameters are tunnel name, old PID, new PID."), currentTunnelState.name, currentTunnelState.processIdentifier ?? -1, process.processIdentifier))
                          self.tunnels[index].processIdentifier = process.processIdentifier
                     }
                 } else { // Process in map but not running (unexpected termination)
                     print(String(format: NSLocalizedString("⚠️ Check: %@ process in map but not running! Termination handler should have caught this. Cleaning up.", comment: "Log message: Process in map but not running. Parameter is tunnel name."), currentTunnelState.name))
                     self.runningManagedProcesses.removeValue(forKey: configPath)
                     if currentTunnelState.status == .running || currentTunnelState.status == .starting {
                         self.tunnels[index].status = .error
                         if self.tunnels[index].lastError == nil { self.tunnels[index].lastError = NSLocalizedString("Process terminated unexpectedly (found in map but not running).", comment: "Error message: Process found in map but not running.") }
                         print(NSLocalizedString("   Status -> Error (Check)", comment: "Log message suffix: Status changed to Error during check."))
                     } else if currentTunnelState.status == .stopping {
                         self.tunnels[index].status = .stopped
                          print(NSLocalizedString("   Status -> Stopped (Check)", comment: "Log message suffix: Status changed to Stopped during check."))
                     }
                     self.tunnels[index].processIdentifier = nil
                 }
             } else { // Process not in map
                 if currentTunnelState.status == .running || currentTunnelState.status == .starting || currentTunnelState.status == .stopping {
                     print(String(format: NSLocalizedString("🔄 Status corrected (Check): %@ process not in map -> Stopped", comment: "Log message: Corrected tunnel status to Stopped (process not in map). Parameter is tunnel name."), currentTunnelState.name))
                     self.tunnels[index].status = .stopped
                     self.tunnels[index].processIdentifier = nil
                 }
             }
        } // End DispatchQueue.main.async
    }

    func checkAllManagedTunnelStatuses(forceCheck: Bool = false) {
        DispatchQueue.main.async {
            guard !self.tunnels.isEmpty else { return }
            // if forceCheck { print("--- Tüm Yönetilen Tünel Durumları Kontrol Ediliyor ---") } // Optional logging
            let managedTunnelsToCheck = self.tunnels.filter { $0.isManaged }
            managedTunnelsToCheck.forEach { self.checkManagedTunnelStatus(tunnel: $0) }
        }
    }

    // MARK: - File Monitoring
    func startMonitoringCloudflaredDirectory() {
        let url = URL(fileURLWithPath: cloudflaredDirectoryPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
             print(String(format: NSLocalizedString("❌ Monitoring could not be started: Directory does not exist or is not a directory - %@", comment: "Log message: Failed to start directory monitoring. Parameter is path."), url.path))
             findManagedTunnels() // Try to create it
             // Consider retrying monitoring setup later if needed
             return
        }
        let fileDescriptor = Darwin.open((url as NSURL).fileSystemRepresentation, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print(String(format: NSLocalizedString("❌ Error: Could not open %@ for monitoring. Errno: %d (%@)", comment: "Log message: Error opening directory for monitoring. Parameters are path, errno, strerror."), cloudflaredDirectoryPath, errno, String(cString: strerror(errno)))); return
        }

        directoryMonitor?.cancel()
        directoryMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: DispatchQueue.global(qos: .utility))

        directoryMonitor?.setEventHandler { [weak self] in
            self?.monitorDebounceTimer?.invalidate()
            self?.monitorDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                print(String(format: NSLocalizedString("📂 Change detected: %@ -> Refreshing managed tunnel list.", comment: "Log message: Change detected in directory, refreshing list. Parameter is directory path."), self?.cloudflaredDirectoryPath ?? ""))
                 DispatchQueue.main.async { self?.findManagedTunnels() }
            }
             if let timer = self?.monitorDebounceTimer { RunLoop.main.add(timer, forMode: .common) }
        }

        directoryMonitor?.setCancelHandler { close(fileDescriptor) }
        directoryMonitor?.resume()
        print(String(format: NSLocalizedString("👀 Directory monitoring started: %@", comment: "Log message: Directory monitoring started. Parameter is path."), cloudflaredDirectoryPath))
    }

    func stopMonitoringCloudflaredDirectory() {
        monitorDebounceTimer?.invalidate(); monitorDebounceTimer = nil
        if directoryMonitor != nil {
             print(String(format: NSLocalizedString("🛑 Stopping directory monitoring: %@", comment: "Log message: Stopping directory monitoring. Parameter is path."), cloudflaredDirectoryPath))
             directoryMonitor?.cancel(); directoryMonitor = nil
        }
    }

     // MARK: - MAMP Integration Helpers
     func scanMampSitesFolder() -> [String] {
         guard FileManager.default.fileExists(atPath: mampSitesDirectoryPath) else {
             print(String(format: NSLocalizedString("❌ MAMP site directory not found: %@", comment: "Log message: MAMP site directory not found. Parameter is path."), mampSitesDirectoryPath))
             return []
         }
         var siteFolders: [String] = []
         do {
             let items = try FileManager.default.contentsOfDirectory(atPath: mampSitesDirectoryPath)
             for item in items {
                 var isDirectory: ObjCBool = false
                 let fullPath = "\(mampSitesDirectoryPath)/\(item)"
                 if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue, !item.starts(with: ".") {
                     siteFolders.append(item)
                 }
             }
         } catch { print(String(format: NSLocalizedString("❌ Could not scan MAMP site directory: %@ - %@", comment: "Log message: Error scanning MAMP site directory. Parameters are path and error."), mampSitesDirectoryPath, error.localizedDescription)) }
         return siteFolders.sorted()
     }

    // updateMampVHost function completely replaced
    // updateMampVHost function completely replaced (Including bug fix)
    func updateMampVHost(serverName: String, documentRoot: String, port: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: documentRoot) else {
            completion(.failure(NSError(domain: "VHostError", code: 20, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("DocumentRoot not found: %@", comment: "Error message: DocumentRoot not found for MAMP vHost. Parameter is path."), documentRoot)]))); return
        }
        guard !serverName.isEmpty && serverName.contains(".") else {
            completion(.failure(NSError(domain: "VHostError", code: 21, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Invalid ServerName: %@", comment: "Error message: Invalid ServerName for MAMP vHost. Parameter is server name."), serverName)]))); return
        }
        // Check if port number is valid (extra safety)
        guard let portInt = Int(port), (1...65535).contains(portInt) else {
            completion(.failure(NSError(domain: "VHostError", code: 25, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Invalid Port Number: %@", comment: "Error message: Invalid port number for MAMP vHost. Parameter is port."), port)]))); return
        }
        let listenDirective = "*:\(port)" // Create listen directive

        let vhostDir = (mampVHostConfPath as NSString).deletingLastPathComponent
        var isDir : ObjCBool = false
        if !FileManager.default.fileExists(atPath: vhostDir, isDirectory: &isDir) || !isDir.boolValue {
            print(String(format: NSLocalizedString("⚠️ MAMP vHost directory not found, creating: %@", comment: "Log message: MAMP vHost directory not found, creating it. Parameter is path."), vhostDir))
            do { try FileManager.default.createDirectory(atPath: vhostDir, withIntermediateDirectories: true, attributes: nil) } catch {
                 completion(.failure(NSError(domain: "VHostError", code: 22, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Could not create MAMP vHost directory: %@\n%@", comment: "Error message: Failed to create MAMP vHost directory. Parameters are path and error."), vhostDir, error.localizedDescription)]))); return
            }
        }

        let vhostEntry = """

        # Added by Cloudflared Manager App for \(serverName) on port \(port)
        <VirtualHost \(listenDirective)>
            ServerName \(serverName)
            DocumentRoot "\(documentRoot)"
            # Optional Logs:
            # ErrorLog "/Applications/MAMP/logs/apache_\(serverName.replacingOccurrences(of: ".", with: "_"))_error.log"
            # CustomLog "/Applications/MAMP/logs/apache_\(serverName.replacingOccurrences(of: ".", with: "_"))_access.log" common
            <Directory "\(documentRoot)">
                Options Indexes FollowSymLinks MultiViews ExecCGI
                AllowOverride All
                Require all granted
            </Directory>
        </VirtualHost>

        """
        do {
            var currentContent = ""
            if FileManager.default.fileExists(atPath: mampVHostConfPath) {
                currentContent = try String(contentsOfFile: mampVHostConfPath, encoding: .utf8)
            } else {
                print(String(format: NSLocalizedString("⚠️ vHost file not found, new file will be created: %@", comment: "Log message: vHost file not found, will create new. Parameter is path."), mampVHostConfPath))
                // Add NameVirtualHost directive if creating a new file
                currentContent = "# Virtual Hosts\nNameVirtualHost \(listenDirective)\n\n"
            }

            // --- START: Corrected vHost Exists Check ---
            let serverNamePattern = #"ServerName\s+\Q\#(serverName)\E"#
            // Using NSRegularExpression for .dotMatchesLineSeparators instead of (?s) flag
            // Pattern: <VirtualHost *:PORT> ... ServerName SERVER ... </VirtualHost>
            let vhostBlockPattern = #"<VirtualHost\s+\*\:\#(port)>.*?\#(serverNamePattern).*?</VirtualHost>"#

            do {
                // Create NSRegularExpression with .dotMatchesLineSeparators option
                let regex = try NSRegularExpression(
                    pattern: vhostBlockPattern,
                    options: [.dotMatchesLineSeparators] // This option is available in NSRegularExpression
                )

                // Search in the entire content
                let searchRange = NSRange(currentContent.startIndex..<currentContent.endIndex, in: currentContent)
                if regex.firstMatch(in: currentContent, options: [], range: searchRange) != nil {
                    // Match found, entry already exists.
                    print(String(format: NSLocalizedString("ℹ️ MAMP vHost file already contains entry for '%@' on port %@. No update made.", comment: "Log message: MAMP vHost entry already exists. Parameters are server name and listen directive."), serverName, listenDirective))
                    completion(.success(()))
                    return // Exit function
                }
                // No match found, continue...
            } catch {
                // Regex creation error (unlikely here if pattern is correct)
                print(String(format: NSLocalizedString("❌ Regex Error: %@ - Pattern: %@", comment: "Log message: Regex error. Parameters are error description and pattern."), error.localizedDescription, vhostBlockPattern))
                completion(.failure(NSError(domain: "VHostError", code: 26, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Could not create regex for vHost check: %@", comment: "Error message: Failed to create regex for vHost check. Parameter is error."), error.localizedDescription)])))
                return
            }
            // --- END: Corrected vHost Exists Check ---


            // If NameVirtualHost directive is missing and file is not empty, add it
            if !currentContent.contains("NameVirtualHost \(listenDirective)") && !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentContent.contains("NameVirtualHost ") { // If no NameVirtualHost at all
                    currentContent = "# Virtual Hosts\nNameVirtualHost \(listenDirective)\n\n" + currentContent
                } else {
                    print(String(format: NSLocalizedString("⚠️ Warning: Other NameVirtualHost directives exist in vHost file. Directive for '%@' not added. Manual check may be required.", comment: "Log message: Other NameVirtualHost directives exist. Parameter is listen directive."), listenDirective))
                }
            }


            let newContent = currentContent + vhostEntry
            try newContent.write(toFile: mampVHostConfPath, atomically: true, encoding: .utf8)
            print(String(format: NSLocalizedString("✅ MAMP vHost file updated: %@ (Port: %@)", comment: "Log message: MAMP vHost file updated. Parameters are path and port."), mampVHostConfPath, port))
            completion(.success(()))

        } catch {
            print(String(format: NSLocalizedString("❌ ERROR updating MAMP vHost file: %@", comment: "Log message: Error updating MAMP vHost file. Parameter is error."), error.localizedDescription))
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
                 completion(.failure(NSError(domain: "VHostError", code: 23, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Write permission error: MAMP vHost file could not be updated (%@). Please check file permissions or add manually.\n%@", comment: "Error message: Write permission error for MAMP vHost. Parameters are path and error."), mampVHostConfPath, error.localizedDescription)])))
            } else {
                 completion(.failure(NSError(domain: "VHostError", code: 24, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Could not write to MAMP vHost file:\n%@", comment: "Error message: Failed to write to MAMP vHost file. Parameter is error."), error.localizedDescription)])))
            }
        }
    }
    // MARK: - Launch At Login (ServiceManagement - Requires macOS 13+)
    // Note: ServiceManagement requires separate configuration (Helper Target or main app registration)
    // These functions assume SMAppService is available and configured correctly.
    @available(macOS 13.0, *)
    func toggleLaunchAtLogin(completion: @escaping (Result<Bool, Error>) -> Void) {
         Task {
             do {
                 let service = SMAppService.mainApp
                 let currentStateEnabled = service.status == .enabled
                 let newStateEnabled = !currentStateEnabled
                 print(String(format: NSLocalizedString("Launch at login: %@", comment: "Log message: Launch at login status change. Parameter is 'Enabling' or 'Disabling'."), (newStateEnabled ? NSLocalizedString("Enabling", comment: "Action: Enabling launch at login") : NSLocalizedString("Disabling", comment: "Action: Disabling launch at login"))))

                 if newStateEnabled {
                     try service.register()
                 } else {
                     try service.unregister()
                 }
                 // Verify state *after* operation
                 let finalStateEnabled = SMAppService.mainApp.status == .enabled
                 if finalStateEnabled == newStateEnabled {
                     print(String(format: NSLocalizedString("   ✅ Launch at login status updated: %@", comment: "Log message: Launch at login status updated successfully. Parameter is new status (true/false)."), String(describing: finalStateEnabled))))
                     completion(.success(finalStateEnabled))
                 } else {
                      print(String(format: NSLocalizedString("❌ Launch at login status could not be changed (expected: %@, result: %@).", comment: "Log message: Failed to change launch at login status. Parameters are expected status and actual status."), String(describing: newStateEnabled), String(describing: finalStateEnabled))))
                      completion(.failure(NSError(domain: "ServiceManagement", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Post-operation status verification failed.", comment: "Error message: Launch at login status verification failed.")])))
                 }
             } catch {
                 print(String(format: NSLocalizedString("❌ Could not change launch at login: %@", comment: "Log message: Error changing launch at login. Parameter is error."), error.localizedDescription))
                 completion(.failure(error))
             }
         }
     }

    @available(macOS 13.0, *)
    func isLaunchAtLoginEnabled() -> Bool {
         // Ensure this check runs relatively quickly. It might involve IPC.
         // Consider caching the state if called very frequently, but for a settings toggle it's fine.
         return SMAppService.mainApp.status == .enabled
     }
}
