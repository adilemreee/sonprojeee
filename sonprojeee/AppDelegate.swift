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
            if let image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "Cloudflared Tunnels") {
                button.image = image
                button.imagePosition = .imageLeading
            } else {
                button.title = "CfT" // Fallback text
                print("⚠️ SF Symbol 'cloud.fill' bulunamadı. Metin kullanılıyor.")
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
        print("Uygulama kapanıyor...")
        NotificationCenter.default.removeObserver(self) // Clean up observer
        tunnelManager?.stopMonitoringCloudflaredDirectory()
        // Stop all tunnels synchronously during shutdown
        tunnelManager?.stopAllTunnels(synchronous: true)
        print("Kapanış işlemleri tamamlandı.")
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
            print("⚠️ Geçersiz kullanıcı bildirimi alındı.")
            return
        }
        sendUserNotification(identifier: identifier, title: title, body: body)
    }
    
    // MARK: - User Notifications (Sending & Receiving System Notifications)
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error = error { print("❌ Bildirim izni hatası: \(error.localizedDescription)") }
                else { print(granted ? "✅ Bildirim izni verildi." : "🚫 Bildirim izni reddedildi.") }
            }
        }
    }
    
    // Sends the actual system notification
    func sendUserNotification(identifier: String = UUID().uuidString, title: String, body: String) {
        // TODO: Add UserDefaults check for global/specific notification toggles if needed
        // guard UserDefaults.standard.bool(forKey: "enableNotifications_\(identifier_type)") ?? true else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        // content.categoryIdentifier = "TUNNEL_ACTIONS" // Optional for grouping/actions
        
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DispatchQueue.main.async { // Print on main thread
                    print("❌ Bildirim gönderilemedi: \(identifier) - \(error.localizedDescription)")
                }
            }
        }
    }
    
    // UNUserNotificationCenterDelegate: Handle user interaction with notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        print("Bildirim yanıtı alındı: \(identifier)")
        
        NSApp.activate(ignoringOtherApps: true) // Bring app to front
        
        // --- Handle Specific Notification Actions ---
        if identifier == "cloudflared_not_found" {
            openSettingsWindowAction() // Open settings if executable not found notification clicked
        }
        else if identifier.starts(with: "quick_url_") {
            // Copy URL if quick tunnel ready notification clicked
            let body = response.notification.request.content.body
            if let url = extractTryCloudflareURL(from: body) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                sendUserNotification(identifier: "url_copied_from_notif_\(UUID().uuidString)", title: "URL Kopyalandı", body: url)
            }
        }
        else if identifier.starts(with: "vhost_success_") {
            // Optionally offer to open MAMP config folder
            askToOpenMampConfigFolder()
        }
        // Add more handlers as needed...
        
        completionHandler()
    }
    
    // Helper to extract URL from notification body
    private func extractTryCloudflareURL(from text: String) -> String? {
        let pattern = #"(https?://[a-zA-Z0-9-]+.trycloudflare.com)"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }
    
    // MARK: - Menu Construction
    @objc func constructMenu() {
        guard let tunnelManager = tunnelManager else {
            // Fallback menu if TunnelManager fails to initialize
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Hata: Yönetici başlatılamadı", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.menu = menu
            return
        }
        
        let menu = NSMenu()
        let isCloudflaredAvailable = FileManager.default.fileExists(atPath: tunnelManager.cloudflaredExecutablePath)
        
        // --- Cloudflared Status / Login ---
        if !isCloudflaredAvailable {
            let item = NSMenuItem(title: "❗️ cloudflared bulunamadı!", action: #selector(openSettingsWindowAction), keyEquivalent: "")
            item.target = self
            item.toolTip = "Lütfen Ayarlar'dan cloudflared yolunu düzeltin."
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        } else {
            let loginItem = NSMenuItem(title: "Cloudflare Girişi Yap / Kontrol Et...", action: #selector(cloudflareLoginAction), keyEquivalent: "")
            loginItem.target = self
            menu.addItem(loginItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // --- Quick Tunnels Section ---
        let quickTunnels = tunnelManager.quickTunnels // Read on main thread
        if !quickTunnels.isEmpty {
            menu.addItem(withTitle: "Hızlı Tüneller", action: nil, keyEquivalent: "").isEnabled = false
            for quickTunnelData in quickTunnels {
                let displayTitle: String
                var toolTip = "Yerel: \(quickTunnelData.localURL)"
                if let url = quickTunnelData.publicURL {
                    displayTitle = "🔗 \(url.replacingOccurrences(of: "https://", with: ""))"
                    toolTip += "\nGenel: \(url)\n(Kopyalamak için tıkla)"
                } else if let error = quickTunnelData.lastError {
                    displayTitle = "❗️ \(quickTunnelData.localURL) (Hata)"
                    toolTip += "\nHata: \(error)"
                } else { // Starting or waiting
                    displayTitle = "⏳ \(quickTunnelData.localURL) (Başlatılıyor/Bekleniyor...)"
                    toolTip += "\n(URL bekleniyor...)"
                }
                if let pid = quickTunnelData.processIdentifier { toolTip += "\nPID: \(pid)" }
                
                let quickItem = NSMenuItem(title: displayTitle, action: #selector(copyQuickTunnelURLAction(_:)), keyEquivalent: "")
                quickItem.target = self
                quickItem.representedObject = quickTunnelData
                quickItem.toolTip = toolTip
                quickItem.isEnabled = (quickTunnelData.publicURL != nil) // Enable copy only if URL exists
                
                let subMenu = NSMenu()
                let stopQuickItem = NSMenuItem(title: "Bu Hızlı Tüneli Durdur", action: #selector(stopQuickTunnelAction(_:)), keyEquivalent: "")
                stopQuickItem.target = self
                stopQuickItem.representedObject = quickTunnelData.id // Pass ID
                subMenu.addItem(stopQuickItem)
                quickItem.submenu = subMenu
                menu.addItem(quickItem)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        // --- Managed Tunnels Section ---
        let managedTunnels = tunnelManager.tunnels // Read on main thread
        if !managedTunnels.isEmpty {
            menu.addItem(withTitle: "Yönetilen Tüneller (Config ile)", action: nil, keyEquivalent: "").isEnabled = false
            for tunnel in managedTunnels {
                let icon: String; let titleText: String
                switch tunnel.status {
                case .running: icon = "🟢"; titleText = "\(icon) \(tunnel.name)"
                case .stopped: icon = "🔴"; titleText = "\(icon) \(tunnel.name)"
                case .starting: icon = "🟡"; titleText = "\(icon) \(tunnel.name) (Başlatılıyor...)"
                case .stopping: icon = "🟠"; titleText = "\(icon) \(tunnel.name) (Durduruluyor...)"
                case .error: icon = "❗️"; titleText = "\(icon) \(tunnel.name) (Hata)"
                }
                let mainMenuItem = NSMenuItem(title: titleText, action: nil, keyEquivalent: "")
                
                var toolTipParts: [String] = ["Durum: \(tunnel.status.displayName)"]
                if let uuid = tunnel.uuidFromConfig { toolTipParts.append("UUID: \(uuid)")} else { toolTipParts.append("UUID: (Config'den okunamadı)")}
                if let path = tunnel.configPath { toolTipParts.append("Config: \((path as NSString).abbreviatingWithTildeInPath)") }
                if let pid = tunnel.processIdentifier { toolTipParts.append("PID: \(pid)") }
                if let err = tunnel.lastError, !err.isEmpty { toolTipParts.append("Son Hata: \(err.split(separator: "\n").first ?? "")") }
                mainMenuItem.toolTip = toolTipParts.joined(separator: "\n")
                
                let subMenu = NSMenu()
                let canToggle = tunnel.isManaged && tunnel.status != .starting && tunnel.status != .stopping && isCloudflaredAvailable
                let toggleTitle = (tunnel.status == .running) ? "Durdur" : "Başlat"
                let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleManagedTunnelAction(_:)), keyEquivalent: ""); toggleItem.target = self; toggleItem.representedObject = tunnel; toggleItem.isEnabled = canToggle; subMenu.addItem(toggleItem)
                subMenu.addItem(NSMenuItem.separator())
                
                let canOpenConfig = tunnel.configPath != nil && FileManager.default.fileExists(atPath: tunnel.configPath!)
                let openConfigItem = NSMenuItem(title: "Config Dosyasını Aç (.yml)", action: #selector(openConfigFileAction(_:)), keyEquivalent: ""); openConfigItem.target = self; openConfigItem.representedObject = tunnel; openConfigItem.isEnabled = canOpenConfig; subMenu.addItem(openConfigItem)
                
                let canRouteDns = tunnel.isManaged && isCloudflaredAvailable
                let routeDnsItem = NSMenuItem(title: "DNS Kaydı Yönlendir...", action: #selector(routeDnsForTunnelAction(_:)), keyEquivalent: ""); routeDnsItem.target = self; routeDnsItem.representedObject = tunnel; routeDnsItem.isEnabled = canRouteDns; subMenu.addItem(routeDnsItem)
                subMenu.addItem(NSMenuItem.separator())
                
                let canDelete = tunnel.isManaged && tunnel.status != .stopping && tunnel.status != .starting && isCloudflaredAvailable
                let deleteItem = NSMenuItem(title: "Bu Tüneli Sil...", action: #selector(deleteTunnelAction(_:)), keyEquivalent: ""); deleteItem.target = self; deleteItem.representedObject = tunnel; deleteItem.isEnabled = canDelete; deleteItem.toolTip = "Cloudflare'dan tüneli ve isteğe bağlı yerel dosyaları siler. DİKKAT! Geri Alınamaz."
                deleteItem.attributedTitle = NSAttributedString(string: deleteItem.title, attributes: [.foregroundColor: NSColor.systemRed]); subMenu.addItem(deleteItem)
                
                mainMenuItem.submenu = subMenu; menu.addItem(mainMenuItem)
            }
        }
        
        // --- Placeholder or Separator ---
        if managedTunnels.isEmpty && quickTunnels.isEmpty && isCloudflaredAvailable {
            menu.addItem(withTitle: "Tünel bulunamadı", action: nil, keyEquivalent: "").isEnabled = false
        }
        if !managedTunnels.isEmpty || !quickTunnels.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        
        // --- Bulk Actions ---
        let canStartAnyManaged = isCloudflaredAvailable && managedTunnels.contains { $0.isManaged && ($0.status == .stopped || $0.status == .error) }
        let startAllItem = NSMenuItem(title: "Tüm Yönetilenleri Başlat", action: #selector(startAllManagedTunnelsAction), keyEquivalent: ""); startAllItem.target = self; startAllItem.isEnabled = canStartAnyManaged; menu.addItem(startAllItem)
        
        let canStopAny = isCloudflaredAvailable && (managedTunnels.contains { $0.isManaged && [.running, .stopping, .starting].contains($0.status) } || !quickTunnels.isEmpty)
        let stopAllItem = NSMenuItem(title: "Tüm Tünelleri Durdur", action: #selector(stopAllTunnelsAction), keyEquivalent: ""); stopAllItem.target = self; stopAllItem.isEnabled = canStopAny; menu.addItem(stopAllItem)
        menu.addItem(NSMenuItem.separator())
        
        // --- Create Actions ---
        menu.addItem(withTitle: "Oluştur / Başlat", action: nil, keyEquivalent: "").isEnabled = false
//        let quickTunnelItem = NSMenuItem(title: "Hızlı Tünel Başlat...", action: #selector(startQuickTunnelAction(_:)), keyEquivalent: "")
//        quickTunnelItem.target = self; quickTunnelItem.isEnabled = isCloudflaredAvailable; menu.addItem(quickTunnelItem)
        
        let createManagedItem = NSMenuItem(title: "Yeni Yönetilen Tünel (Config ile)...", action: #selector(openCreateManagedTunnelWindow), keyEquivalent: "n"); createManagedItem.target = self; createManagedItem.isEnabled = isCloudflaredAvailable; menu.addItem(createManagedItem)
        
        let mampIntegrationPossible = isCloudflaredAvailable && FileManager.default.fileExists(atPath: tunnelManager.mampSitesDirectoryPath)
        let createMampItem = NSMenuItem(title: "MAMP Sitesinden Oluştur...", action: #selector(openCreateFromMampWindow), keyEquivalent: "")
        createMampItem.target = self; createMampItem.isEnabled = mampIntegrationPossible;
        if !mampIntegrationPossible && isCloudflaredAvailable { createMampItem.toolTip = "MAMP site dizini bulunamadı: \(tunnelManager.mampSitesDirectoryPath)" }
        menu.addItem(createMampItem)
        
        // --- Folder Management, Refresh, Settings, Quit ---
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Yönetim", action: nil, keyEquivalent: "").isEnabled = false
        let openCloudflaredItem = NSMenuItem(title: "~/.cloudflared Klasörünü Aç", action: #selector(openCloudflaredFolderAction), keyEquivalent: ""); openCloudflaredItem.target = self; openCloudflaredItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.cloudflaredDirectoryPath); menu.addItem(openCloudflaredItem)
        let openMampConfigItem = NSMenuItem(title: "MAMP Apache Conf Klasörünü Aç", action: #selector(openMampConfigFolderAction), keyEquivalent: ""); openMampConfigItem.target = self; openMampConfigItem.isEnabled = FileManager.default.fileExists(atPath: tunnelManager.mampConfigDirectoryPath); menu.addItem(openMampConfigItem)

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Listeyi Yenile (Yönetilen)", action: #selector(refreshManagedTunnelListAction), keyEquivalent: "r"); refreshItem.target = self; menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())
        
        // --- [NEW] Setup PDF Item ---
        let setupPdfItem = NSMenuItem(title: "Kurulum Kılavuzunu Aç (PDF)", action: #selector(openSetupPdfAction), keyEquivalent: ""); setupPdfItem.target = self; menu.addItem(setupPdfItem)
        // --- [END NEW] ---

        menu.addItem(NSMenuItem.separator()) // Separator before Refresh

        // --- Launch At Login (macOS 13+) ---
        if #available(macOS 13.0, *) {
            let launchAtLoginItem = NSMenuItem(title: "Oturum Açıldığında Başlat", action: #selector(toggleLaunchAtLoginAction(_:)), keyEquivalent: ""); launchAtLoginItem.target = self
            // Get current state synchronously (should be fast enough for menu build)
            launchAtLoginItem.state = tunnelManager.isLaunchAtLoginEnabled() ? .on : .off
            menu.addItem(launchAtLoginItem)
        } else {
            let launchAtLoginItem = NSMenuItem(title: "Oturum Açıldığında Başlat (macOS 13+)", action: nil, keyEquivalent: ""); launchAtLoginItem.isEnabled = false; menu.addItem(launchAtLoginItem)
        }
        
        let settingsItem = NSMenuItem(title: "Ayarlar...", action: #selector(openSettingsWindowAction), keyEquivalent: ","); settingsItem.target = self; menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Cloudflared Manager'dan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quitItem)
        
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
        alert.messageText = "'\(tunnel.name)' Tünelini Sil"
        alert.informativeText = "Bu işlem tüneli Cloudflare'dan kalıcı olarak silecektir.\n\n⚠️ BU İŞLEM GERİ ALINAMAZ! ⚠️\n\nEmin misiniz?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Evet, Kalıcı Olarak Sil")
        alert.addButton(withTitle: "İptal")
        if alert.buttons.count > 0 { alert.buttons[0].hasDestructiveAction = true }
        
        // Activate app before showing modal alert
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal() // Use runModal for critical confirmations
            
            if response == .alertFirstButtonReturn {
                print("Silme işlemi başlatılıyor: \(tunnel.name)")
                self.tunnelManager?.deleteTunnel(tunnelInfo: tunnel) { result in
                    DispatchQueue.main.async { // Ensure UI updates on main thread
                        switch result {
                        case .success:
                            self.sendUserNotification(identifier:"deleted_\(tunnel.id)", title: "Tünel Silindi", body: "'\(tunnel.name)' Cloudflare'dan silindi.")
                            self.askToDeleteLocalFiles(for: tunnel) // Ask about local files AFTER cloud success
                            self.tunnelManager?.findManagedTunnels() // Refresh list
                        case .failure(let error):
                            self.showErrorAlert(message: "'\(tunnel.name)' tüneli silinirken hata:\n\(error.localizedDescription)")
                        }
                    }
                }
            } else {
                print("Silme iptal edildi.")
            }
        } // End DispatchQueue.main.async for runModal
    }
    
    @objc func routeDnsForTunnelAction(_ sender: NSMenuItem) {
        guard let tunnel = sender.representedObject as? TunnelInfo, tunnel.isManaged, let tunnelManager = tunnelManager else { return }
        let suggestedHostname = tunnelManager.findHostname(for: tunnel.configPath ?? "") ?? "\(tunnel.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }).adilemre.xyz" // Sanitize suggestion

        let alert = NSAlert()
        alert.messageText = "DNS Kaydı Yönlendir"
        alert.informativeText = "'\(tunnel.name)' (UUID: \(tunnel.uuidFromConfig ?? "N/A")) tüneline yönlendirilecek hostname'i girin:"
        alert.addButton(withTitle: "Yönlendir")
        alert.addButton(withTitle: "İptal")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.stringValue = suggestedHostname
        inputField.placeholderString = "örn: app.alanadiniz.com"
        alert.accessoryView = inputField
        // İlk yanıtlayıcıyı runModal'dan ÖNCE ayarlayın.
        alert.window.initialFirstResponder = inputField

        // Uygulamayı öne getirin, böylece alert diyalogu görünür olur.
        NSApp.activate(ignoringOtherApps: true)

        // --- DEĞİŞİKLİK BURADA ---
        // beginSheetModal ve completion handler yerine runModal kullanın.
        // runModal, kullanıcı bir butona basana kadar bu satırda bekler (senkron).
        let response = alert.runModal()
        // --- DEĞİŞİKLİK SONU ---

        // Kullanıcı "Yönlendir" butonuna bastıysa devam et
        if response == .alertFirstButtonReturn {
            let hostname = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hostname.isEmpty && hostname.contains(".") else {
                // runModal sonrası zaten ana thread'deyiz, tekrar Dispatch gerekmez.
                self.showErrorAlert(message: "Geçersiz hostname formatı.")
                return
            }

            // Asenkron DNS yönlendirme işlemini başlat
            self.tunnelManager.routeDns(tunnelInfo: tunnel, hostname: hostname) { result in
                // Sonuç geldiğinde UI güncellemesini ana thread'de yap
                DispatchQueue.main.async {
                    switch result {
                    case .success(let output):
                        self.showInfoAlert(title: "DNS Yönlendirme Başarılı", message: "'\(hostname)' için DNS kaydı başarıyla oluşturuldu veya güncellendi.\n\n\(output)")
                        self.sendUserNotification(identifier:"dns_routed_\(tunnel.id)_\(hostname)", title: "DNS Yönlendirildi", body: "\(hostname) -> \(tunnel.name)")
                    case .failure(let error):
                        self.showErrorAlert(message: "'\(hostname)' için DNS yönlendirme hatası:\n\(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Kullanıcı "İptal" veya başka bir butona bastı (veya pencereyi kapattı)
            print("DNS yönlendirme iptal edildi.")
        }
    }
    
    // Quick Tunnel Actions
    @objc func startQuickTunnelAction(_ sender: Any) {
        guard let tunnelManager = tunnelManager else { return }
        let alert = NSAlert(); alert.messageText = "Hızlı Tünel Başlat"; alert.informativeText = "Erişime açılacak yerel URL'yi girin:"; alert.addButton(withTitle: "Başlat"); alert.addButton(withTitle: "İptal")
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); inputField.placeholderString = "http://localhost:8000"; alert.accessoryView = inputField;
        
        DispatchQueue.main.async { // Present alert on main thread
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = inputField
            let windowForSheet = NSApp.keyWindow ?? NSWindow()
            alert.beginSheetModal(for: windowForSheet) { [weak self] response in
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    let localURL = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !localURL.isEmpty, let url = URL(string: localURL), url.scheme != nil, url.host != nil else {
                        self.showErrorAlert(message: "Geçersiz yerel URL formatı.\n(örn: http://localhost:8000)"); return
                    }
                    tunnelManager.startQuickTunnel(localURL: localURL) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let tunnelID):
                                print("Hızlı tünel başlatma işlemi gönderildi, ID: \(tunnelID)")
                                // Notification will be sent by manager on success/failure/URL found
                            case .failure(let error):
                                self.showErrorAlert(message: "Hızlı tünel başlatılamadı:\n\(error.localizedDescription)")
                            }
                        }
                    }
                } else { print("Hızlı tünel başlatma iptal edildi.") }
            } // End beginSheetModal
        } // End DispatchQueue.main.async for alert presentation
    }
    
    @objc func stopQuickTunnelAction(_ sender: NSMenuItem) {
        guard let tunnelID = sender.representedObject as? UUID, let tunnelManager = tunnelManager else { return }
        tunnelManager.stopQuickTunnel(id: tunnelID)
    }
    @objc func copyQuickTunnelURLAction(_ sender: NSMenuItem) {
        guard let tunnelData = sender.representedObject as? QuickTunnelData, let urlString = tunnelData.publicURL else {
            sendUserNotification(identifier: "copy_fail_\(UUID().uuidString)", title: "Kopyalanamadı", body: "Tünel URL'si henüz mevcut değil.")
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlString, forType: .string)
        sendUserNotification(identifier: "url_copied_\(tunnelData.id)", title: "URL Kopyalandı", body: urlString)
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
                    self?.sendUserNotification(identifier: "login_check_complete", title: "Cloudflare Giriş Kontrolü", body: "İşlem başlatıldı veya durum kontrol edildi. Gerekirse tarayıcıyı kontrol edin.")
                case .failure(let error):
                    self?.showErrorAlert(message: "Cloudflare giriş işlemi sırasında hata:\n\(error.localizedDescription)")
                }
            }
        }
    }
    
    // Launch At Login Action (macOS 13+)
    @objc func toggleLaunchAtLoginAction(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *), let tunnelManager = tunnelManager else {
            showErrorAlert(message: "Bu özellik macOS 13 veya üstünü gerektirir.")
            return
        }
        tunnelManager.toggleLaunchAtLogin { result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let newStateEnabled):
                    sender.state = newStateEnabled ? .on : .off
                    self.sendUserNotification(identifier: "launch_toggle", title: "Açılışta Başlatma", body: newStateEnabled ? "Etkinleştirildi" : "Devre Dışı Bırakıldı")
                case .failure(let error):
                    self.showErrorAlert(message: "Oturum açıldığında başlatma ayarı değiştirilirken hata:\n\(error.localizedDescription)")
                    // Revert UI state by checking actual state again
                    sender.state = tunnelManager.isLaunchAtLoginEnabled() ? .on : .off
                }
            }
        }
    }
    
    // --- [NEW] Action to Open Setup PDF ---
     @objc func openSetupPdfAction() {
         // Replace "KurulumKılavuzu" with the actual name of your PDF file (without the .pdf extension)
         guard let pdfURL = Bundle.main.url(forResource: "kullanım", withExtension: "pdf") else {
             print("❌ Hata: Kurulum PDF'i uygulama paketinde bulunamadı ('KurulumKılavuzu.pdf').")
             showErrorAlert(message: "Kurulum kılavuzu PDF dosyası bulunamadı.")
             return
         }
         print("Kurulum PDF'i açılıyor: \(pdfURL.path)")
         NSWorkspace.shared.open(pdfURL)
     }
     // --- [END NEW] ---
    
    // MARK: - Window Management
    private func showWindow<Content: View>(
        // Bu closure'lar hangi pencere değişkenini okuyup yazacağımızı belirler
        _ windowPropertySetter: @escaping (NSWindow?) -> Void,
        _ existingWindowGetter: @escaping () -> NSWindow?,
        title: String,
        view: Content
    ) {
        // Pencere işlemleri her zaman ana iş parçacığında yapılmalı
        DispatchQueue.main.async {
            // Önce TunnelManager'ın var olduğundan emin olalım
            guard let manager = self.tunnelManager else {
                print("❌ Hata: showWindow çağrıldı ancak TunnelManager mevcut değil.")
                self.showErrorAlert(message: "Pencere açılamadı: Tünel Yöneticisi bulunamadı.")
                return
            }
            
            // Uygulamayı aktif hale getir
            NSApp.activate(ignoringOtherApps: true)
            
            // Mevcut pencereyi kontrol et (getter closure'ı kullanarak)
            if let existingWindow = existingWindowGetter(), existingWindow.isVisible {
                // Eğer zaten varsa ve görünürse, ortala ve öne getir
                existingWindow.center()
                existingWindow.makeKeyAndOrderFront(nil)
                print("Mevcut pencere öne getirildi: \(title)")
                return // Yeni pencere oluşturma
            }
            
            // --- Yeni Pencere Oluşturma ---
            print("Yeni pencere oluşturuluyor: \(title)")
            
            // View'ı NSHostingController içine yerleştir ve TunnelManager'ı ekle
            let hostingController = NSHostingController(rootView: view.environmentObject(manager))
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable] // Kapatma düğmesi olan standart stil
            newWindow.level = .normal // Normal pencere seviyesi
            // ÖNEMLİ: isReleasedWhenClosed false olmalı ki biz referansı tutabilelim
            newWindow.isReleasedWhenClosed = false
            newWindow.center() // Ekranda ortala
            
            // Yeni oluşturulan pencere referansını AppDelegate'deki doğru değişkene ata
            // (setter closure'ı kullanarak)
            windowPropertySetter(newWindow)
            
            // Yeni pencereyi göster ve klavye odağını ver
            newWindow.makeKeyAndOrderFront(nil)
        }
    }
    
    // Ayarlar penceresini açan standart yöntem (Settings Scene ile)
    @objc func openSettingsWindowAction() {
        // @main App içindeki Settings Scene'i tetikler
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        // Uygulamanın aktif olduğundan emin ol
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    // "Create Managed Tunnel" penceresini açan Action (DÜZELTİLMİŞ ÇAĞRI)
    @objc func openCreateManagedTunnelWindow() {
        let createView = CreateManagedTunnelView()
        // showWindow'a hangi değişkenin güncelleneceğini ve okunacağını closure'lar ile bildiriyoruz
        showWindow(
            { newWindow in self.createManagedTunnelWindow = newWindow }, // Setter
            { self.createManagedTunnelWindow },                         // Getter
            title: "Yeni Yönetilen Tünel Oluştur",
            view: createView
        )
    }
    
    // "Create From MAMP" penceresini açan Action (DÜZELTİLMİŞ ÇAĞRI)
    @objc func openCreateFromMampWindow() {
        let createView = CreateFromMampView()
        // showWindow'a hangi değişkenin güncelleneceğini ve okunacağını closure'lar ile bildiriyoruz
        showWindow(
            { newWindow in self.createFromMampWindow = newWindow }, // Setter
            { self.createFromMampWindow },                         // Getter
            title: "MAMP Sitesinden Tünel Oluştur",
            view: createView
        )
    }
    // MARK: - Alert Helpers
    private func showInfoAlert(title: String, message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .informational; alert.addButton(withTitle: "Tamam");
            alert.runModal()
        }
    }
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "Hata"; alert.informativeText = message; alert.alertStyle = .critical; alert.addButton(withTitle: "Tamam");
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
        
        DispatchQueue.main.async { // Show alert on main thread
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "Yerel Dosyaları Sil?"; alert.informativeText = "'\(tunnel.name)' tüneli Cloudflare'dan silindi.\nİlişkili yerel dosyaları da silmek ister misiniz?\n\n- \(fileNames.joined(separator: "\n- "))"; alert.alertStyle = .warning; alert.addButton(withTitle: "Evet, Yerel Dosyaları Sil"); alert.addButton(withTitle: "Hayır, Dosyaları Koruyun")
            if alert.buttons.count > 0 { alert.buttons[0].hasDestructiveAction = true }
            
            if alert.runModal() == .alertFirstButtonReturn {
                print("Yerel dosyalar siliniyor: \(filesToDelete)")
                var errors: [String] = []
                filesToDelete.forEach { path in
                    do { try FileManager.default.removeItem(atPath: path); print("   Silindi: \(path)") }
                    catch { print("❌ Yerel dosya silme hatası: \(path) - \(error)"); errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)") }
                }
                if errors.isEmpty { self.sendUserNotification(identifier:"local_deleted_\(tunnel.id)", title: "Yerel Dosyalar Silindi", body: "'\(tunnel.name)' ile ilişkili dosyalar silindi.") }
                else { self.showErrorAlert(message: "Bazı yerel dosyalar silinirken hata oluştu:\n\(errors.joined(separator: "\n"))") }
                self.tunnelManager?.findManagedTunnels() // Refresh list after deletion attempt
            } else { print("Yerel dosyalar korunuyor.") }
        } // End DispatchQueue.main.async for alert
    }
    
    // Ask helper for opening MAMP config
    func askToOpenMampConfigFolder() {
        guard let configPath = tunnelManager?.mampConfigDirectoryPath else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "MAMP Yapılandırması Güncellendi"
            alert.informativeText = "MAMP vHost dosyası güncellendi. Ayarların etkili olması için MAMP sunucularını yeniden başlatmanız gerekir.\n\nMAMP Apache yapılandırma klasörünü açmak ister misiniz?"
            alert.addButton(withTitle: "Klasörü Aç")
            alert.addButton(withTitle: "Hayır")
            alert.alertStyle = .informational
            
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
            }
        }
    }
    
    // End AppDelegate
}
