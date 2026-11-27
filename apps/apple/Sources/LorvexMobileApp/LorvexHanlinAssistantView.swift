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
    private let store: MobileStore
    @State private var showTaskWorkspace = false
    private let remoteBridge: LorvexRemoteBridgeState
    private let cloudAccount: LorvexCloudAccountState?
    private let chatGPTAccount: LorvexChatGPTAccountState
    @State private var showChatGPTAccountSettings = false
    @State private var showCloudAccountSettings = false
    @State private var showRemoteBridgeSettings = false
    @State private var showModelSettings = false
    #if canImport(UIKit)
    @State private var composerDraft = HanlinComposerDraft()
    @State private var unconfiguredDraft = ""
    @State private var pendingDraftTransfer: DraftTransfer?

    private struct DraftTransfer {
        let scope: LorvexHanlinConversationScope
        let text: String
    }
    #endif
    @State private var apiToken = ""
    @State private var configuredToken = ""
    @State private var configuredProfileID: String?
    @State private var configurationError: String?
    @State private var draftProvider = "OpenRouter"
    @State private var draftModelID = ""
    @State private var draftEndpoint = ""
    @State private var isSavingSettings = false
    @State private var pendingSendID: UUID?
    @State private var pendingSend: _Concurrency.Task<Void, Never>?
    @AppStorage("lorvex.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("lorvex.hanlin.model") private var modelID = ""
    @AppStorage("lorvex.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(assistant: LorvexHanlinAssistantState, store: MobileStore, remoteBridge: LorvexRemoteBridgeState,
         cloudAccount: LorvexCloudAccountState?,
         chatGPTAccount: LorvexChatGPTAccountState) {
        self.assistant = assistant; self.store = store; self.remoteBridge = remoteBridge
        self.cloudAccount = cloudAccount; self.chatGPTAccount = chatGPTAccount
    }

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(UIKit)
                if assistant.conversationScope == conversationScope {
                    LorvexHanlinChatWorkspace(assistant: assistant, store: store, draft: composerDraft,
                        modelName: provider == "ChatGPT" ? chatGPTAccount.selectedModelID : modelID,
                        showModelSettings: { openModelSettings() },
                        showRemoteBridgeSettings: openMCPSettings,
                        send: send)
                } else {
                    ProgressView("Opening conversation…")
                }
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
                    Button(String(localized: "Task workspace"), systemImage: "point.3.connected.trianglepath.dotted") {
                        showTaskWorkspace = true
                    }
                    .accessibilityIdentifier("hanlin.workspace.open")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cloud", systemImage: "icloud") {
                        showCloudAccountSettings = true
                    }
                    .accessibilityIdentifier("hanlin.cloud.settings")
                    .disabled(cloudAccount == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("MCP", systemImage: "network", action: openMCPSettings)
                        .accessibilityIdentifier("hanlin.mcp.settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Model", systemImage: "gearshape") { openModelSettings() }
                        .accessibilityIdentifier("hanlin.model.settings")
                }
            }
            .onAppear(perform: loadCredential)
            .task(id: conversationScope) { await restoreConversation() }
            #if canImport(UIKit)
            .onChange(of: composerDraft.text) { [scope = conversationScope] _, text in
                if let scope { assistant.updateDraft(text, scope: scope) }
                else if assistant.conversationScope == nil && !assistant.isRestoringConversation {
                    unconfiguredDraft = text
                }
            }
            #endif
            .onChange(of: chatGPTAccount.sessionRevision) { _, _ in
                guard provider == "ChatGPT" else { return }
                cancelPendingSend()
                _Concurrency.Task { await assistant.cancel() }
            }
            .onDisappear {
                cancelPendingSend()
                _Concurrency.Task { await assistant.cancel() }
            }
            .sheet(isPresented: $showTaskWorkspace) {
                NavigationStack {
                    MobileTaskWorkspaceView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Close")) { showTaskWorkspace = false }
                                    .accessibilityIdentifier("hanlin.workspace.close")
                            }
                        }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hanlin.workspace.sheet")
            }
            .sheet(isPresented: $showModelSettings) {
                settings
            }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                LorvexRemoteBridgeSettingsView(bridge: remoteBridge)
            }
            .sheet(isPresented: $showCloudAccountSettings) {
                if let cloudAccount {
                    LorvexCloudAccountSettingsView(cloud: cloudAccount, legacyBridge: remoteBridge)
                }
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showChatGPTAccountSettings) {
                NavigationStack {
                    LorvexChatGPTPlanSettingsView(account: chatGPTAccount)
                }
            }
            #endif
        }
        .chatMotionPreferences()
    }

    private var conversationScope: LorvexHanlinConversationScope? {
        let accountID: String?
        if provider == "ChatGPT" {
            #if canImport(UIKit)
            accountID = chatGPTAccount.activeAccountID
            #else
            accountID = nil
            #endif
        } else { accountID = configuredProfileID }
        guard let accountID else { return nil }
        return .init(lorvexAccountID: cloudAccount?.accountID, provider: provider,
                     endpoint: provider == "ChatGPT" ? "https://api.openai.com/v1" : endpoint,
                     providerAccountID: accountID)
    }

    private func restoreConversation() async {
        let scope = conversationScope
        cancelPendingSend()
        await assistant.selectConversation(scope)
        guard !_Concurrency.Task<Never, Never>.isCancelled, conversationScope == scope else { return }
        #if canImport(UIKit)
        if scope == nil { composerDraft.text = unconfiguredDraft }
        else {
            if let transfer = pendingDraftTransfer, transfer.scope == scope,
               assistant.isConversationReady {
                if assistant.draft.isEmpty { assistant.updateDraft(transfer.text, scope: scope) }
                pendingDraftTransfer = nil
            }
            composerDraft.text = assistant.draft
        }
        #endif
    }

    private func retainUnconfiguredDraft(provider: String, endpoint: String, profileID: String?) {
        #if canImport(UIKit)
        guard conversationScope == nil, let profileID, !composerDraft.text.isEmpty else { return }
        let scope = LorvexHanlinConversationScope(lorvexAccountID: cloudAccount?.accountID,
            provider: provider, endpoint: endpoint, providerAccountID: profileID)
        pendingDraftTransfer = .init(scope: scope, text: composerDraft.text)
        #endif
    }

    private func cancelPendingSend() {
        // Revoke ownership before cancellation can resume a suspended credential lookup.
        pendingSendID = nil
        pendingSend?.cancel()
        pendingSend = nil
    }

    private func openMCPSettings() {
        if cloudAccount != nil { showCloudAccountSettings = true }
        else { showRemoteBridgeSettings = true }
    }

    private func loadCredential() {
        #if DEBUG
        if LorvexHanlinWorkspaceAcceptance.isEnabled {
            // The opt-in simulator fixture never reads or writes a Keychain token.
            provider = "Other"
            modelID = LorvexHanlinWorkspaceAcceptance.modelID
            endpoint = LorvexHanlinWorkspaceAcceptance.endpoint
            apiToken = LorvexHanlinWorkspaceAcceptance.credential
            configuredToken = apiToken
            configuredProfileID = "native-workspace-acceptance"
            return
        }
        #endif
        apiToken = LorvexHanlinKeychain.read()
        configuredToken = apiToken
        do {
            if provider == "ChatGPT" { configuredProfileID = nil }
            else {
                configuredProfileID = try LorvexHanlinProviderProfileKeychain.profileID(
                    provider: provider, endpoint: endpoint, credential: configuredToken)
            }
        } catch {
            configuredProfileID = nil
            configurationError = String(localized: "Keychain could not securely store this credential.")
        }
        if modelID.isEmpty { openModelSettings() }
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
                    .accessibilityIdentifier("hanlin.model.provider")
                    if draftProvider == "ChatGPT" {
                        #if canImport(UIKit)
                        Label(chatGPTAccount.status, systemImage:"person.crop.circle")
                        NavigationLink("Connect / manage ChatGPT account") {
                            LorvexChatGPTPlanSettingsView(account: chatGPTAccount)
                        }
                        .accessibilityIdentifier("hanlin.chatgpt.settings")
                        if chatGPTAccount.canUsePlan {
                            Text(String(localized: "Selected: ") + chatGPTAccount.selectedModelID)
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

    private func openModelSettings() {
        guard !showModelSettings else { return }
        // Initialize a new draft once per presentation. Returning from account
        // authorization must preserve the selected provider and navigation.
        prepareSettings()
        showModelSettings = true
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
            cancelPendingSend()
            let revision = chatGPTAccount.sessionRevision
            let selectedModel = chatGPTAccount.selectedModelID
            _Concurrency.Task {
                await assistant.cancel()
                guard chatGPTAccount.sessionRevision == revision, chatGPTAccount.canUsePlan else {
                    configurationError = String(localized: "Sign in and select an eligible ChatGPT model first.")
                    isSavingSettings = false
                    return
                }
                #if canImport(UIKit)
                retainUnconfiguredDraft(provider: "ChatGPT", endpoint: "https://api.openai.com/v1",
                    profileID: chatGPTAccount.activeAccountID)
                #endif
                provider = "ChatGPT"
                modelID = selectedModel
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
            let selectedProfileID = try LorvexHanlinProviderProfileKeychain.profileID(
                provider: draftProvider, endpoint: draftEndpoint, credential: apiToken)
            try LorvexHanlinKeychain.save(apiToken)
            // Stop the previous owner before the newly saved configuration is
            // exposed to another send. Cancellation of settings leaves the
            // persisted provider/model/endpoint unchanged.
            isSavingSettings = true
            cancelPendingSend()
            let selectedProvider = draftProvider, selectedModel = draftModelID
            let selectedEndpoint = draftEndpoint, selectedCredential = apiToken
            _Concurrency.Task {
                await assistant.cancel()
                retainUnconfiguredDraft(provider: selectedProvider, endpoint: selectedEndpoint,
                    profileID: selectedProfileID)
                provider = selectedProvider; modelID = selectedModel; endpoint = selectedEndpoint
                configuredToken = selectedCredential; configuredProfileID = selectedProfileID
                configurationError = nil
                isSavingSettings = false; showModelSettings = false
            }
        } catch {
            configurationError = String(localized: "Keychain could not securely store this credential.")
        }
    }

    #if canImport(UIKit)
    private func send() {
        let text = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isRunning, pendingSendID == nil else { return }
        guard let selectedScope = conversationScope else {
            if provider == "ChatGPT" { showChatGPTAccountSettings = true }
            else { openModelSettings() }
            return
        }
        guard assistant.isConversationReady, assistant.conversationScope == selectedScope else { return }
        if provider == "ChatGPT" {
            guard chatGPTAccount.canUsePlan else {
                showChatGPTAccountSettings = true
                return
            }
            let requestID = UUID()
            pendingSendID = requestID
            pendingSend = _Concurrency.Task {
                defer {
                    if pendingSendID == requestID { pendingSendID = nil; pendingSend = nil }
                }
                do {
                    let credential = try await chatGPTAccount.accessForInference()
                    try _Concurrency.Task<Never, Never>.checkCancellation()
                    guard pendingSendID == requestID, conversationScope == selectedScope else { return }
                    if composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                        composerDraft.text = ""
                    }
                    modelID = credential.modelID
                    await assistant.send(text, modelID: credential.modelID,
                        endpoint: "https://api.openai.com/v1",
                        credential: credential.token, provider: "ChatGPT", scope: selectedScope)
                } catch is CancellationError {
                    // Preserve the unsent draft when the user closes the assistant.
                } catch {
                    guard pendingSendID == requestID else { return }
                    configurationError = LorvexHanlinErrorMessage.description(for: error)
                    chatGPTAccount.reportConnectionError(error)
                    showChatGPTAccountSettings = true
                }
            }
            return
        }
        guard !modelID.isEmpty, !configuredToken.isEmpty else {
            openModelSettings()
            return
        }
        let requestID = UUID()
        let selectedModel = modelID, selectedEndpoint = endpoint
        let selectedCredential = configuredToken, selectedProvider = provider
        pendingSendID = requestID
        pendingSend = _Concurrency.Task {
            defer {
                if pendingSendID == requestID { pendingSendID = nil; pendingSend = nil }
            }
            guard pendingSendID == requestID, conversationScope == selectedScope,
                  !_Concurrency.Task<Never, Never>.isCancelled else { return }
            if composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                composerDraft.text = ""
            }
            await assistant.send(text, modelID: selectedModel, endpoint: selectedEndpoint,
                                 credential: selectedCredential, provider: selectedProvider, scope: selectedScope)
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
