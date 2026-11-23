#if canImport(UIKit)
import HanlinChatCore
import SwiftUI

@MainActor
struct LorvexChatGPTPlanSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var account: LorvexChatGPTAccountState

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label(account.status,systemImage:account.canUsePlan
                ? "checkmark.shield.fill" : "person.crop.circle")
          if let email=account.email {
            LabeledContent("ChatGPT account",value:email)
          }
        } header: {
          Text("Sign in with ChatGPT")
        } footer: {
          Text("This uses OpenAI's official open-source authorization flow. No API key or ChatGPT password is entered in Lorvex.")
        }

        if account.canUsePlan {
          Section("Available models") {
            if account.models.isEmpty {
              Button("Load ChatGPT models"){
                _Concurrency.Task {await account.loadModels()}
              }
            } else {
              Picker("Model",selection:$account.selectedModelID) {
                ForEach(account.models){ model in
                  Text(model.displayName).tag(model.slug)
                }
              }
              .pickerStyle(.menu)
            }
            Text("Available models depend on your ChatGPT subscription and permitted workspace. Usage shares your ChatGPT plan limits.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Section("Connect account") {
            Button {
              account.beginSignIn()
            } label: {
              Label(account.isConnecting ? "Opening ChatGPT…" :
                "Continue with ChatGPT",systemImage:"person.crop.circle.badge.checkmark")
            }
            .disabled(account.isConnecting)
            if account.email != nil {
              Text("The ChatGPT account signed in successfully but has not granted the plan-use scope. You can reauthorize or use another AI provider.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if account.email != nil {
          Section {
            Button("Reauthorize ChatGPT"){
              account.beginSignIn()
            }
            .disabled(account.isConnecting)
            Button("Sign out of ChatGPT",role:.destructive) {
              account.signOut()
            }
          }
        }

        Section("Privacy and limitations") {
          Text("The ChatGPT OAuth bearer token stays in the iPad Keychain. Lorvex never copies your ChatGPT cookies or existing conversations. Inference uses OpenAI Responses with no response storage.")
          Text("ChatGPT plan inference requires an eligible account and explicit permission. If access is unavailable, you can keep using your configured OpenRouter or OpenAI API provider.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .task { if account.canUsePlan { await account.loadModels() } }
      .navigationTitle("ChatGPT account")
      .toolbar {
        ToolbarItem(placement:.confirmationAction){
          Button("Done"){dismiss()}
        }
      }
      .sheet(isPresented:Binding(
        get:{account.authorizationURL != nil},
        set:{if !$0 {account.cancelSignIn()}}
      )) {
        if let url=account.authorizationURL {
          LorvexChatGPTPlanBrowser(url:url)
            .ignoresSafeArea()
        }
      }
    }
  }
}
#endif
