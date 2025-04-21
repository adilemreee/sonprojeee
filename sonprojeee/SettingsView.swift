import SwiftUI
import Combine // For Just

struct SettingsView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var cloudflaredPath: String = ""
    @State private var checkIntervalString: String = ""
    @State private var launchAtLoginEnabled: Bool = false // Only used if #available(macOS 13.0, *)
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var showPathWarning: Bool = false
    
    // Debouncer for path validation
    @State private var pathDebounceSubject = PassthroughSubject<String, Never>()
    @State private var pathCancellable: AnyCancellable?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Genel Ayarlar").font(.title2).padding(.bottom, 10)
            
            // Cloudflared Path
            VStack(alignment: .leading) {
                Text("cloudflared Yolu:")
                HStack {
                    TextField("cloudflared yürütülebilir dosyasının yolu", text: $cloudflaredPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: cloudflaredPath) { newValue in
                            // Pass to debouncer
                            pathDebounceSubject.send(newValue)
                        }
                    Button("Gözat...", action: browseForCloudflared)
                }
                if showPathWarning {
                    Text("⚠️ Seçilen yol 'cloudflared' dosyası değil veya mevcut değil.")
                        .font(.caption).foregroundColor(.red)
                } else {
                    Text("Genellikle `/usr/local/bin/cloudflared` veya `/opt/homebrew/bin/cloudflared`").font(.caption).foregroundColor(.gray)
                }
            }
            
            Divider()
            
            // Check Interval
            VStack(alignment: .leading) {
                Text("Yönetilen Tünel Durum Kontrol Aralığı (saniye):")
                TextField("Saniye", text: $checkIntervalString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 80)
                    .onChange(of: checkIntervalString) { newValue in
                        let filtered = newValue.filter { "0123456789.".contains($0) } // Allow dot temporarily
                        let validChars = String(filtered.prefix(4)) // Limit length
                        if validChars != newValue {
                            checkIntervalString = validChars
                        }
                        // Update manager only if a valid Double >= 5 is entered
                        if let interval = Double(validChars), interval >= 5 {
                            if tunnelManager.checkInterval != interval {
                                tunnelManager.checkInterval = interval
                            }
                        } else if validChars.isEmpty || Double(validChars) == nil {
                            // Handle invalid input (e.g., ".") - could show warning or reset
                            // For simplicity, we just don't update the manager on invalid intermediate input.
                        }
                    }
                Text("Tünel durumlarının ne sıklıkta kontrol edileceği (min 5 sn).").font(.caption).foregroundColor(.gray)
            }
            
            Divider()
            
            // Launch at Login Toggle (macOS 13+)
            if #available(macOS 13.0, *) {
                Toggle("Oturum Açıldığında Başlat", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { newValue in
                        tunnelManager.toggleLaunchAtLogin { result in
                            DispatchQueue.main.async { // UI updates on main thread
                                switch result {
                                case .success(let enabled):
                                    print("Launch at login state changed to: \(enabled)")
                                    // Update local state only if different from actual result
                                    if launchAtLoginEnabled != enabled {
                                        launchAtLoginEnabled = enabled
                                    }
                                case .failure(let error):
                                    errorMessage = "Oturum açıldığında başlatma ayarı değiştirilemedi:\n\(error.localizedDescription)"
                                    showErrorAlert = true
                                    // Revert UI toggle by checking actual state
                                    launchAtLoginEnabled = tunnelManager.isLaunchAtLoginEnabled()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 5)
            } else {
                Text("Oturum Açıldığında Başlat (macOS 13+ Gerekli)")
                    .font(.callout)
                    .foregroundColor(.gray)
                    .padding(.bottom, 5)
            }
            
            // Add other settings like notification toggles here later if needed
            
            Spacer() // Pushes content up
        }
        .padding()
        .frame(minWidth: 450, idealWidth: 500, minHeight: 300, idealHeight: 350) // Adjusted height
        .onAppear {
            initializeState()
            setupPathDebouncer()
        }
        .alert("Hata", isPresented: $showErrorAlert, actions: {
            Button("Tamam") { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    func initializeState() {
        let currentPath = tunnelManager.cloudflaredExecutablePath
        cloudflaredPath = currentPath
        validatePath(currentPath) // Initial validation
        checkIntervalString = String(format: "%.0f", tunnelManager.checkInterval)
        if #available(macOS 13.0, *) {
            launchAtLoginEnabled = tunnelManager.isLaunchAtLoginEnabled()
        }
    }
    
    // Setup debouncer for path validation/update
    func setupPathDebouncer() {
        pathCancellable = pathDebounceSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main) // Wait 500ms after typing stops
            .sink { [self] path in
                self.validateAndSetPath(path)
            }
    }
    
    
    func validatePath(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // A simple check: must exist and filename must contain 'cloudflared'
        let fileExists = FileManager.default.fileExists(atPath: trimmedPath)
        let nameContainsCloudflared = (trimmedPath as NSString).lastPathComponent.lowercased().contains("cloudflared")
        showPathWarning = !fileExists || !nameContainsCloudflared
    }
    
    // Called by the debouncer
    func validateAndSetPath(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        validatePath(trimmedPath) // Update warning state based on final debounced value
        
        // Update manager only if path actually changed and it's now considered valid
        if !showPathWarning && trimmedPath != tunnelManager.cloudflaredExecutablePath {
            tunnelManager.cloudflaredExecutablePath = trimmedPath
        }
        // If path becomes invalid after being valid, the warning appears,
        // but we don't necessarily need to revert the manager's path immediately.
        // The manager's own checkCloudflaredExecutable will handle the invalid path.
    }
    
    func browseForCloudflared() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.message = "Lütfen 'cloudflared' yürütülebilir dosyasını seçin"
        let initialDir = (tunnelManager.cloudflaredExecutablePath as NSString).deletingLastPathComponent
        if !initialDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: initialDir) }
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async { // Ensure state update is on main thread
                    self.cloudflaredPath = url.path // Update state, onChange -> debouncer -> validateAndSetPath
                }
            }
        }
    }
}
