import SwiftUI
import LorvexHanlinAgent

/// User-driven OAuth linking. The iPad generates a private device credential,
/// registers its actual SDK tool catalog, and displays a short-lived one-time
/// code. No server-side copy of Lorvex's private database is created.
struct LorvexRemoteBridgeSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var bridge: LorvexRemoteBridgeState

  var body: some View {
    NavigationStack {
      Form {
        Section("Cloudflare / MCP bridge") {
          TextField("HTTPS bridge URL", text: $bridge.endpointText)
            .textContentType(.URL)
            .autocorrectionDisabled()
          Text("The address of your private Lorvex MCP relay. It must use HTTPS.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Image(systemName: bridge.linked ? "checkmark.shield.fill" : "network")
              .foregroundStyle(bridge.linked ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
              Text(bridge.status)
                .font(.callout)
              if let last = bridge.lastTool {
                Text("Last tool: " + last).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          Button {
            Task { await bridge.pair() }
          } label: {
            if bridge.isPairing {
              ProgressView("Connecting…")
            } else {
              Label("Pair this iPad with ChatGPT", systemImage: "link")
            }
          }
          .disabled(bridge.isPairing || bridge.endpointText.isEmpty)
        }

        if let code = bridge.pairingCode {
          Section("One-time pairing code") {
            Text(code)
              .font(.system(.largeTitle, design: .monospaced, weight: .bold))
              .textSelection(.enabled)
              .accessibilityLabel("One-time ChatGPT pairing code: " + code)
            Text("In ChatGPT on the web, connect a custom MCP server at this HTTPS address with OAuth. When ChatGPT opens the Lorvex sign-in page, enter this code. The code expires after 10 minutes.")
              .font(.callout)
            Text("You do not need to share your Lorvex database, Apple ID or API keys with the bridge.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("When can ChatGPT use tools?") {
          Label("Keep Lorvex open in the foreground while ChatGPT uses the tools.", systemImage: "ipad")
          Label("Task changes require approval on this iPad.", systemImage: "checkmark.shield")
          Label("The server stores only device pairing and temporary requests, not your tasks.", systemImage: "lock.shield")
          if bridge.linked {
            Button("Disconnect ChatGPT and revoke access", role: .destructive) {
              Task { await bridge.disconnect() }
            }
          }
        }
      }
      .navigationTitle("ChatGPT MCP")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
