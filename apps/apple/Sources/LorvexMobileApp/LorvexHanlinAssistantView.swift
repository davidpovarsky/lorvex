import Security
import SwiftUI
import LorvexCore
import LorvexHanlinAgent
import HanlinChatUI

@MainActor
struct LorvexHanlinAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    private let assistant: LorvexHanlinAssistantState
    private let remoteBridge: LorvexRemoteBridgeState
    @State private var showRemoteBridgeSettings = false
    @State private var showModelSettings = false
    #if canImport(UIKit)
    @State private var composerDraft = HanlinComposerDraft()
    #endif
    @State private var apiToken = ""
    @State private var configuredToken = ""
    @State private var configurationError: String?
    @State private var draftProvider = "OpenRouter"
    @State private var draftModelID = ""
    @State private var draftEndpoint = ""
    @State private var isSavingSettings = false
    @AppStorage("lorvex.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("lorvex.hanlin.model") private var modelID = ""
    @AppStorage("lorvex.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(assistant: LorvexHanlinAssistantState, remoteBridge: LorvexRemoteBridgeState) {
        self.assistant = assistant; self.remoteBridge = remoteBridge
    }

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(UIKit)
                LorvexHanlinChatWorkspace(assistant: assistant, draft: composerDraft,
                    modelName: modelID,
                    showModelSettings: { showModelSettings = true },
                    showRemoteBridgeSettings: { showRemoteBridgeSettings = true },
                    send: send)
                #else
                ContentUnavailableView("Hanlin AI", systemImage: "ipad",
                    description: Text("Open the original Hanlin chat in the Lorvex iPad or iPhone app."))
                #endif
            }
            .navigationTitle("Hanlin AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("hanlin.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("MCP", systemImage: "network") { showRemoteBridgeSettings = true }
                        .accessibilityIdentifier("hanlin.mcp.settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Model", systemImage: "gearshape") { showModelSettings = true }
                        .accessibilityIdentifier("hanlin.model.settings")
                }
            }
            .onAppear(perform: loadCredential)
            .onDisappear { _Concurrency.Task { await assistant.cancel() } }
            .sheet(isPresented: $showModelSettings) {
                settings.onAppear(perform: prepareSettings)
            }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                LorvexRemoteBridgeSettingsView(bridge: remoteBridge)
            }
        }
        .chatMotionPreferences()
    }

    private func loadCredential() {
        apiToken = LorvexHanlinKeychain.read()
        configuredToken = apiToken
        if modelID.isEmpty { showModelSettings = true }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("AI provider") {
                    Picker("Provider", selection: $draftProvider) {
                        Text("OpenRouter").tag("OpenRouter")
                        Text("OpenAI").tag("OpenAI")
                        Text("Anthropic").tag("Anthropic")
                        Text("Google").tag("Google")
                        Text("Other compatible").tag("Other")
                    }
                    TextField("Model identifier", text: $draftModelID)
                        .autocorrectionDisabled()
                    TextField("HTTPS API base URL", text: $draftEndpoint)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiToken)
                        .autocorrectionDisabled()
                    Text("The API key is saved only in your device Keychain. An API provider may charge for usage. This is not ChatGPT account sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let configurationError {
                    Text(configurationError).foregroundStyle(.red)
                }
            }
            .disabled(isSavingSettings)
            .navigationTitle("Hanlin model settings")
            .interactiveDismissDisabled(isSavingSettings)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        apiToken = configuredToken
                        showModelSettings = false
                    }.disabled(isSavingSettings)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveSettings).disabled(isSavingSettings)
                }
            }
        }
    }

    private func prepareSettings() {
        draftProvider = provider; draftModelID = modelID; draftEndpoint = endpoint
        apiToken = configuredToken; configurationError = nil
    }

    private func saveSettings() {
        guard !isSavingSettings, let url = URL(string: draftEndpoint),
              url.scheme == "https", url.host != nil, !draftModelID.isEmpty else {
            configurationError = "Enter an HTTPS endpoint and a model identifier."
            return
        }
        do {
            try LorvexHanlinKeychain.save(apiToken)
            // Stop the previous owner before the newly saved configuration is
            // exposed to another send. Cancellation of settings leaves the
            // persisted provider/model/endpoint unchanged.
            isSavingSettings = true
            _Concurrency.Task {
                await assistant.cancel()
                provider = draftProvider; modelID = draftModelID; endpoint = draftEndpoint
                configuredToken = apiToken; configurationError = nil
                isSavingSettings = false; showModelSettings = false
            }
        } catch {
            configurationError = "Keychain could not securely store this credential."
        }
    }

    #if canImport(UIKit)
    private func send() {
        let text = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isRunning else { return }
        guard !modelID.isEmpty, !configuredToken.isEmpty else {
            showModelSettings = true
            return
        }
        composerDraft.text = ""
        _Concurrency.Task {
            await assistant.send(text, modelID: modelID, endpoint: endpoint,
                                 credential: configuredToken, provider: provider)
        }
    }
    #endif
}

private enum LorvexHanlinKeychain {
    private static let service = "com.itorah.lorvex.hanlin-agent"
    private static let account = "current-provider-api-key"

    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data, let text = String(data: bytes, encoding: .utf8)
        else { return "" }
        return text
    }

    static func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            // A failed replacement must retain the working credential.
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        let item = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
        }
    }
}
