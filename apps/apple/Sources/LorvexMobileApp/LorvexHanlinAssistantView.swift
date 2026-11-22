import Security
import SwiftUI
import Charts
import LorvexMobile
import LorvexCore
import LorvexHanlinAgent

/// In-app Hanlin assistant for tasks. The model endpoint and model are user-configured.
/// API tokens stay in the device Keychain (not UserDefaults, project files or conversation logs).
struct LorvexHanlinAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assistant: LorvexHanlinAssistantState
    let remoteBridge: LorvexRemoteBridgeState
    @State private var showRemoteBridgeSettings = false
    @State private var prompt = ""
    @State private var chartBreakdown = "status"
    @State private var showModelSettings = false
    @State private var apiToken = ""
    @State private var configuredToken = ""
    @State private var configurationError: String?
    @AppStorage("lorvex.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("lorvex.hanlin.model") private var modelID = ""
    @AppStorage("lorvex.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(store: MobileStore, remoteBridge: LorvexRemoteBridgeState) {
        self.remoteBridge = remoteBridge
        _assistant = State(initialValue: LorvexHanlinAssistantState(
            core: store.assistantCore,
            didWrite: { [weak store] in _ = await store?.refresh() }))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if assistant.messages.isEmpty {
                    ContentUnavailableView {
                        Label("Task AI assistant", systemImage: "sparkles")
                    } description: {
                        Text("Ask for task summaries, planning, priority changes, or a dashboard. Writes require your approval.")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(assistant.messages) { entry in
                                HStack {
                                    if entry.role == .user { Spacer(minLength: 36) }
                                    Text(entry.text)
                                        .font(entry.role == .status ? .caption : .body)
                                        .foregroundStyle(entry.role == .status ? .secondary : .primary)
                                        .padding(11)
                                        .background(
                                            entry.role == .user ? Color.accentColor.opacity(0.12) :
                                            Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 15))
                                    if entry.role != .user { Spacer(minLength: 36) }
                                }
                                .id(entry.id)
                            }
                            if let summary = assistant.dashboard {
                                visualDashboard(summary)
                            }
                            if assistant.isRunning {
                                ProgressView("Working…")
                                    .font(.caption)
                                    .id("progress")
                            }
                        }.padding(15)
                    }
                    .onChange(of: assistant.messages.count) { _, _ in
                        if let last = assistant.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                if let error = assistant.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                HStack(spacing: 10) {
                    TextField("Ask about your tasks…", text: $prompt, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                    if assistant.isRunning {
                        Button {
                            Task { await assistant.cancel() }
                        } label: { Image(systemName: "stop.circle") }
                            .accessibilityLabel("Stop AI")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send to AI")
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Hanlin AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("MCP", systemImage: "network") {
                        showRemoteBridgeSettings = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Model", systemImage: "gearshape") { showModelSettings = true }
                }
            }
            .onAppear {
                apiToken = LorvexHanlinKeychain.read()
                configuredToken = apiToken
                if modelID.isEmpty { showModelSettings = true }
            }
            .onDisappear {
                Task { await assistant.cancel() }
            }
            .sheet(isPresented: $showModelSettings) { settings }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                LorvexRemoteBridgeSettingsView(bridge: remoteBridge)
            }
            .confirmationDialog(
                "Allow the AI to modify your tasks?",
                isPresented: Binding(
                    get: { assistant.pendingApproval != nil },
                    set: { if !$0 && assistant.pendingApproval != nil { assistant.resolveApproval(false) } }),
                titleVisibility: .visible
            ) {
                Button("Allow change") { assistant.resolveApproval(true) }
                Button("Deny", role: .cancel) { assistant.resolveApproval(false) }
            } message: {
                Text(assistant.pendingApproval?.description ?? "The requested change needs approval.")
            }
        }
    }

    @ViewBuilder
    private func visualDashboard(_ summary: LorvexHanlinSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Task overview").font(.headline)
                Spacer()
                Text(summary.partial ? "Partial sample" : "All tasks")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(summary.open) active", systemImage: "circle.dotted")
                Label("\(summary.completed) completed", systemImage: "checkmark.circle")
            }
            .font(.caption)
            Picker("Breakdown", selection: $chartBreakdown) {
                Text("Status").tag("status")
                Text("Priority").tag("priority")
            }
            .pickerStyle(.segmented)
            Chart(summary.buckets(by: chartBreakdown)) { bucket in
                BarMark(
                    x: .value("Category", bucket.name),
                    y: .value("Tasks", bucket.value))
                    .foregroundStyle(by: .value("Category", bucket.name))
            }
            .chartLegend(.hidden)
            .frame(height: 170)
            .accessibilityLabel("Task summary bar chart")
            if summary.partial {
                Text("Based on \(summary.sampleSize) of \(summary.totalMatching) matching tasks.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("AI provider") {
                    Picker("Provider", selection: $provider) {
                        Text("OpenRouter").tag("OpenRouter")
                        Text("OpenAI").tag("OpenAI")
                        Text("Anthropic").tag("Anthropic")
                        Text("Google").tag("Google")
                        Text("Other compatible").tag("Other")
                    }
                    TextField("Model identifier", text: $modelID)
                        .autocorrectionDisabled()
                    TextField("HTTPS API base URL", text: $endpoint)
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
            .navigationTitle("Hanlin model settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        apiToken = configuredToken
                        showModelSettings = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
                              !modelID.isEmpty else {
                            configurationError = "Enter an HTTPS endpoint and a model identifier."
                            return
                        }
                        do {
                            try LorvexHanlinKeychain.save(apiToken)
                            configuredToken = apiToken
                            configurationError = nil
                            showModelSettings = false
                            Task { await assistant.cancel() }
                        } catch {
                            configurationError = "Keychain could not securely store this credential."
                        }
                    }
                }
            }
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isRunning else { return }
        prompt = ""
        Task {
            await assistant.send(text, modelID: modelID, endpoint: endpoint,
                                 credential: configuredToken, provider: provider)
        }
    }
}

private enum LorvexHanlinKeychain {
    private static let service = "com.lorvex.apple.hanlin-agent"
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
        let previous = SecItemDelete(query as CFDictionary)
        guard previous == errSecSuccess || previous == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(previous))
        }
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}
