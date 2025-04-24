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
            print("Yeni cloudflared yolu ayarlandı: \(cloudflaredExecutablePath)")
            checkCloudflaredExecutable() // Validate the new path
        }
    }
    @Published var checkInterval: TimeInterval = UserDefaults.standard.double(forKey: "checkInterval") > 0 ? UserDefaults.standard.double(forKey: "checkInterval") : 30.0 {
         didSet {
             if checkInterval < 5 { checkInterval = 5 } // Minimum interval 5s
             UserDefaults.standard.set(checkInterval, forKey: "checkInterval")
             setupStatusCheckTimer() // Restart timer with new interval
             print("Yeni kontrol aralığı ayarlandı: \(checkInterval) saniye")
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
        mampHttpdConfPath = "/Applications/MAMP/conf/apache/httpd.conf" // <<< YENİ SABİTİ ATA >>>
        print("Cloudflared directory path: \(cloudflaredDirectoryPath)")
        print("Mamp Config directory path: \(mampConfigDirectoryPath)")
        print("Mamp Sites directory path: \(mampSitesDirectoryPath)")
        print("Mamp vHost path: \(mampVHostConfPath)")
        print("Mamp httpd.conf path: \(mampHttpdConfPath)") // <<< LOG EKLE (opsiyonel) >>>
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
             print("⚠️ UYARI: cloudflared şurada bulunamadı: \(cloudflaredExecutablePath)")
             postUserNotification(identifier:"cloudflared_not_found", title: "Cloudflared Bulunamadı", body: "'\(cloudflaredExecutablePath)' konumunda bulunamadı. Lütfen Ayarlar'dan yolu düzeltin.")
         }
     }

    // MARK: - Timer Setup
    func setupStatusCheckTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
             self?.checkAllManagedTunnelStatuses()
        }
        RunLoop.current.add(statusCheckTimer!, forMode: .common)
        print("Yönetilen tünel durum kontrol timer'ı \(checkInterval) saniye aralıkla kuruldu.")
    }

    // MARK: - Tunnel Discovery (Managed Tunnels from Config Files)
    func findManagedTunnels() {
        print("Yönetilen tüneller aranıyor (config dosyaları): \(cloudflaredDirectoryPath)")
        var discoveredTunnelsDict: [String: TunnelInfo] = [:]
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: cloudflaredDirectoryPath, isDirectory: &isDirectory) {
            print("ℹ️ \(cloudflaredDirectoryPath) dizini bulunamadı, oluşturuluyor...")
            do {
                try fileManager.createDirectory(atPath: cloudflaredDirectoryPath, withIntermediateDirectories: true, attributes: nil)
                print("   ✅ Dizin oluşturuldu.")
                isDirectory = true // Set local variable after successful creation
            } catch {
                print("❌ Hata: \(cloudflaredDirectoryPath) dizini oluşturulamadı: \(error)")
                DispatchQueue.main.async { self.tunnels.removeAll { $0.isManaged } }
                postUserNotification(identifier:"cf_dir_create_error", title: "Cloudflared Dizini Hatası", body: "'\(cloudflaredDirectoryPath)' oluşturulamadı veya erişilemedi.")
                return
            }
        } else if !isDirectory.boolValue {
             print("❌ Hata: \(cloudflaredDirectoryPath) bir dizin değil.")
             DispatchQueue.main.async { self.tunnels.removeAll { $0.isManaged } }
             postUserNotification(identifier:"cf_dir_not_dir", title: "Cloudflared Yolu Hatalı", body: "'\(cloudflaredDirectoryPath)' bir dizin değil.")
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
            print("❌ Hata: \(cloudflaredDirectoryPath) dizini okunurken hata oluştu: \(error)")
            postUserNotification(identifier:"cf_dir_read_error", title: "Dizin Okuma Hatası", body: "'\(cloudflaredDirectoryPath)' okunurken hata oluştu.")
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
                     print("Yeni yönetilen tünel bulundu: \(discoveredTunnel.name)")
                     updatedManagedTunnels.append(discoveredTunnel)
                 }
             }

             let existingConfigFiles = Set(discoveredTunnelsDict.keys)
             let removedTunnels = existingManagedTunnels.filter {
                 guard let configPath = $0.configPath else { return false }
                 return !existingConfigFiles.contains(configPath)
             }

             if !removedTunnels.isEmpty {
                 print("Kaldırılan config dosyaları: \(removedTunnels.map { $0.name })")
                 for removedTunnel in removedTunnels {
                      if let configPath = removedTunnel.configPath, self.runningManagedProcesses[configPath] != nil {
                           print("   Otomatik durduruluyor: \(removedTunnel.name)")
                           self.stopManagedTunnel(removedTunnel, synchronous: true) // Stop synchronously on file removal
                      }
                 }
             }

             self.tunnels = updatedManagedTunnels.sorted { $0.name.lowercased() < $1.name.lowercased() }
             print("Güncel yönetilen tünel listesi: \(self.tunnels.map { $0.name })")
             self.checkAllManagedTunnelStatuses(forceCheck: true)
         }
    }

    // MARK: - Tunnel Control (Start/Stop/Toggle - Managed Only)
    func toggleManagedTunnel(_ tunnel: TunnelInfo) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else {
            print("❌ Hata: Yalnızca yapılandırma dosyası olan yönetilen tüneller değiştirilebilir: \(tunnel.name)")
            return
        }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
             print("❌ Hata: Tünel bulunamadı: \(tunnel.name)")
             return
        }
        let currentStatus = tunnels[index].status
        print("Toggling managed tunnel: \(tunnel.name), Current status: \(currentStatus)")
        switch currentStatus {
        case .running, .starting: stopManagedTunnel(tunnels[index])
        case .stopped, .error: startManagedTunnel(tunnels[index])
        case .stopping: print("\(tunnel.name) zaten durduruluyor.")
        }
    }

    func startManagedTunnel(_ tunnel: TunnelInfo) {
        guard tunnel.isManaged, let configPath = tunnel.configPath else { return }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }

        guard runningManagedProcesses[configPath] == nil, tunnels[index].status != .running, tunnels[index].status != .starting else {
             print("ℹ️ \(tunnel.name) zaten çalışıyor veya başlatılıyor.")
             return
        }
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
             DispatchQueue.main.async {
                 if self.tunnels.indices.contains(index) {
                     self.tunnels[index].status = .error
                     self.tunnels[index].lastError = "cloudflared yürütülebilir dosyası bulunamadı: \(self.cloudflaredExecutablePath)"
                 }
             }
            postUserNotification(identifier:"start_fail_noexec_\(tunnel.id)", title: "Başlatma Hatası: \(tunnel.name)", body: "cloudflared yürütülebilir dosyası bulunamadı.")
            return
        }

        print("▶️ Yönetilen tünel \(tunnel.name) başlatılıyor...")
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
                     print("Termination handler: Tunnel not found in list anymore: \(configPath)")
                     self.runningManagedProcesses.removeValue(forKey: configPath); return
                 }

                 let status = terminatedProcess.terminationStatus
                 let reason = terminatedProcess.terminationReason
                 print("⏹️ Yönetilen tünel \(self.tunnels[idx].name) bitti. Kod: \(status), Neden: \(reason == .exit ? "Exit" : "Signal")")
                 // if !finalOutputString.isEmpty { /* print("   Output: \(finalOutputString)") */ } // Usually logs only
                 if !finalErrorString.isEmpty { print("   Error: \(finalErrorString)") }

                 let wasStopping = self.tunnels[idx].status == .stopping
                 let wasStoppedIntentionally = self.runningManagedProcesses[configPath] == nil // If not in map, assume intentional stop

                 if self.runningManagedProcesses[configPath] != nil {
                     print("   Termination handler removing \(self.tunnels[idx].name) from running map (unexpected termination).")
                     self.runningManagedProcesses.removeValue(forKey: configPath)
                 }

                 if self.tunnels.indices.contains(idx) {
                     self.tunnels[idx].processIdentifier = nil

                     if wasStoppedIntentionally {
                         self.tunnels[idx].status = .stopped
                         self.tunnels[idx].lastError = nil
                         if !wasStopping { // Notify only if stop wasn't already in progress UI-wise
                             print("   Tünel durduruldu (termination handler).")
                             self.postUserNotification(identifier:"stopped_\(self.tunnels[idx].id)", title: "Tünel Durduruldu", body: "'\(self.tunnels[idx].name)' başarıyla durduruldu.")
                         }
                     } else { // Unintentional termination
                         self.tunnels[idx].status = .error
                         let errorMessage = finalErrorString.isEmpty ? "İşlem beklenmedik şekilde sonlandı (Kod: \(status))." : finalErrorString
                         self.tunnels[idx].lastError = errorMessage.split(separator: "\n").prefix(3).joined(separator: "\n")

                         print("   Hata: Tünel beklenmedik şekilde sonlandı.")
                         self.postUserNotification(identifier:"error_\(self.tunnels[idx].id)", title: "Tünel Hatası: \(self.tunnels[idx].name)", body: self.tunnels[idx].lastError ?? "Bilinmeyen hata.")
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
            print("   Başlatıldı. PID: \(pid)")
             DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                 guard let self = self else { return }
                 if let index = self.tunnels.firstIndex(where: { $0.id == tunnel.id }), self.tunnels[index].status == .starting {
                     if let runningProcess = self.runningManagedProcesses[configPath], runningProcess.isRunning {
                         self.tunnels[index].status = .running
                         print("   Durum güncellendi -> Çalışıyor (\(self.tunnels[index].name))")
                         self.postUserNotification(identifier:"started_\(tunnel.id)", title: "Tünel Başlatıldı", body: "'\(tunnel.name)' başarıyla başlatıldı.")
                     } else {
                         print("   Başlatma sırasında tünel sonlandı (\(self.tunnels[index].name)). Durum -> Hata.")
                         self.tunnels[index].status = .error
                         if self.tunnels[index].lastError == nil {
                             self.tunnels[index].lastError = "Başlatma sırasında işlem sonlandı."
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
                    self.tunnels[index].lastError = "İşlem başlatılamadı: \(error.localizedDescription)"
                 }
                 outputPipe.fileHandleForReading.readabilityHandler = nil // Cleanup handlers on failure
                 errorPipe.fileHandleForReading.readabilityHandler = nil
             }
            runningManagedProcesses.removeValue(forKey: configPath) // Remove if run fails
            postUserNotification(identifier:"start_fail_run_\(tunnel.id)", title: "Başlatma Hatası: \(tunnel.name)", body: "İşlem başlatılamadı: \(error.localizedDescription)")
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
                     print("⚠️ Durdurma: \(tunnel.name) işlemi haritada değil, durum düzeltiliyor -> Durduruldu")
                     self.tunnels[index].status = .stopped
                     self.tunnels[index].processIdentifier = nil
                     self.tunnels[index].lastError = nil
                 }
             }
            return
        }

        if tunnels[index].status == .stopping {
            print("ℹ️ \(tunnel.name) zaten durduruluyor.")
            return
        }

        print("🛑 Yönetilen tünel \(tunnel.name) durduruluyor...")
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
                               print("   \(tunnel.name) senkron olarak durduruldu (SIGTERM ile). Durum -> Durduruldu.")
                           } else {
                               print("   ⚠️ \(tunnel.name) senkron olarak durdurulamadı (\(timeoutInterval)s timeout). Durum -> Durduruldu (termination handler bekleniyor).")
                               // Termination handler should eventually fire and confirm.
                           }
                           // Termination handler will still fire, potentially sending a notification, but we update UI state here for sync case.
                      }
                 }
             }
        } else {
             process.terminate() // Sends SIGTERM asynchronously
             print("   Durdurma sinyali gönderildi (asenkron).")
             // Termination handler will update status and potentially send notification.
        }
    }

    // MARK: - Tunnel Creation & Config
    func createTunnel(name: String, completion: @escaping (Result<(uuid: String, jsonPath: String), Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cloudflared yürütülebilir dosyası şurada bulunamadı: \(cloudflaredExecutablePath)"])))
            return
        }
        if name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || name.isEmpty {
             completion(.failure(NSError(domain: "InputError", code: 11, userInfo: [NSLocalizedDescriptionKey: "Tünel adı boşluk içeremez ve boş olamaz."])))
             return
         }

        print("🏗️ Yeni tünel oluşturuluyor: \(name)...")
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
            print("   'tunnel create \(name)' bitti. Durum: \(status)")
            if !outputString.isEmpty { print("   Output:\n\(outputString)") }
            if !errorString.isEmpty { print("   Error:\n\(errorString)") }

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
                        print("   ✅ Tünel oluşturuldu: \(name) (UUID: \(uuid), JSON: \(absolutePath))")
                        completion(.success((uuid: uuid, jsonPath: absolutePath)))
                    } else {
                         print("   ❌ Tünel oluşturuldu ama JSON dosyası bulunamadı: \(absolutePath) (Orijinal Çıktı Yolu: \(path))")
                         completion(.failure(NSError(domain: "CloudflaredManagerError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tünel oluşturuldu ancak JSON kimlik bilgisi dosyası şurada bulunamadı:\n\(absolutePath)\n\nCloudflared çıktısını kontrol edin:\n\(outputString)"])))
                    }
                 } else {
                     completion(.failure(NSError(domain: "CloudflaredManagerError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tünel oluşturuldu ancak UUID (\(tunnelUUID ?? "yok")) veya JSON yolu (\(jsonPath ?? "yok")) çıktıda bulunamadı:\n\(outputString)"])))
                 }
            } else {
                let errorMsg = errorString.isEmpty ? "Tünel oluşturulurken bilinmeyen hata (Kod: \(status)). Cloudflare hesabınızda oturum açtınız mı?" : errorString
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }

    // createConfigFile fonksiyonunu bulun ve içini aşağıdaki gibi düzenleyin:
    func createConfigFile(configName: String, tunnelUUID: String, credentialsPath: String, hostname: String, port: String, documentRoot: String?, completion: @escaping (Result<String, Error>) -> Void) {
         print("📄 Yapılandırma dosyası oluşturuluyor: \(configName).yml")
            let fileManager = FileManager.default

            // Ensure ~/.cloudflared directory exists
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: cloudflaredDirectoryPath, isDirectory: &isDir) || !isDir.boolValue {
                 do {
                     try fileManager.createDirectory(atPath: cloudflaredDirectoryPath, withIntermediateDirectories: true, attributes: nil)
                 } catch {
                     completion(.failure(NSError(domain: "FileSystemError", code: 4, userInfo: [NSLocalizedDescriptionKey:"~/.cloudflared dizini oluşturulamadı: \(error.localizedDescription)"]))); return
                 }
             }

             var cleanConfigName = configName.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
             cleanConfigName = cleanConfigName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
             if cleanConfigName.isEmpty {
                  completion(.failure(NSError(domain: "InputError", code: 12, userInfo: [NSLocalizedDescriptionKey: "Geçersiz config dosyası adı."]))); return
             }
             let targetPath = "\(cloudflaredDirectoryPath)/\(cleanConfigName).yml"
             if fileManager.fileExists(atPath: targetPath) {
                 completion(.failure(NSError(domain: "CloudflaredManagerError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Yapılandırma dosyası zaten mevcut: \(targetPath)"]))); return
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
            print("   ✅ Yapılandırma dosyası oluşturuldu: \(targetPath)")

            // --- MAMP Güncellemeleri (DispatchGroup ile Eş Zamanlı) ---
            var vhostUpdateError: Error? = nil
            var listenUpdateError: Error? = nil
            let mampUpdateGroup = DispatchGroup() // Eş zamanlılık için

            // Sadece documentRoot varsa MAMP güncellemelerini yap
            if let docRoot = documentRoot, !docRoot.isEmpty {
                // 1. vHost Güncellemesi
                mampUpdateGroup.enter()
                updateMampVHost(serverName: hostname, documentRoot: docRoot, port: port) { result in
                    if case .failure(let error) = result {
                        vhostUpdateError = error // Hatayı sakla
                        print("⚠️ MAMP vHost güncelleme hatası: \(error.localizedDescription)")
                        // (Bildirim zaten updateMampVHost içinde gönderiliyor)
                    } else {
                        print("✅ MAMP vHost dosyası başarıyla güncellendi (veya zaten vardı).")
                    }
                    mampUpdateGroup.leave()
                }

                // 2. httpd.conf Listen Güncellemesi
                mampUpdateGroup.enter()
                updateMampHttpdConfListen(port: port) { result in
                    if case .failure(let error) = result {
                        listenUpdateError = error // Hatayı sakla
                        print("⚠️ MAMP httpd.conf Listen güncelleme hatası: \(error.localizedDescription)")
                        // (Bildirim updateMampHttpdConfListen içinde gönderiliyor, ama burada tekrar gönderebiliriz)
                         self.postUserNotification(identifier: "mamp_httpd_update_fail_\(port)", title: "MAMP httpd.conf Hatası", body: "'Listen \(port)' eklenemedi. İzinleri kontrol edin veya manuel ekleyin.\n\(error.localizedDescription)")
                    } else {
                        print("✅ MAMP httpd.conf Listen direktifi başarıyla güncellendi (veya zaten vardı).")
                    }
                    mampUpdateGroup.leave()
                }
            } else {
                 print("ℹ️ DocumentRoot belirtilmedi veya boş, MAMP yapılandırma dosyaları güncellenmedi.")
            }

            // MAMP güncellemelerinin bitmesini bekle ve sonucu bildir
            mampUpdateGroup.notify(queue: .main) { [weak self] in
                 guard let self = self else { return }
                 self.findManagedTunnels() // Listeyi yenile

                 // Genel sonucu bildir
                 if vhostUpdateError == nil && listenUpdateError == nil {
                      // Her iki MAMP güncellemesi de başarılı (veya gerekmiyordu)
                      self.postUserNotification(identifier: "config_created_\(cleanConfigName)", title: "Config Oluşturuldu", body: "'\(cleanConfigName).yml' dosyası oluşturuldu." + (documentRoot != nil ? " MAMP yapılandırması güncellendi." : ""))
                      completion(.success(targetPath))
                 } else {
                      // Config başarılı ama MAMP güncellemelerinde hata var
                      let combinedErrorDesc = [
                          vhostUpdateError != nil ? "vHost: \(vhostUpdateError!.localizedDescription)" : nil,
                          listenUpdateError != nil ? "httpd.conf: \(listenUpdateError!.localizedDescription)" : nil
                      ].compactMap { $0 }.joined(separator: "\n")

                      print("❌ Config oluşturuldu, ancak MAMP güncellemelerinde hata(lar) var.")
                      // Kullanıcıya config'in başarılı olduğunu ama MAMP için uyarıyı bildir
                      self.postUserNotification(identifier: "config_created_mamp_warn_\(cleanConfigName)", title: "Config Oluşturuldu (MAMP Uyarısı)", body: "'\(cleanConfigName).yml' oluşturuldu, ancak MAMP yapılandırması güncellenirken hata(lar) oluştu:\n\(combinedErrorDesc)\nLütfen MAMP ayarlarını manuel kontrol edin.")
                      // Yine de başarı olarak dönebiliriz, çünkü tünel ve config tamamlandı.
                      completion(.success(targetPath))
                      // VEYA Hata olarak dönmek isterseniz:
                      // let error = NSError(domain: "PartialSuccessError", code: 99, userInfo: [NSLocalizedDescriptionKey: "Config dosyası oluşturuldu, ancak MAMP güncellemelerinde hata(lar) oluştu:\n\(combinedErrorDesc)"])
                      // completion(.failure(error))
                 }
            }
        } catch {
            // .yml dosyası yazılamadıysa
            print("❌ Hata: Yapılandırma dosyası yazılamadı: \(targetPath) - \(error)")
            completion(.failure(error))
        }
    } // createConfigFile sonu

    // MARK: - Tunnel Deletion (Revised - Removing --force temporarily)
    func deleteTunnel(tunnelInfo: TunnelInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cloudflared yürütülebilir dosyası bulunamadı."]))); return
        }

        // Silme için KESİNLİKLE UUID'yi tercih et
        let identifierToDelete: String
        let idType: String
        if let uuid = tunnelInfo.uuidFromConfig, !uuid.isEmpty {
            identifierToDelete = uuid
            idType = "UUID"
        } else {
            identifierToDelete = tunnelInfo.name // Fallback to name
            idType = "Name"
            print("   ⚠️ Uyarı: Config dosyasından tünel UUID'si okunamadı, isim ('\(identifierToDelete)') ile silme deneniyor.")
        }

        // !!! --force flag'ini GEÇİCİ OLARAK KALDIRIYORUZ !!!
        print("🗑️ Tünel siliniyor (Identifier: \(identifierToDelete), Type: \(idType)) [--force KULLANILMIYOR]...")

        // Adım 1: Tüneli durdur (Senkron)
        if let configPath = tunnelInfo.configPath, runningManagedProcesses[configPath] != nil {
            print("   Silmeden önce tünel durduruluyor: \(tunnelInfo.name)")
            stopManagedTunnel(tunnelInfo, synchronous: true)
            Thread.sleep(forTimeInterval: 0.5) // Kısa bekleme
            print("   Durdurma işlemi sonrası devam ediliyor...")
        } else {
             print("   Tünel zaten çalışmıyor veya uygulama tarafından yönetilmiyor.")
        }


        // Adım 2: Silme komutunu çalıştır (--force OLMADAN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        // process.arguments = ["tunnel", "delete", identifierToDelete, "--force"] // ESKİ HALİ
        process.arguments = ["tunnel", "delete", identifierToDelete] // YENİ HALİ (--force YOK)
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe

        process.terminationHandler = { terminatedProcess in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = terminatedProcess.terminationStatus

            print("   'tunnel delete \(identifierToDelete)' [--force YOK] bitti. Çıkış Kodu: \(status)")
            if !outputString.isEmpty { print("   Output: \(outputString)") }
            if !errorString.isEmpty { print("   Error: \(errorString)") }

            // Sonucu Değerlendirme
            let lowerError = errorString.lowercased()
            let specificAmbiguityError = "there should only be 1 non-deleted tunnel named" // Bu hata hala gelebilir mi?

            if status == 0 {
                print("   ✅ Tünel başarıyla silindi (Çıkış Kodu 0): \(identifierToDelete)")
                completion(.success(()))
            }
            else if lowerError.contains("tunnel not found") || lowerError.contains("could not find tunnel") {
                print("   ℹ️ Tünel zaten silinmiş veya bulunamadı (Hata mesajı): \(identifierToDelete)")
                completion(.success(())) // Başarılı kabul et
            }
            // Eğer --force olmadan da aynı "named" hatası geliyorsa, sorun daha derinde.
            else if lowerError.contains(specificAmbiguityError) {
                 // --force olmamasına rağmen bu hatanın gelmesi çok daha tuhaf olurdu.
                 print("   ❌ Tünel silme hatası: Cloudflare tarafında isim/UUID çakışması veya başka bir tutarsızlık var (--force kullanılmadı).")
                 let errorMsg = "Tünel silinemedi çünkü Cloudflare tarafında bir tutarsızlık var (--force kullanılmadı).\n\nHata Mesajı: '\(errorString)'\n\nLütfen bu tüneli Cloudflare Dashboard üzerinden kontrol edip manuel olarak silin."
                 completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
            // Diğer tüm hatalar
            else {
                let errorMsg = errorString.isEmpty ? "Tünel silinirken bilinmeyen bir hata oluştu (Çıkış Kodu: \(status))." : errorString
                print("   ❌ Tünel silme hatası (--force kullanılmadı): \(errorMsg)")
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        } // Termination Handler Sonu

        // İşlemi Başlat
        do {
            try process.run()
        } catch {
            print("❌ 'tunnel delete' işlemi başlatılamadı: \(error)")
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
        } catch { print("⚠️ Config okuma hatası: \(filePath), \(error)") }
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
                print("   Uyarı: 'credentials-file' anahtarı config'de bulunamadı: \(configPath)")
                return nil
            }

            // Adım 1: Tilde'yi (~) genişlet (eğer varsa)
            let expandedPathString = (credentialsPathValue as NSString).expandingTildeInPath

            // Adım 2: Genişletilmiş yolu standardize et (örn: gereksiz /../ gibi kısımları temizler)
            // expandedPathString bir Swift String'i olduğu için tekrar NSString'e çeviriyoruz.
            let standardizedPath = (expandedPathString as NSString).standardizingPath

            // Adım 3: Standardize edilmiş mutlak yolun varlığını kontrol et
            if standardizedPath.hasPrefix("/") && FileManager.default.fileExists(atPath: standardizedPath) {
                // Eğer bulunduysa, standardize edilmiş yolu döndür
                return standardizedPath
            } else {
                print("   Kimlik bilgisi dosyası config'de belirtilen yolda bulunamadı: \(standardizedPath) (Orijinal: '\(credentialsPathValue)', Config: \(configPath))")

                // --- Fallback (Eğer mutlak yol çalışmazsa, nadiren ihtiyaç duyulur) ---
                // ~/.cloudflared dizinine göreceli yolu kontrol et
                let pathInCloudflaredDir = cloudflaredDirectoryPath.appending("/").appending(credentialsPathValue)
                let standardizedRelativePath = (pathInCloudflaredDir as NSString).standardizingPath // Bunu da standardize et
                if FileManager.default.fileExists(atPath: standardizedRelativePath) {
                    print("   Fallback: Kimlik bilgisi dosyası ~/.cloudflared içinde bulundu: \(standardizedRelativePath)")
                    return standardizedRelativePath
                }
                // --- Fallback Sonu ---

                return nil // Hiçbir yerde bulunamadı
            }
        }


    // Finds the first hostname listed in the ingress rules
    func findHostname(for configPath: String) -> String? {
         return parseValueFromYaml(key: "hostname", filePath: configPath)
    }

    // MARK: - DNS Routing
    func routeDns(tunnelInfo: TunnelInfo, hostname: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cloudflared bulunamadı."]))); return
        }
        guard !hostname.isEmpty && hostname.contains(".") && hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
             completion(.failure(NSError(domain: "InputError", code: 13, userInfo: [NSLocalizedDescriptionKey: "Geçersiz hostname formatı."])))
             return
        }

        let tunnelIdentifier = tunnelInfo.uuidFromConfig ?? tunnelInfo.name
        print("🔗 DNS yönlendiriliyor: \(tunnelIdentifier) -> \(hostname)...")
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

            print("   'tunnel route dns' bitti. Durum: \(status)")
            if !outputString.isEmpty { print("   Output: \(outputString)") }
            if !errorString.isEmpty { print("   Error: \(errorString)") }

            if status == 0 {
                if errorString.lowercased().contains("already exists") || outputString.lowercased().contains("already exists") {
                     completion(.success("Başarılı: DNS kaydı zaten mevcut veya güncellendi.\n\(outputString)"))
                } else {
                     completion(.success(outputString.isEmpty ? "DNS yönlendirmesi başarıyla eklendi/güncellendi." : outputString))
                }
            } else {
                let errorMsg = errorString.isEmpty ? "DNS yönlendirme hatası (Kod: \(status)). Alan adınız Cloudflare'de mi?" : errorString
                completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
            }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }
    
    
    
    // TunnelManager sınıfının içine, tercihen updateMampVHost fonksiyonunun yakınına ekleyin:
    private func updateMampHttpdConfListen(port: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let portInt = Int(port), (1...65535).contains(portInt) else {
            completion(.failure(NSError(domain: "HttpdConfError", code: 30, userInfo: [NSLocalizedDescriptionKey: "Geçersiz Port Numarası: \(port)"])))
            return
        }
        let listenDirective = "Listen \(port)" // Örn: "Listen 8080"
        let httpdPath = mampHttpdConfPath

        guard FileManager.default.fileExists(atPath: httpdPath) else {
            completion(.failure(NSError(domain: "HttpdConfError", code: 31, userInfo: [NSLocalizedDescriptionKey: "MAMP httpd.conf dosyası bulunamadı: \(httpdPath)"])))
            return
        }

        // Yazma iznini kontrol et (en azından üst dizine)
        guard FileManager.default.isWritableFile(atPath: httpdPath) else {
             completion(.failure(NSError(domain: "HttpdConfError", code: 32, userInfo: [NSLocalizedDescriptionKey: "Yazma izni hatası: MAMP httpd.conf dosyası güncellenemedi (\(httpdPath)). İzinleri kontrol edin."])))
             return
        }

        do {
            var currentContent = try String(contentsOfFile: httpdPath, encoding: .utf8)

            // Direktifin zaten var olup olmadığını kontrol et (yorum satırları hariç)
            // Regex: Satır başında boşluk olabilir, sonra "Listen", sonra boşluk, sonra port numarası, sonra boşluk veya satır sonu.
            let pattern = #"^\s*Listen\s+\#(portInt)\s*(?:#.*)?$"#
            if currentContent.range(of: pattern, options: .regularExpression) != nil {
                print("ℹ️ MAMP httpd.conf zaten '\(listenDirective)' içeriyor.")
                completion(.success(()))
                return
            }

            // Ekleme noktasını bul: Son "Listen" satırının sonrasını hedefle
            var insertionPoint = currentContent.endIndex
            // Desen: Satır başı, boşluk olabilir, "Listen", boşluk, RAKAMLAR.
            let lastListenPattern = #"^\s*Listen\s+\d+"#
            // Sondan başlayarak ara
            if let lastListenMatchRange = currentContent.range(of: lastListenPattern, options: [.regularExpression, .backwards]) {
                // Bulunan satırın sonunu bul
                if let lineEndRange = currentContent.range(of: "\n", options: [], range: lastListenMatchRange.upperBound..<currentContent.endIndex) {
                    insertionPoint = lineEndRange.upperBound // Sonraki satırın başı
                } else {
                    // Dosyanın son satırıysa, sona eklemeden önce newline ekle
                    if !currentContent.hasSuffix("\n") { currentContent += "\n" }
                    insertionPoint = currentContent.endIndex
                }
            } else {
                // Hiç "Listen" bulunamazsa (çok nadir), dosyanın sonuna ekle
                print("⚠️ MAMP httpd.conf içinde 'Listen' direktifi bulunamadı. Sona ekleniyor.")
                if !currentContent.hasSuffix("\n") { currentContent += "\n" }
                insertionPoint = currentContent.endIndex
            }

            // Eklenecek içeriği hazırla
            let contentToInsert = "\n# Added by Cloudflared Manager App for port \(port)\n\(listenDirective)\n"
            currentContent.insert(contentsOf: contentToInsert, at: insertionPoint)

            // Değiştirilmiş içeriği dosyaya yaz
            try currentContent.write(toFile: httpdPath, atomically: true, encoding: .utf8)
            print("✅ MAMP httpd.conf güncellendi: '\(listenDirective)' direktifi eklendi.")

            // Kullanıcıyı bilgilendir (MAMP yeniden başlatma hatırlatması)
            postUserNotification(
                identifier: "mamp_httpd_listen_added_\(port)",
                title: "MAMP httpd.conf Güncellendi",
                body: "'\(listenDirective)' direktifi eklendi. Ayarların etkili olması için MAMP sunucularını yeniden başlatmanız gerekebilir."
            )
            completion(.success(()))

        } catch {
            print("❌ MAMP httpd.conf güncellenirken HATA: \(error)")
            // Hata detayını completion'a ilet
            completion(.failure(NSError(domain: "HttpdConfError", code: 33, userInfo: [NSLocalizedDescriptionKey: "MAMP httpd.conf okuma/yazma hatası: \(error.localizedDescription)"])))
        }
    }

    // MARK: - Cloudflare Login
    func cloudflareLogin(completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cloudflared bulunamadı."]))); return
        }
        print("🔑 Cloudflare girişi başlatılıyor (Tarayıcı açılacak)...")

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
             print("   'cloudflared login' bitti. Durum: \(status)")
             if !outputString.isEmpty { print("   Output:\n\(outputString)") }
             if !errorString.isEmpty { print("   Error:\n\(errorString)") }

             if status == 0 {
                 if outputString.contains("You have successfully logged in") || outputString.contains("already logged in") {
                     print("   ✅ Giriş başarılı veya zaten yapılmış.")
                     completion(.success(()))
                 } else {
                     print("   Giriş işlemi başlatıldı, tarayıcıda devam edin.")
                     completion(.success(())) // Assume user needs to interact with browser
                 }
             } else {
                 let errorMsg = errorString.isEmpty ? "Cloudflare girişinde bilinmeyen hata (Kod: \(status))" : errorString
                 completion(.failure(NSError(domain: "CloudflaredCLIError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])))
             }
         }
        do {
             try process.run()
             print("   Tarayıcıda Cloudflare giriş sayfası açılmalı veya zaten giriş yapılmış.")
         } catch {
             print("❌ Cloudflare giriş işlemi başlatılamadı: \(error)")
             completion(.failure(error))
         }
    }

     // MARK: - Quick Tunnel Management (Revised URL Detection)
    func startQuickTunnel(localURL: String, completion: @escaping (Result<UUID, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: cloudflaredExecutablePath) else {
            completion(.failure(NSError(domain: "CloudflaredManagerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cloudflared bulunamadı: \(cloudflaredExecutablePath)"]))); return
        }
        guard let url = URL(string: localURL), url.scheme != nil, url.host != nil else {
            completion(.failure(NSError(domain: "InputError", code: 10, userInfo: [NSLocalizedDescriptionKey: "Geçersiz yerel URL formatı. (örn: http://localhost:8000)"]))); return
        }

        print("🚀 Hızlı tünel başlatılıyor (Basit Arg): \(localURL)...")
        let process = Process()
        let tunnelID = UUID()

        process.executableURL = URL(fileURLWithPath: cloudflaredExecutablePath)
        process.arguments = ["tunnel", "--url", localURL] // Basit argümanlar

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
                    // Sadece URL parse etmeyi dene, hata arama yok.
                    self.parseQuickTunnelOutput(outputBuffer: combinedOutputBuffer, tunnelID: tunnelID)
                    bufferLock.unlock()
                }
            }
        }

        // Handler'ları ayarla
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
                         print("🏁 Hızlı tünel (\(tunnelID) - \(localURL)) sonlandı. Kod: \(status), Neden: \(reason == .exit ? "Exit" : "Signal")")
                        // if !finalCombinedOutput.isEmpty { print("   🏁 Son Buffer [\(tunnelID)]:\n---\n\(finalCombinedOutput)\n---") }

                         guard let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }) else {
                             print("   Termination handler: Quick tunnel \(tunnelID) listede bulunamadı.")
                             self.runningQuickProcesses.removeValue(forKey: tunnelID)
                             return
                         }

                         var tunnelData = self.quickTunnels[index]
                         let urlWasFound = tunnelData.publicURL != nil
                         let wasStoppedIntentionally = self.runningQuickProcesses[tunnelID] == nil || (reason == .exit && status == 0) || (reason == .uncaughtSignal && status == SIGTERM)

                         // Hata Durumu: Sadece URL bulunamadıysa VE beklenmedik şekilde sonlandıysa
                         if !urlWasFound && !wasStoppedIntentionally && !(reason == .exit && status == 0) {
                             print("   ‼️ Hızlı Tünel: URL bulunamadı ve beklenmedik şekilde sonlandı [\(tunnelID)].")
                             let errorLines = finalCombinedOutput.split(separator: "\n").filter {
                                 $0.lowercased().contains("error") || $0.lowercased().contains("fail") || $0.lowercased().contains("fatal")
                             }.map(String.init)
                             var finalError = errorLines.prefix(3).joined(separator: "\n")
                             if finalError.isEmpty {
                                 finalError = "İşlem URL bulunamadan sonlandı (Kod: \(status)). Çıktıyı kontrol edin."
                             }
                             tunnelData.lastError = finalError // Hatayı ayarla
                             print("   Hata mesajı ayarlandı: \(finalError)")
                             // Hata bildirimi
                             self.postUserNotification(identifier: "quick_fail_\(tunnelID)", title: "Hızlı Tünel Hatası", body: "\(localURL)\n\(finalError.prefix(100))...")
                         } else if wasStoppedIntentionally {
                              print("   Hızlı tünel durduruldu veya normal sonlandı (\(tunnelID)).")
                              // Başarılı durdurma bildirimi (URL bulunduysa veya temiz çıkışsa)
                              if urlWasFound || (reason == .exit && status == 0) {
                                  self.postUserNotification(identifier: "quick_stopped_\(tunnelID)", title: "Hızlı Tünel Durduruldu", body: "\(localURL)")
                              }
                         }
                         // else: URL bulundu ve normal şekilde çalışmaya devam ediyordu (kapatma sinyali gelene kadar) - hata yok.

                         // Listeden ve haritadan kaldır
                         self.quickTunnels.remove(at: index)
                         self.runningQuickProcesses.removeValue(forKey: tunnelID)
                     }
                 }



        // --- İşlemi başlatma kısmı ---
              do {
                  DispatchQueue.main.async {
                       // Başlangıçta lastError = nil olsun
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
                       print("   Hızlı tünel işlemi başlatıldı (PID: \(pid), ID: \(tunnelID)). Çıktı bekleniyor...")
                       completion(.success(tunnelID))
                  }

        } catch {
            print("❌ Hızlı tünel işlemi başlatılamadı (try process.run() hatası): \(error)")
            // Başlatma sırasında hata olursa temizle
            DispatchQueue.main.async {
                     self.quickTunnels.removeAll { $0.id == tunnelID }
                     self.runningQuickProcesses.removeValue(forKey: tunnelID)
                     self.postUserNotification(identifier: "quick_start_run_fail_\(tunnelID)", title: "Hızlı Tünel Başlatma Hatası", body: "İşlem başlatılamadı: \(error.localizedDescription)")
                     completion(.failure(error))
                }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
           }
       } /// startQuickTunnel Sonu


    // Sadece URL arar, hata aramaz. URL bulursa durumu günceller.
    private func parseQuickTunnelOutput(outputBuffer: String, tunnelID: UUID) {
        var urlAlreadyFound = false
        DispatchQueue.main.sync {
            urlAlreadyFound = self.quickTunnels.first(where: { $0.id == tunnelID })?.publicURL != nil
        }
        guard !urlAlreadyFound else { return } // Zaten bulunduysa çık

        // URL Arama
               let urlPattern = #"(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
               let establishedPattern = #"Tunnel established at\s+(\S+)"# // Veya "Visit it at ... URL" satırı
               let visitPattern = #"Visit it at.*(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
               var foundURL: String? = nil

               // Önce "established at" veya "Visit it at" satırlarını ara
               if let establishedMatch = outputBuffer.range(of: establishedPattern, options: .regularExpression) {
                    if let urlRange = outputBuffer.range(of: urlPattern, options: .regularExpression, range: establishedMatch) {
                        foundURL = String(outputBuffer[urlRange])
                    }
               } else if let visitMatch = outputBuffer.range(of: visitPattern, options: .regularExpression) {
                    // Regex'in yakaladığı 1. grup URL'dir
                    let matchString = String(outputBuffer[visitMatch])
                    if let urlRange = matchString.range(of: urlPattern, options: .regularExpression) {
                         foundURL = String(matchString[urlRange])
                    }
               }

        // URL Bulunduysa -> Durumu Güncelle (Ana Thread'de)
        if let theURL = foundURL {
            DispatchQueue.main.async {
                if let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }), self.quickTunnels[index].publicURL == nil {
                    self.quickTunnels[index].publicURL = theURL
                    self.quickTunnels[index].lastError = nil // Hata olmadığından emin ol
                    print("   ☁️ Hızlı Tünel URL'si (\(tunnelID)): \(theURL)")
                    self.postUserNotification(identifier: "quick_url_\(tunnelID)", title: "Hızlı Tünel Hazır", body: "\(self.quickTunnels[index].localURL)\n⬇️\n\(theURL)")
                }
            }
            // URL bulunduktan sonra bu fonksiyondan çık (artık parse etmeye gerek yok)
        }

        // --- Hata Arama (Sadece URL bulunamadıysa buraya gelinir) ---
        let errorPatterns = [
            "error", "fail", "fatal", "cannot", "unable", "could not", "refused", "denied",
            "address already in use", "invalid tunnel credentials", "dns record creation failed"
        ]
        var detectedError: String? = nil
        for errorPattern in errorPatterns {
             // Tüm buffer'da hata deseni ara
             if outputBuffer.lowercased().range(of: errorPattern) != nil {
                 // Buffer'daki *son* ilgili satırı bulmaya çalış (daha anlamlı olabilir)
                 let errorLine = outputBuffer.split(separator: "\n").last(where: { $0.lowercased().contains(errorPattern) })
                 detectedError = String(errorLine ?? Substring("Hata algılandı: \(errorPattern)")).prefix(150).trimmingCharacters(in: .whitespacesAndNewlines)
                 // print("   ‼️ Hata Deseni Algılandı [\(tunnelID)]: '\(errorPattern)' -> Mesaj: \(detectedError!)") // İsteğe bağlı debug logu
                 break // İlk bulunan hatayı al ve çık
             }
        }

        // Eğer hata algılandıysa, ana thread'de durumu güncelle
        if let finalError = detectedError {
            DispatchQueue.main.async {
                // URL'nin hala bulunmadığından emin ol
                if let index = self.quickTunnels.firstIndex(where: { $0.id == tunnelID }), self.quickTunnels[index].publicURL == nil {
                    // Sadece mevcut hata boşsa veya 'Başlatılıyor...' ise güncelle
                    if self.quickTunnels[index].lastError == nil || self.quickTunnels[index].lastError == "Başlatılıyor..." {
                         self.quickTunnels[index].lastError = finalError
                         print("   Hızlı Tünel Başlatma Hatası Güncellendi (\(tunnelID)): \(finalError)")
                    }
                }
            }
        }
    } 

     func stopQuickTunnel(id: UUID) {
         DispatchQueue.main.async { // Ensure access to quickTunnels and runningQuickProcesses is synchronized
              guard let process = self.runningQuickProcesses[id] else {
                  print("❓ Durdurulacak hızlı tünel işlemi bulunamadı: \(id)")
                  if let index = self.quickTunnels.firstIndex(where: { $0.id == id }) {
                      print("   Listeden de kaldırılıyor.")
                      self.quickTunnels.remove(at: index) // Remove lingering data if process gone
                  }
                  return
              }

              guard let tunnelData = self.quickTunnels.first(where: { $0.id == id }) else {
                   print("❓ Durdurulacak hızlı tünel verisi bulunamadı (process var ama veri yok): \(id)")
                   self.runningQuickProcesses.removeValue(forKey: id)
                   process.terminate() // Terminate process anyway
                   return
              }

              print("🛑 Hızlı tünel durduruluyor: \(tunnelData.localURL) (\(id)) PID: \(process.processIdentifier)")
              // Remove from map *before* terminating to signal intent
              self.runningQuickProcesses.removeValue(forKey: id)
              process.terminate() // Send SIGTERM
              // Termination handler will remove it from the `quickTunnels` array and send notification.
          }
     }

    // MARK: - Bulk Actions
    func startAllManagedTunnels() {
        print("--- Tüm Yönetilenleri Başlat ---")
         DispatchQueue.main.async {
             let tunnelsToStart = self.tunnels.filter { $0.isManaged && ($0.status == .stopped || $0.status == .error) }
             if tunnelsToStart.isEmpty { print("   Başlatılacak yönetilen tünel yok."); return }
             print("   Başlatılacak tüneller: \(tunnelsToStart.map { $0.name })")
             tunnelsToStart.forEach { self.startManagedTunnel($0) }
         }
    }

    func stopAllTunnels(synchronous: Bool = false) {
        print("--- Tüm Tünelleri Durdur (\(synchronous ? "Senkron" : "Asenkron")) ---")
        var didStopSomething = false

        DispatchQueue.main.async { // Ensure array/dict access is safe
            // Stop Managed Tunnels
            let configPathsToStop = Array(self.runningManagedProcesses.keys)
            if !configPathsToStop.isEmpty {
                print("   Yönetilen tüneller durduruluyor...")
                for configPath in configPathsToStop {
                    if let tunnelInfo = self.tunnels.first(where: { $0.configPath == configPath }) {
                        self.stopManagedTunnel(tunnelInfo, synchronous: synchronous)
                        didStopSomething = true
                    } else {
                        print("⚠️ Çalışan process (\(configPath)) listede değil, yine de durduruluyor...")
                        if let process = self.runningManagedProcesses.removeValue(forKey: configPath) {
                            if synchronous { _ = self.stopProcessAndWait(process, timeout: 2.0) } else { process.terminate() }
                            didStopSomething = true
                        }
                    }
                }
                if synchronous { print("--- Senkron yönetilen durdurmalar tamamlandı (veya sinyal gönderildi) ---") }
            } else {
                print("   Çalışan yönetilen tünel yok.")
                 // Ensure UI consistency
                 self.tunnels.indices.filter{ self.tunnels[$0].isManaged && [.running, .stopping, .starting].contains(self.tunnels[$0].status) }
                                   .forEach { idx in
                                       self.tunnels[idx].status = .stopped; self.tunnels[idx].processIdentifier = nil; self.tunnels[idx].lastError = nil
                                   }
            }

            // Stop Quick Tunnels (Always Asynchronous via stopQuickTunnel)
            let quickTunnelIDsToStop = Array(self.runningQuickProcesses.keys)
            if !quickTunnelIDsToStop.isEmpty {
                print("   Hızlı tüneller durduruluyor...")
                for id in quickTunnelIDsToStop {
                    self.stopQuickTunnel(id: id)
                    didStopSomething = true
                }
            } else {
                 print("   Çalışan hızlı tünel yok.")
                 // Ensure UI consistency
                 if !self.quickTunnels.isEmpty {
                     print("   ⚠️ Çalışan hızlı tünel işlemi yok ama listede eleman var, temizleniyor.")
                     self.quickTunnels.removeAll()
                 }
            }

            if didStopSomething {
                 // Send notification after a brief delay to allow termination handlers to potentially run
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                      let title = "Tüm Tüneller Durduruldu"
                      let body = synchronous ? "(Senkron durdurma denendi)" : nil
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
                         print("🔄 Durum düzeltildi (Check): \(currentTunnelState.name) (\(currentTunnelState.status.displayName)) -> Çalışıyor")
                         self.tunnels[index].status = .running
                         self.tunnels[index].processIdentifier = process.processIdentifier
                         self.tunnels[index].lastError = nil
                     } else if currentTunnelState.status == .running && currentTunnelState.processIdentifier != process.processIdentifier {
                          print("🔄 PID düzeltildi (Check): \(currentTunnelState.name) \(currentTunnelState.processIdentifier ?? -1) -> \(process.processIdentifier)")
                          self.tunnels[index].processIdentifier = process.processIdentifier
                     }
                 } else { // Process in map but not running (unexpected termination)
                     print("⚠️ Kontrol: \(currentTunnelState.name) işlemi haritada ama çalışmıyor! Termination handler bunu yakalamalıydı. Temizleniyor.")
                     self.runningManagedProcesses.removeValue(forKey: configPath)
                     if currentTunnelState.status == .running || currentTunnelState.status == .starting {
                         self.tunnels[index].status = .error
                         if self.tunnels[index].lastError == nil { self.tunnels[index].lastError = "İşlem beklenmedik şekilde sonlandı (haritada bulundu ama çalışmıyor)." }
                         print("   Durum -> Hata (Check)")
                     } else if currentTunnelState.status == .stopping {
                         self.tunnels[index].status = .stopped
                          print("   Durum -> Durduruldu (Check)")
                     }
                     self.tunnels[index].processIdentifier = nil
                 }
             } else { // Process not in map
                 if currentTunnelState.status == .running || currentTunnelState.status == .starting || currentTunnelState.status == .stopping {
                     print("🔄 Durum düzeltildi (Check): \(currentTunnelState.name) işlemi haritada yok -> Durduruldu")
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
             print("❌ İzleme başlatılamadı: Dizin yok veya dizin değil - \(url.path)")
             findManagedTunnels() // Try to create it
             // Consider retrying monitoring setup later if needed
             return
        }
        let fileDescriptor = Darwin.open((url as NSURL).fileSystemRepresentation, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("❌ Hata: \(cloudflaredDirectoryPath) izleme için açılamadı. Errno: \(errno) (\(String(cString: strerror(errno))))"); return
        }

        directoryMonitor?.cancel()
        directoryMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: DispatchQueue.global(qos: .utility))

        directoryMonitor?.setEventHandler { [weak self] in
            self?.monitorDebounceTimer?.invalidate()
            self?.monitorDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                print("📂 Değişiklik algılandı: \(self?.cloudflaredDirectoryPath ?? "") -> Yönetilen Tünel listesi yenileniyor.")
                 DispatchQueue.main.async { self?.findManagedTunnels() }
            }
             if let timer = self?.monitorDebounceTimer { RunLoop.main.add(timer, forMode: .common) }
        }

        directoryMonitor?.setCancelHandler { close(fileDescriptor) }
        directoryMonitor?.resume()
        print("👀 Dizin izleme başlatıldı: \(cloudflaredDirectoryPath)")
    }

    func stopMonitoringCloudflaredDirectory() {
        monitorDebounceTimer?.invalidate(); monitorDebounceTimer = nil
        if directoryMonitor != nil {
             print("🛑 Dizin izleme durduruluyor: \(cloudflaredDirectoryPath)")
             directoryMonitor?.cancel(); directoryMonitor = nil
        }
    }

     // MARK: - MAMP Integration Helpers
     func scanMampSitesFolder() -> [String] {
         guard FileManager.default.fileExists(atPath: mampSitesDirectoryPath) else {
             print("❌ MAMP site dizini bulunamadı: \(mampSitesDirectoryPath)")
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
         } catch { print("❌ MAMP site dizini taranamadı: \(mampSitesDirectoryPath) - \(error)") }
         return siteFolders.sorted()
     }

    // updateMampVHost fonksiyonunu tamamen değiştirin
    // updateMampVHost fonksiyonunu tamamen değiştirin (Hata düzeltmesi dahil)
    func updateMampVHost(serverName: String, documentRoot: String, port: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard FileManager.default.fileExists(atPath: documentRoot) else {
            completion(.failure(NSError(domain: "VHostError", code: 20, userInfo: [NSLocalizedDescriptionKey: "DocumentRoot bulunamadı: \(documentRoot)"]))); return
        }
        guard !serverName.isEmpty && serverName.contains(".") else {
            completion(.failure(NSError(domain: "VHostError", code: 21, userInfo: [NSLocalizedDescriptionKey: "Geçersiz ServerName: \(serverName)"]))); return
        }
        // Port numarasının geçerli olup olmadığını kontrol et (ekstra güvenlik)
        guard let portInt = Int(port), (1...65535).contains(portInt) else {
            completion(.failure(NSError(domain: "VHostError", code: 25, userInfo: [NSLocalizedDescriptionKey: "Geçersiz Port Numarası: \(port)"]))); return
        }
        let listenDirective = "*:\(port)" // Dinleme direktifini oluştur

        let vhostDir = (mampVHostConfPath as NSString).deletingLastPathComponent
        var isDir : ObjCBool = false
        if !FileManager.default.fileExists(atPath: vhostDir, isDirectory: &isDir) || !isDir.boolValue {
            print("⚠️ MAMP vHost dizini bulunamadı, oluşturuluyor: \(vhostDir)")
            do { try FileManager.default.createDirectory(atPath: vhostDir, withIntermediateDirectories: true, attributes: nil) } catch {
                 completion(.failure(NSError(domain: "VHostError", code: 22, userInfo: [NSLocalizedDescriptionKey: "MAMP vHost dizini oluşturulamadı: \(vhostDir)\n\(error.localizedDescription)"]))); return
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
                print("⚠️ vHost dosyası bulunamadı, yeni dosya oluşturulacak: \(mampVHostConfPath)")
                // Yeni dosya oluşturuluyorsa NameVirtualHost direktifini ekle
                currentContent = "# Virtual Hosts\nNameVirtualHost \(listenDirective)\n\n"
            }

            // --- BAŞLANGIÇ: Düzeltilmiş vHost Var mı Kontrolü ---
            let serverNamePattern = #"ServerName\s+\Q\#(serverName)\E"#
            // Noktanın yeni satırları da eşleştirmesi için (?s) flag'i yerine NSRegularExpression kullanıyoruz.
            // Desen: <VirtualHost *:PORT> ... ServerName SERVER ... </VirtualHost>
            let vhostBlockPattern = #"<VirtualHost\s+\*\:\#(port)>.*?\#(serverNamePattern).*?</VirtualHost>"#

            do {
                // NSRegularExpression oluştur, .dotMatchesLineSeparators seçeneği ile
                let regex = try NSRegularExpression(
                    pattern: vhostBlockPattern,
                    options: [.dotMatchesLineSeparators] // Bu seçenek NSRegularExpression'da mevcut
                )

                // Tüm içerikte ara
                let searchRange = NSRange(currentContent.startIndex..<currentContent.endIndex, in: currentContent)
                if regex.firstMatch(in: currentContent, options: [], range: searchRange) != nil {
                    // Eşleşme bulunduysa, giriş zaten var demektir.
                    print("ℹ️ MAMP vHost dosyası zaten '\(serverName)' için \(listenDirective) portunda giriş içeriyor. Güncelleme yapılmadı.")
                    completion(.success(()))
                    return // Fonksiyondan çık
                }
                // Eşleşme bulunamadı, devam et...
            } catch {
                // Regex oluşturma hatası (desen bozuksa olabilir, ama burada pek olası değil)
                print("❌ Regex Hatası: \(error.localizedDescription) - Desen: \(vhostBlockPattern)")
                completion(.failure(NSError(domain: "VHostError", code: 26, userInfo: [NSLocalizedDescriptionKey: "vHost kontrolü için regex oluşturulamadı: \(error.localizedDescription)"])))
                return
            }
            // --- BİTİŞ: Düzeltilmiş vHost Var mı Kontrolü ---


            // Eğer NameVirtualHost direktifi eksikse ve dosya boş değilse, ekle
            if !currentContent.contains("NameVirtualHost \(listenDirective)") && !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentContent.contains("NameVirtualHost ") { // Hiç NameVirtualHost yoksa
                    currentContent = "# Virtual Hosts\nNameVirtualHost \(listenDirective)\n\n" + currentContent
                } else {
                    print("⚠️ Uyarı: vHost dosyasında başka NameVirtualHost direktifleri var. '\(listenDirective)' için direktif eklenmiyor. Manuel kontrol gerekebilir.")
                }
            }


            let newContent = currentContent + vhostEntry
            try newContent.write(toFile: mampVHostConfPath, atomically: true, encoding: .utf8)
            print("✅ MAMP vHost dosyası güncellendi: \(mampVHostConfPath) (Port: \(port))")
            completion(.success(()))

        } catch {
            print("❌ MAMP vHost dosyası güncellenirken HATA: \(error)")
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
                 completion(.failure(NSError(domain: "VHostError", code: 23, userInfo: [NSLocalizedDescriptionKey: "Yazma izni hatası: MAMP vHost dosyası güncellenemedi (\(mampVHostConfPath)). Lütfen dosya izinlerini kontrol edin veya manuel olarak ekleyin.\n\(error.localizedDescription)"])))
            } else {
                 completion(.failure(NSError(domain: "VHostError", code: 24, userInfo: [NSLocalizedDescriptionKey: "MAMP vHost dosyasına yazılamadı:\n\(error.localizedDescription)"])))
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
                 print("Oturum açıldığında başlatma: \(newStateEnabled ? "Etkinleştiriliyor" : "Devre Dışı Bırakılıyor")")

                 if newStateEnabled {
                     try service.register()
                 } else {
                     try service.unregister()
                 }
                 // Verify state *after* operation
                 let finalStateEnabled = SMAppService.mainApp.status == .enabled
                 if finalStateEnabled == newStateEnabled {
                     print("   ✅ Oturum açıldığında başlatma durumu güncellendi: \(finalStateEnabled)")
                     completion(.success(finalStateEnabled))
                 } else {
                      print("❌ Oturum açıldığında başlatma durumu değiştirilemedi (beklenen: \(newStateEnabled), sonuç: \(finalStateEnabled)).")
                      completion(.failure(NSError(domain: "ServiceManagement", code: -1, userInfo: [NSLocalizedDescriptionKey: "İşlem sonrası durum doğrulaması başarısız oldu."])))
                 }
             } catch {
                 print("❌ Oturum açıldığında başlatma değiştirilemedi: \(error)")
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
