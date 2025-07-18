import SwiftUI
import AppKit // For FileManager

struct CreateManagedTunnelView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss // Use standard dismiss

    // Form State
    @State private var tunnelName: String = ""
    @State private var configName: String = ""
    @State private var hostname: String = ""
    @State private var portString: String = "80" // Default to 80
    @State private var documentRoot: String = ""
    @State private var updateVHost: Bool = false

    // UI State
    @State private var isCreating: Bool = false
    @State private var creationStatus: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var showSuccessAlert: Bool = false
    @State private var successMessage: String = ""

    // Validation computed property
    var isFormValid: Bool {
         !tunnelName.isEmpty && tunnelName.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         !configName.isEmpty && configName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil &&
         !hostname.isEmpty && hostname.contains(".") && hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         !portString.isEmpty && Int(portString) != nil && (1...65535).contains(Int(portString)!) &&
         (!updateVHost || (!documentRoot.isEmpty && FileManager.default.fileExists(atPath: documentRoot))) // If updateVHost, docRoot must exist
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(NSLocalizedString("Create New Managed Tunnel", comment: "View title: Create new managed tunnel"))
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            // Main Content
            VStack(spacing: 16) {
                // Tunnel Details Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("Tunnel Details", comment: "Section header for tunnel details in managed tunnel creation"))
                        .font(.headline)
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        FormField(label: NSLocalizedString("Tunnel Name", comment: "Form field label: Tunnel Name in managed creation"), text: $tunnelName, placeholder: NSLocalizedString("Name on Cloudflare (no spaces)", comment: "Placeholder for tunnel name in managed creation"))
                            .onChange(of: tunnelName) { syncConfigName() }
                        
                        FormField(label: NSLocalizedString("Config Name", comment: "Form field label: Config Name in managed creation"), text: $configName, placeholder: NSLocalizedString("Local .yml File Name", comment: "Placeholder for config file name in managed creation"))
                        
                        FormField(label: NSLocalizedString("Hostname", comment: "Form field label: Hostname in managed creation"), text: $hostname, placeholder: NSLocalizedString("Domain to access", comment: "Placeholder for hostname in managed creation"))
                        
                        HStack {
                            Text(NSLocalizedString("Local Port", comment: "Form field label: Local Port in managed creation"))
                                .frame(width: 100, alignment: .trailing)
                            TextField(NSLocalizedString("Port", comment: "Placeholder for local port input in managed creation"), text: $portString)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 100)
                                .onChange(of: portString) { newValue in
                                    let filtered = newValue.filter { "0123456789".contains($0) }
                                    let clamped = String(filtered.prefix(5))
                                    if clamped != newValue {
                                        DispatchQueue.main.async { portString = clamped }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }

                Divider()
                    .padding(.horizontal)

                // MAMP Integration Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "link.circle.fill")
                            .foregroundColor(.blue)
                        Text(NSLocalizedString("MAMP Integration", comment: "Section header for MAMP integration in managed tunnel creation"))
                            .font(.headline)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("Project Root", comment: "Form field label: Project Root in managed creation"))
                                .frame(width: 100, alignment: .trailing)
                            TextField(NSLocalizedString("MAMP site folder", comment: "Placeholder for MAMP site folder input in managed creation"), text: $documentRoot)
                                .textFieldStyle(.roundedBorder)
                            Button(action: browseForDocumentRoot) {
                                Image(systemName: "folder")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.bordered)
                            .help(NSLocalizedString("Select project root directory", comment: "Help text for browse button in managed creation"))
                        }

                        Toggle(NSLocalizedString("Update MAMP Apache vHost File", comment: "Toggle label for updating MAMP vHost file in managed creation"), isOn: $updateVHost)
                            .padding(.leading, 105)
                            .disabled(documentRoot.isEmpty || !FileManager.default.fileExists(atPath: documentRoot))

                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(NSLocalizedString("If project root is valid and selected, attempts to add an entry to httpd-vhosts.conf. MAMP restart required.", comment: "Informational note about MAMP vHost update in managed creation"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 105)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)

            // Status/Progress Area
            if isCreating {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(creationStatus)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            Divider()

            // Action Buttons
            HStack {
                Button(NSLocalizedString("Cancel", comment: "Button title: Cancel action in managed creation form")) {
                    if !isCreating { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(action: startCreationProcess) {
                    HStack {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(NSLocalizedString("Create", comment: "Button title: Create action in managed creation form"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || !isFormValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .onAppear {
            portString = "\(tunnelManager.defaultMampPort)" // Set default MAMP port
        }
        .alert(NSLocalizedString("Error", comment: "Alert title: Error in managed creation form"), isPresented: $showErrorAlert) {
            Button(NSLocalizedString("OK", comment: "Alert button: OK in managed creation form")) { }
        } message: {
            Text(errorMessage)
        }
        .alert(NSLocalizedString("Success!", comment: "Alert title: Success in managed creation form"), isPresented: $showSuccessAlert) { // Changed "Başarılı" to "Success!" and "Harika!" to "Great!"
            Button(NSLocalizedString("Great!", comment: "Alert button: Great! in managed creation form")) { dismiss() }
        } message: {
            Text(successMessage)
        }
    }

    // Helper Views
    private struct FormField: View {
        let label: String
        @Binding var text: String
        let placeholder: String
        
        var body: some View {
            HStack {
                Text(label)
                    .frame(width: 100, alignment: .trailing)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // Sync config name with tunnel name initially
    private func syncConfigName() {
         if configName.isEmpty && !tunnelName.isEmpty {
             var safeName = tunnelName.replacingOccurrences(of: " ", with: "-").lowercased()
             safeName = safeName.filter { "abcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) }
             configName = safeName
         }
    }

    func browseForDocumentRoot() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.message = NSLocalizedString("Please select MAMP Project Root Directory", comment: "NSOpenPanel message for selecting MAMP project root in managed creation")
        if !documentRoot.isEmpty && FileManager.default.fileExists(atPath: documentRoot) { panel.directoryURL = URL(fileURLWithPath: documentRoot) }
        else if FileManager.default.fileExists(atPath: tunnelManager.mampSitesDirectoryPath) { panel.directoryURL = URL(fileURLWithPath: tunnelManager.mampSitesDirectoryPath) }

        panel.begin { response in
            if response == .OK, let url = panel.url { DispatchQueue.main.async { self.documentRoot = url.path } }
        }
    }

    private func startCreationProcess() {
        guard isFormValid else { /* Build specific error message based on invalid fields */
             errorMessage = NSLocalizedString("Please fill all required fields correctly.", comment: "Error message: Form validation failed in managed creation")
             // Add specific checks for better feedback (optional)
             showErrorAlert = true; return
        }
        guard let portIntValue = Int(portString), (1...65535).contains(portIntValue) else {
             errorMessage = NSLocalizedString("Invalid port number.", comment: "Error message: Invalid port number in managed creation"); showErrorAlert = true; return
        }

        isCreating = true
        creationStatus = String(format: NSLocalizedString("Creating tunnel '%@' on Cloudflare...", comment: "Status message: Creating tunnel on Cloudflare. Parameter is tunnel name in managed creation."), tunnelName)

        // Step 1: Create the tunnel on Cloudflare
        tunnelManager.createTunnel(name: tunnelName) { createResult in
            DispatchQueue.main.async {
                switch createResult {
                case .success(let tunnelData):
                    creationStatus = String(format: NSLocalizedString("Creating configuration file '%@.yml'...", comment: "Status message: Creating config file. Parameter is config name in managed creation."), configName)
                    let finalDocRoot = (self.updateVHost && !self.documentRoot.isEmpty && FileManager.default.fileExists(atPath: self.documentRoot)) ? self.documentRoot : nil

                    // Step 2: Create the local config file & potentially update MAMP
                    tunnelManager.createConfigFile(configName: self.configName, tunnelUUID: tunnelData.uuid, credentialsPath: tunnelData.jsonPath, hostname: self.hostname, port: self.portString, documentRoot: finalDocRoot) { configResult in
                        DispatchQueue.main.async {
                            switch configResult {
                            case .success(let configPath):
                                isCreating = false
                                successMessage = String(format: NSLocalizedString("Tunnel '%1$@' and configuration '%2$@' created successfully.", comment: "Success message: Tunnel and config created. Parameters are tunnel name, config file name in managed creation."), tunnelName, (configPath as NSString).lastPathComponent)
                                if finalDocRoot != nil { successMessage += NSLocalizedString("\n\nMAMP vHost file update attempted. You may need to restart MAMP servers.", comment: "Success message detail: MAMP vHost updated in managed creation") }
                                showSuccessAlert = true // Trigger success alert & dismiss

                            case .failure(let configError):
                                errorMessage = String(format: NSLocalizedString("Tunnel created, but configuration/MAMP error:\n%@", comment: "Error message: Tunnel created but config/MAMP error. Parameter is error description in managed creation."), configError.localizedDescription)
                                showErrorAlert = true; isCreating = false; creationStatus = NSLocalizedString("Error.", comment: "Status message: Error (short) in managed creation")
                            }
                        }
                    }
                case .failure(let createError):
                     errorMessage = String(format: NSLocalizedString("Error creating tunnel on Cloudflare:\n%@", comment: "Error message: Cloudflare tunnel creation error. Parameter is error description in managed creation."), createError.localizedDescription)
                     showErrorAlert = true; isCreating = false; creationStatus = NSLocalizedString("Error.", comment: "Status message: Error (short) in managed creation")
                }
             }
        }
    }
}

