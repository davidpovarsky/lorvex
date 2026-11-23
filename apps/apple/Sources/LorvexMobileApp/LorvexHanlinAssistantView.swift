import Security
import LorvexMobile
import SwiftUI
import LorvexCore
import LorvexHanlinAgent
import HanlinChatUI

@MainActor
struct LorvexHanlinAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    private let assistant: LorvexHanlinAssistantState
    private let remoteBridge: LorvexRemoteBridgeState
    private let cloudAccount: LorvexCloudAccountState?
    private let chatGPTAccount: LorvexChatGPTAccountState
    @State private var showChatGPTAccountSettings = false
    @State private var showCloudAccountSettings = false
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
    @State private var isPreparingRequest = false
    @State private var pendingSend: _Concurrency.Task<Void, Never>?
    @AppStorage("lorvex.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("lorvex.hanlin.model") private var modelID = ""
    @AppStorage("lorvex.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(assistant: LorvexHanlinAssistantState, remoteBridge: LorvexRemoteBridgeState,
         cloudAccount: LorvexCloudAccountState?,
         chatGPTAccount: LorvexChatGPTAccountState) {
        self.assistant = assistant; self.remoteBridge = remoteBridge
        self.cloudAccount = cloudAccount; self.chatGPTAccount = chatGPTAccount
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
                    Button("Cloud", systemImage: "icloud") {
                        showCloudAccountSettings = true
                    }
                    .accessibilityIdentifier("hanlin.cloud.settings")
                    .disabled(cloudAccount == nil)
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
            .onDisappear {
                pendingSend?.cancel(); pendingSend = nil; isPreparingRequest = false
                _Concurrency.Task { await assistant.cancel() }
            }
            .sheet(isPresented: $showModelSettings) {
                settings.onAppear(perform: prepareSettings)
            }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                LorvexRemoteBridgeSettingsView(bridge: remoteBridge)
            }
            .sheet(isPresented: $showCloudAccountSettings) {
                if let cloudAccount {
                    LorvexCloudAccountSettingsView(cloud: cloudAccount)
                }
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showChatGPTAccountSettings) {
                LorvexChatGPTPlanSettingsView(account: chatGPTAccount)
            }
            #endif
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
                        Text("ChatGPT account").tag("ChatGPT")
                        Text("Anthropic").tag("Anthropic")
                        Text("Google").tag("Google")
                        Text("Other compatible").tag("Other")
                    }
                    if draftProvider == "ChatGPT" {
                        #if canImport(UIKit)
                        Label(chatGPTAccount.status, systemImage:"person.crop.circle")
                        NavigationLink("Connect / manage ChatGPT account") {
                            LorvexChatGPTPlanSettingsView(account: chatGPTAccount)
                        }
                        if chatGPTAccount.canUsePlan {
                            Text("Selected: " + chatGPTAccount.selectedModelID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        #else
                        Text("ChatGPT account login is available in Lorvex on iPad.")
                        #endif
                    } else {
                        TextField("Model identifier", text: $draftModelID)
                            .autocorrectionDisabled()
                        TextField("HTTPS API base URL", text: $draftEndpoint)
                            .autocorrectionDisabled()
                        SecureField("API key", text: $apiToken)
                            .autocorrectionDisabled()
                        Text("Your API key is stored only in the iPad Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    .accessibilityIdentifier("hanlin.model.cancel")
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
        if draftProvider == "ChatGPT" {
            guard !isSavingSettings, chatGPTAccount.canUsePlan,
                  !chatGPTAccount.selectedModelID.isEmpty else {
                configurationError = String(localized: "Sign in and select an eligible ChatGPT model first.")
                return
            }
            isSavingSettings = true
            _Concurrency.Task {
                await assistant.cancel()
                provider = "ChatGPT"
                modelID = chatGPTAccount.selectedModelID
                endpoint = "https://api.openai.com/v1"
                configurationError = nil
                isSavingSettings = false
                showModelSettings = false
            }
            return
        }
        guard !isSavingSettings, let url = URL(string: draftEndpoint),
              url.scheme == "https", url.host != nil, !draftModelID.isEmpty else {
            configurationError = String(localized: "Enter an HTTPS endpoint and a model identifier.")
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
            configurationError = String(localized: "Keychain could not securely store this credential.")
        }
    }

    #if canImport(UIKit)
    private func send() {
        let text = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isRunning, !isPreparingRequest else { return }
        if provider == "ChatGPT" {
            guard chatGPTAccount.canUsePlan else {
                showChatGPTAccountSettings = true
                return
            }
            isPreparingRequest = true
            pendingSend = _Concurrency.Task {
                defer { isPreparingRequest = false; pendingSend = nil }
                do {
                    let credential = try await chatGPTAccount.accessForInference()
                    try _Concurrency.Task<Never, Never>.checkCancellation()
                    if composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                        composerDraft.text = ""
                    }
                    modelID = credential.modelID
                    await assistant.send(text, modelID: credential.modelID,
                        endpoint: "https://api.openai.com/v1",
                        credential: credential.token, provider: "ChatGPT")
                } catch is CancellationError {
                    // Preserve the unsent draft when the user closes the assistant.
                } catch {
                    configurationError = error.localizedDescription
                    chatGPTAccount.reportConnectionError(error)
                    showChatGPTAccountSettings = true
                }
            }
            return
        }
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
