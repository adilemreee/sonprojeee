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
                Text("Tamam")
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
                Text("MAMP Sitesinden Tünel Oluştur")
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
                            Text("MAMP Sitesi")
                                .font(.headline)
                            
                            Picker("", selection: $selectedSite) {
                                Text("-- Seçiniz --").tag("")
                                ForEach(mampSites, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedSite) { newSite in autoFillDetails(for: newSite) }
                        }

                        // Document Root Display
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Proje Kökü")
                                .font(.headline)
                            
                            HStack {
                                Text(documentRoot.isEmpty ? "(Site Seçin)" : (documentRoot as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(documentRoot.isEmpty || documentRootExists ? .secondary : .red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                if !documentRoot.isEmpty {
                                    Image(systemName: documentRootExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundColor(documentRootExists ? .green : .red)
                                        .help(documentRootExists ? "Dizin bulundu." : "Dizin bulunamadı!")
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
                        Text("Tünel Detayları")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 8) {
                            FormField(label: "Tünel Adı", text: $tunnelName, placeholder: "Cloudflare'deki Ad (boşluksuz)")
                            FormField(label: "Config Adı", text: $configName, placeholder: "Yerel .yml Dosya Adı")
                            FormField(label: "Hostname", text: $hostname, placeholder: "Erişilecek Alan Adı")
                                .help("DNS kaydını Cloudflare'de oluşturmanız gerekebilir.")
                            
                            HStack {
                                Text("Yerel Port")
                                    .frame(width: 100, alignment: .trailing)
                                TextField("Port (örn: 8888)", text: $portString)
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
                    Text("Not: Bu işlem MAMP vHost dosyasını otomatik güncellemeyi dener. MAMP'ı yeniden başlatmanız gerekir.")
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
                Button("İptal") {
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
                        Text("Oluştur")
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
        .alert("Hata", isPresented: $showErrorAlert) {
            Button("Tamam") { }
        } message: {
            Text(errorMessage)
        }
        .alert("Başarılı", isPresented: $showSuccessAlert) {
            Button("Tamamlandı") { dismiss() }
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
                
                Text("MAMP site dizininde proje klasörü bulunamadı")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text("Dizin: \(mampSitesDirectoryPath)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: mampSitesDirectoryPath)) }) {
                    Label("MAMP Site Dizinini Aç", systemImage: "folder")
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
            customAlertTitle = "Hata"
            customAlertMessage = "Lütfen geçerli bir MAMP sitesi seçin ve tüm alanları doğru doldurun."
            if !documentRootExists && !selectedSite.isEmpty {
                customAlertMessage += "\n\nSeçilen site için proje kökü bulunamadı: \(documentRoot)"
            }
            customAlertType = .error
            showCustomAlert = true
            return
        }

        isCreating = true
        creationStatus = "'\(tunnelName)' tüneli Cloudflare'da oluşturuluyor..."

        tunnelManager.createTunnel(name: tunnelName) { createResult in
            DispatchQueue.main.async {
                switch createResult {
                case .success(let tunnelData):
                    creationStatus = "Yapılandırma dosyası '\(configName).yml' oluşturuluyor..."

                    tunnelManager.createConfigFile(configName: self.configName, tunnelUUID: tunnelData.uuid, credentialsPath: tunnelData.jsonPath, hostname: self.hostname, port: self.portString, documentRoot: self.documentRoot) { configResult in
                        DispatchQueue.main.async {
                            switch configResult {
                            case .success(let configPath):
                                isCreating = false
                                customAlertTitle = "Başarılı"
                                customAlertMessage = """
                                    MAMP sitesi '\(selectedSite)' için tünel '\(tunnelName)' ve yapılandırma '\((configPath as NSString).lastPathComponent)' başarıyla oluşturuldu.

                                    MAMP Apache yapılandırma dosyaları (vhost ve httpd.conf) güncellenmeye çalışıldı.

                                    ⚠️ Ayarların etkili olması için MAMP sunucularını yeniden başlatmanız GEREKİR!
                                    """
                                customAlertType = .success
                                customAlertAction = { dismiss() }
                                showCustomAlert = true

                            case .failure(let configError):
                                customAlertTitle = "Hata"
                                customAlertMessage = "Tünel oluşturuldu ancak yapılandırma/MAMP hatası:\n\(configError.localizedDescription)"
                                if configError.localizedDescription.contains("Yazma izni hatası") {
                                    customAlertMessage += "\n\nLütfen vHost dosyası için yazma izinlerini kontrol edin."
                                }
                                customAlertType = .error
                                showCustomAlert = true
                                isCreating = false
                                creationStatus = "Hata."
                            }
                        }
                    }
                case .failure(let createError):
                    customAlertTitle = "Hata"
                    customAlertMessage = "Cloudflare'da tünel oluşturma hatası:\n\(createError.localizedDescription)"
                    customAlertType = .error
                    showCustomAlert = true
                    isCreating = false
                    creationStatus = "Hata."
                }
            }
        }
    }
} // End CreateFromMampView

