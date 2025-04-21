import SwiftUI
import AppKit // For FileManager, NSWorkspace

struct CreateFromMampView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss

    // Form State
    @State private var mampSites: [String] = []
    @State private var selectedSite: String = ""
    @State private var tunnelName: String = ""
    @State private var configName: String = ""
    @State private var hostname: String = ""

    // UI State
    @State private var isCreating: Bool = false
    @State private var creationStatus: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var showSuccessAlert: Bool = false
    @State private var successMessage: String = ""

    // Computed Properties
    var documentRoot: String {
        guard !selectedSite.isEmpty else { return "" }
        let sitesPath = tunnelManager.mampSitesDirectoryPath.hasSuffix("/") ? String(tunnelManager.mampSitesDirectoryPath.dropLast()) : tunnelManager.mampSitesDirectoryPath
        return sitesPath.appending("/").appending(selectedSite)
    }
    var mampPortString: String { "\(tunnelManager.defaultMampPort)" }
    var documentRootExists: Bool { !documentRoot.isEmpty && FileManager.default.fileExists(atPath: documentRoot) }

    // Validation
    var isFormValid: Bool {
         !selectedSite.isEmpty &&
         !tunnelName.isEmpty && tunnelName.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         !configName.isEmpty && configName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil &&
         !hostname.isEmpty && hostname.contains(".") && hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
         documentRootExists // Document root derived from selection must exist
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("MAMP Sitesinden Tünel Oluştur").font(.title2).padding(.bottom, 10)

            if mampSites.isEmpty {
                Text("MAMP site dizininde (\(tunnelManager.mampSitesDirectoryPath)) proje klasörü bulunamadı.")
                    .foregroundColor(.orange).padding()
                Button("MAMP Site Dizinini Aç") { NSWorkspace.shared.open(URL(fileURLWithPath: tunnelManager.mampSitesDirectoryPath)) }
            } else {
                // Site Selection
                Picker("MAMP Sitesi Seçin:", selection: $selectedSite) {
                    Text("-- Seçiniz --").tag("")
                    ForEach(mampSites, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: selectedSite) { newSite in autoFillDetails(for: newSite) }

                // Display calculated document root
                HStack {
                     Text("Proje Kökü:")
                     Text(documentRoot.isEmpty ? "(Site Seçin)" : (documentRoot as NSString).abbreviatingWithTildeInPath)
                         .font(.caption).foregroundColor(documentRoot.isEmpty || documentRootExists ? .gray : .red)
                         .lineLimit(1).truncationMode(.middle)
                     if !documentRoot.isEmpty {
                          Image(systemName: documentRootExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                              .foregroundColor(documentRootExists ? .green : .red)
                              .help(documentRootExists ? "Dizin bulundu." : "Dizin bulunamadı!")
                     }
                     Spacer()
                 }
                 .padding(.leading, 5)

                Divider()

                // Tunnel Details (Auto-filled based on selection)
                Group {
                    HStack { Text("Tünel Adı:").frame(width: 100, alignment: .trailing); TextField("Cloudflare'deki Ad (boşluksuz)", text: $tunnelName) }
                    HStack { Text("Config Adı:").frame(width: 100, alignment: .trailing); TextField("Yerel .yml Dosya Adı", text: $configName) }
                    HStack { Text("Hostname:").frame(width: 100, alignment: .trailing); TextField("Erişilecek Alan Adı", text: $hostname).help("DNS kaydını Cloudflare'de oluşturmanız gerekebilir.") }
                    HStack { Text("Yerel Port:").frame(width: 100, alignment: .trailing); Text(mampPortString).foregroundColor(.gray) }
                }

                Divider()
                Text("Not: Bu işlem MAMP vHost dosyasını otomatik güncellemeyi dener. MAMP'ı yeniden başlatmanız gerekir.")
                    .font(.caption).foregroundColor(.gray)

            } // End if mampSites not empty

            Spacer() // Push buttons down

            // Status/Progress Area
            if isCreating {
                HStack { ProgressView().scaleEffect(0.8); Text(creationStatus).font(.callout).foregroundColor(.gray).lineLimit(2) }.padding(.bottom, 5)
            }

            // Action Buttons
            HStack {
                Button("İptal") { if !isCreating { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Oluştur") { startMampCreationProcess() }.keyboardShortcut(.defaultAction)
                    .disabled(isCreating || !isFormValid || mampSites.isEmpty)
            }
            .padding(.top)

        } // End VStack
        .padding()
        .frame(minWidth: 500, idealWidth: 550, minHeight: 380, idealHeight: 430) // Adjusted height
        .onAppear(perform: loadMampSites)
        .alert("Hata", isPresented: $showErrorAlert, actions: { Button("Tamam") { } }, message: { Text(errorMessage) })
        .alert("Başarılı", isPresented: $showSuccessAlert, actions: { Button("Tamamlandı") { dismiss() } }, message: { Text(successMessage) })
    } // End body

    private func loadMampSites() {
        mampSites = tunnelManager.scanMampSitesFolder()
        selectedSite = "" // Reset selection on appear
        autoFillDetails(for: "") // Clear fields initially
    }

    private func autoFillDetails(for siteName: String) {
         if !siteName.isEmpty {
             let safeName = siteName.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) }
             // Only update if fields were empty or clearly default suggestions
             if tunnelName.isEmpty || configName.isEmpty || hostname.hasSuffix(".adilemre.xyz") || tunnelName == configName {
                  tunnelName = safeName
                  configName = safeName
                  hostname = "\(safeName).adilemre.xyz" // Suggest a default hostname
             }
         } else {
             // Clear fields if "-- Seçiniz --" is chosen
             tunnelName = ""
             configName = ""
             hostname = ""
         }
    }


    private func startMampCreationProcess() {
         guard isFormValid else {
             errorMessage = "Lütfen geçerli bir MAMP sitesi seçin ve tüm alanları doğru doldurun."
             if !documentRootExists && !selectedSite.isEmpty { errorMessage += "\n\nSeçilen site için proje kökü bulunamadı: \(documentRoot)" }
             showErrorAlert = true; return
         }

        isCreating = true
        creationStatus = "'\(tunnelName)' tüneli Cloudflare'da oluşturuluyor..."

        // Step 1: Create tunnel on Cloudflare
        tunnelManager.createTunnel(name: tunnelName) { createResult in
            DispatchQueue.main.async {
                switch createResult {
                case .success(let tunnelData):
                    creationStatus = "Yapılandırma dosyası '\(configName).yml' oluşturuluyor..."

                    // Step 2: Create local config file (always pass documentRoot for MAMP)
                    tunnelManager.createConfigFile(configName: self.configName, tunnelUUID: tunnelData.uuid, credentialsPath: tunnelData.jsonPath, hostname: self.hostname, port: self.mampPortString, documentRoot: self.documentRoot) { configResult in
                        DispatchQueue.main.async {
                            switch configResult {
                            case .success(let configPath):
                                isCreating = false
                                successMessage = "MAMP sitesi '\(selectedSite)' için tünel '\(tunnelName)' ve yapılandırma '\((configPath as NSString).lastPathComponent)' başarıyla oluşturuldu.\n\nMAMP vHost dosyası güncellendi. MAMP sunucularını yeniden başlatın."
                                showSuccessAlert = true // Trigger success alert & dismiss

                            case .failure(let configError):
                                errorMessage = "Tünel oluşturuldu ancak yapılandırma/MAMP hatası:\n\(configError.localizedDescription)"
                                if configError.localizedDescription.contains("Yazma izni hatası") { errorMessage += "\n\nLütfen vHost dosyası için yazma izinlerini kontrol edin." }
                                showErrorAlert = true; isCreating = false; creationStatus = "Hata."
                            }
                        }
                    }
                case .failure(let createError):
                    errorMessage = "Cloudflare'da tünel oluşturma hatası:\n\(createError.localizedDescription)"
                    showErrorAlert = true; isCreating = false; creationStatus = "Hata."
                }
             }
        }
    }
} // End CreateFromMampView
