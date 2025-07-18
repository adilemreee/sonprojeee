import SwiftUI
import AppKit // For FileManager, NSWorkspace

// Custom Alert View
struct ModernAlertView: View {
    let title: String
    let message: String
    let type: AlertType
    let action: () -> Void
    
    @State private var isAnimating = false
    
    enum AlertType {
        case success
        case error
        case info
        
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .success: return Color(red: 0.2, green: 0.8, blue: 0.2)
            case .error: return Color(red: 0.9, green: 0.2, blue: 0.2)
            case .info: return Color(red: 0.2, green: 0.6, blue: 0.9)
            }
        }
        
        var backgroundColor: Color {
            switch self {
            case .success: return Color(red: 0.2, green: 0.8, blue: 0.2).opacity(0.1)
            case .error: return Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.1)
            case .info: return Color(red: 0.2, green: 0.6, blue: 0.9).opacity(0.1)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with icon
            VStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.system(size: 40))
                    .foregroundColor(type.color)
                    .symbolEffect(.bounce, options: .repeating, value: isAnimating)
                    .padding(.top, 20)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            .background(type.backgroundColor)
            
            // Message content
            ScrollView {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .frame(maxHeight: 150)
            
            // Button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    action()
                }
            }) {
                Text(NSLocalizedString("OK", comment: "Button title in ModernAlertView"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 120, height: 36)
                    .background(type.color)
                    .cornerRadius(10)
                    .shadow(color: type.color.opacity(0.3), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.bottom, 20)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 8)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// Custom button style for scale animation
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct CreateFromMampView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss

    // Form State
    @State private var mampSites: [String] = []
    @State private var selectedSite: String = ""
    @State private var tunnelName: String = ""
    @State private var configName: String = ""
    @State private var hostname: String = ""
    @State private var portString: String = ""

    // UI State
    @State private var isCreating: Bool = false
    @State private var creationStatus: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var showSuccessAlert: Bool = false
    @State private var successMessage: String = ""

    // Add new state for custom alert
    @State private var showCustomAlert: Bool = false
    @State private var customAlertTitle: String = ""
    @State private var customAlertMessage: String = ""
    @State private var customAlertType: ModernAlertView.AlertType = .info
    @State private var customAlertAction: (() -> Void)?

    // Computed Properties
    var documentRoot: String {
        guard !selectedSite.isEmpty else { return "" }
        let sitesPath = tunnelManager.mampSitesDirectoryPath.hasSuffix("/") ? String(tunnelManager.mampSitesDirectoryPath.dropLast()) : tunnelManager.mampSitesDirectoryPath
        return sitesPath.appending("/").appending(selectedSite)
    }
    var mampPortString: String { "\(tunnelManager.defaultMampPort)" }
    var documentRootExists: Bool { !documentRoot.isEmpty && FileManager.default.fileExists(atPath: documentRoot) }

    var isFormValid: Bool {
         !selectedSite.isEmpty &&
         !tunnelName.isEmpty && tunnelName.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         !configName.isEmpty && configName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil &&
         !hostname.isEmpty && hostname.contains(".") && hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         documentRootExists &&
         !portString.isEmpty && Int(portString) != nil && (1...65535).contains(Int(portString)!)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(NSLocalizedString("Create Tunnel from MAMP Site", comment: "View title: Create tunnel from MAMP site"))
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            // Main Content
            VStack(spacing: 16) {
                if mampSites.isEmpty {
                    EmptyStateView(mampSitesDirectoryPath: tunnelManager.mampSitesDirectoryPath)
                } else {
                    // Left Column - Site Selection
                    VStack(alignment: .leading, spacing: 12) {
                        // Site Selection
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("MAMP Site", comment: "Label for MAMP site picker"))
                                .font(.headline)
                            
                            Picker("", selection: $selectedSite) {
                                Text(NSLocalizedString("-- Select --", comment: "Default placeholder for MAMP site picker")).tag("")
                                ForEach(mampSites, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedSite) { newSite in autoFillDetails(for: newSite) }
                        }

                        // Document Root Display
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Project Root", comment: "Label for project root display"))
                                .font(.headline)
                            
                            HStack {
                                Text(documentRoot.isEmpty ? NSLocalizedString("(Select Site)", comment: "Placeholder text when no MAMP site is selected for document root") : (documentRoot as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(documentRoot.isEmpty || documentRootExists ? .secondary : .red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                if !documentRoot.isEmpty {
                                    Image(systemName: documentRootExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundColor(documentRootExists ? .green : .red)
                                        .help(documentRootExists ? NSLocalizedString("Directory found.", comment: "Tooltip: Document root directory found") : NSLocalizedString("Directory not found!", comment: "Tooltip: Document root directory not found"))
                                }
                            }
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // Right Column - Tunnel Details
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("Tunnel Details", comment: "Section header for tunnel details in MAMP creation form"))
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 8) {
                            FormField(label: NSLocalizedString("Tunnel Name", comment: "Form field label: Tunnel Name in MAMP creation"), text: $tunnelName, placeholder: NSLocalizedString("Name on Cloudflare (no spaces)", comment: "Placeholder for tunnel name in MAMP creation"))
                            FormField(label: NSLocalizedString("Config Name", comment: "Form field label: Config Name in MAMP creation"), text: $configName, placeholder: NSLocalizedString("Local .yml File Name", comment: "Placeholder for config file name in MAMP creation"))
                            FormField(label: NSLocalizedString("Hostname", comment: "Form field label: Hostname in MAMP creation"), text: $hostname, placeholder: NSLocalizedString("Domain to access", comment: "Placeholder for hostname in MAMP creation"))
                                .help(NSLocalizedString("You may need to create the DNS record in Cloudflare.", comment: "Help text for hostname field in MAMP creation"))
                            
                            HStack {
                                Text(NSLocalizedString("Local Port", comment: "Form field label: Local Port in MAMP creation"))
                                    .frame(width: 100, alignment: .trailing)
                                TextField(NSLocalizedString("Port (e.g., 8888)", comment: "Placeholder for local port input in MAMP creation"), text: $portString)
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
                }
            }
            .padding(.vertical, 8)

            // Note Section
            if !mampSites.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text(NSLocalizedString("Note: This process attempts to automatically update the MAMP vHost file. You will need to restart MAMP.", comment: "Informational note about MAMP vHost update in MAMP creation form"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

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
                Button(NSLocalizedString("Cancel", comment: "Button title: Cancel action in MAMP creation form")) {
                    if !isCreating { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(action: startMampCreationProcess) {
                    HStack {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(NSLocalizedString("Create", comment: "Button title: Create action in MAMP creation form"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || !isFormValid || mampSites.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadMampSites()
            portString = "\(tunnelManager.defaultMampPort)"
        }
        .alert(NSLocalizedString("Error", comment: "Alert title: Error in MAMP creation form"), isPresented: $showErrorAlert) {
            Button(NSLocalizedString("OK", comment: "Alert button: OK in MAMP creation form")) { }
        } message: {
            Text(errorMessage)
        }
        .alert(NSLocalizedString("Success", comment: "Alert title: Success in MAMP creation form"), isPresented: $showSuccessAlert) {
            Button(NSLocalizedString("Done", comment: "Alert button: Done in MAMP creation form")) { dismiss() }
        } message: {
            Text(successMessage)
        }
        .overlay {
            if showCustomAlert {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .overlay {
                        ModernAlertView(
                            title: customAlertTitle,
                            message: customAlertMessage,
                            type: customAlertType
                        ) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showCustomAlert = false
                            }
                            customAlertAction?()
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
            }
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

    private struct EmptyStateView: View {
        let mampSitesDirectoryPath: String
        
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                
                Text(NSLocalizedString("No project folder found in MAMP site directory", comment: "Empty state message: No MAMP projects found in MAMP creation form"))
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text(String(format: NSLocalizedString("Directory: %@", comment: "Empty state detail: MAMP directory path. Parameter is path in MAMP creation form."), mampSitesDirectoryPath))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: mampSitesDirectoryPath)) }) {
                    Label(NSLocalizedString("Open MAMP Site Directory", comment: "Button title: Open MAMP site directory in MAMP creation form"), systemImage: "folder")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private func loadMampSites() {
        mampSites = tunnelManager.scanMampSitesFolder()
        selectedSite = ""
        autoFillDetails(for: "")
    }

    private func autoFillDetails(for siteName: String) {
        if !siteName.isEmpty {
            let safeName = siteName.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) }
            if tunnelName.isEmpty || configName.isEmpty || hostname.hasSuffix(".adilemre.xyz") || tunnelName == configName {
                tunnelName = safeName
                configName = safeName
                hostname = "\(safeName).adilemre.xyz"
            }
        } else {
            tunnelName = ""
            configName = ""
            hostname = ""
        }
    }

    private func startMampCreationProcess() {
        guard isFormValid else {
            customAlertTitle = NSLocalizedString("Error", comment: "Custom alert title: Error in MAMP creation")
            customAlertMessage = NSLocalizedString("Please select a valid MAMP site and fill all fields correctly.", comment: "Custom alert message: Form validation failed for MAMP creation")
            if !documentRootExists && !selectedSite.isEmpty {
                customAlertMessage += String(format: NSLocalizedString("\n\nProject root not found for selected site: %@", comment: "Custom alert message detail: Project root not found. Parameter is path in MAMP creation."), documentRoot)
            }
            customAlertType = .error
            showCustomAlert = true
            return
        }

        isCreating = true
        creationStatus = String(format: NSLocalizedString("Creating tunnel '%@' on Cloudflare...", comment: "Status message: Creating tunnel on Cloudflare. Parameter is tunnel name in MAMP creation."), tunnelName)

        tunnelManager.createTunnel(name: tunnelName) { createResult in
            DispatchQueue.main.async {
                switch createResult {
                case .success(let tunnelData):
                    creationStatus = String(format: NSLocalizedString("Creating configuration file '%@.yml'...", comment: "Status message: Creating config file. Parameter is config name in MAMP creation."), configName)

                    tunnelManager.createConfigFile(configName: self.configName, tunnelUUID: tunnelData.uuid, credentialsPath: tunnelData.jsonPath, hostname: self.hostname, port: self.portString, documentRoot: self.documentRoot) { configResult in
                        DispatchQueue.main.async {
                            switch configResult {
                            case .success(let configPath):
                                isCreating = false
                                customAlertTitle = NSLocalizedString("Success", comment: "Custom alert title: Success in MAMP creation")
                                customAlertMessage = String(format: NSLocalizedString("Tunnel '%1$@' and configuration '%2$@' for MAMP site '%3$@' created successfully.\n\nMAMP Apache configuration files (vhost and httpd.conf) were attempted to be updated.\n\n⚠️ You MUST restart MAMP servers for changes to take effect!", comment: "Custom alert message: MAMP tunnel creation successful. Parameters are tunnel name, config file name, MAMP site name."), tunnelName, (configPath as NSString).lastPathComponent, selectedSite)
                                customAlertType = .success
                                customAlertAction = { dismiss() }
                                showCustomAlert = true

                            case .failure(let configError):
                                customAlertTitle = NSLocalizedString("Error", comment: "Custom alert title: Error in MAMP creation")
                                customAlertMessage = String(format: NSLocalizedString("Tunnel created, but configuration/MAMP error:\n%@", comment: "Custom alert message: Tunnel created but config/MAMP error. Parameter is error description in MAMP creation."), configError.localizedDescription)
                                if configError.localizedDescription.contains(NSLocalizedString("Write permission error", comment: "Substring to check for write permission error in configError in MAMP creation")) {
                                    customAlertMessage += NSLocalizedString("\n\nPlease check write permissions for the vHost file.", comment: "Custom alert message detail: Check vHost write permissions in MAMP creation.")
                                }
                                customAlertType = .error
                                showCustomAlert = true
                                isCreating = false
                                creationStatus = NSLocalizedString("Error.", comment: "Status message: Error (short) in MAMP creation")
                            }
                        }
                    }
                case .failure(let createError):
                    customAlertTitle = NSLocalizedString("Error", comment: "Custom alert title: Error in MAMP creation")
                    customAlertMessage = String(format: NSLocalizedString("Error creating tunnel on Cloudflare:\n%@", comment: "Custom alert message: Cloudflare tunnel creation error. Parameter is error description in MAMP creation."), createError.localizedDescription)
                    customAlertType = .error
                    showCustomAlert = true
                    isCreating = false
                    creationStatus = NSLocalizedString("Error.", comment: "Status message: Error (short) in MAMP creation")
                }
            }
        }
    }
} // End CreateFromMampView

