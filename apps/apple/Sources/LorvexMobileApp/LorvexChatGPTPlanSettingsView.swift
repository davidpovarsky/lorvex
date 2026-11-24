#if canImport(UIKit)
import HanlinChatCore
import SwiftUI

@MainActor
struct LorvexChatGPTPlanSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var account: LorvexChatGPTAccountState

  var body: some View {
    Form {
      Section {
        Label(account.status, systemImage: account.canUsePlan
              ? "checkmark.shield.fill" : "person.crop.circle")
        if let active = account.activeAccount {
          LabeledContent("ChatGPT account", value: active.label)
          if let email = account.email { Text(email).foregroundStyle(.secondary) }
        }
        if let notice = account.signOutNotice {
          Text(notice).font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("Sign in with ChatGPT")
      } footer: {
        Text("This uses OpenAI's official open-source authorization flow. No API key or ChatGPT password is entered in Lorvex.")
      }

      Section {
        ForEach(account.accounts) { profile in
          Button {
            account.beginSignIn(accountID: profile.id)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(profile.label)
                if let email = profile.registration.email {
                  Text(email).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if profile.id == account.activeAccountID {
                Label("Active", systemImage: "checkmark.circle.fill")
                  .font(.caption)
              }
            }
            .contentShape(Rectangle())
          }
          .foregroundStyle(.primary)
          .disabled(account.isConnecting || account.revokingAccountIDs.contains(profile.id))
          .accessibilityValue(profile.id == account.activeAccountID
            ? String(localized: "Active") : String(localized: "Saved account"))
          .accessibilityIdentifier("chatgpt.accounts.saved.\(profile.ordinal)")
        }
        Button {
          account.beginSignIn()
        } label: {
          Label(account.accounts.isEmpty ? String(localized: "Continue with ChatGPT")
                : String(localized: "Add ChatGPT account"),
                systemImage: "person.crop.circle.badge.plus")
        }
        .disabled(account.isConnecting)
        .accessibilityIdentifier("chatgpt.accounts.add")
      } header: {
        Text("ChatGPT accounts")
          .accessibilityIdentifier("chatgpt.accounts.saved")
      } footer: {
        Text("Choose a saved account to sign in again, or add another. Each account keeps its own sign-in and model selection.")
      }

      if account.canUsePlan {
        Section("Available models") {
          if account.models.isEmpty {
            Button("Load ChatGPT models") {
              _Concurrency.Task { await account.loadModels() }
            }
          } else {
            Picker("Model", selection: $account.selectedModelID) {
              ForEach(account.models) { model in Text(model.displayName).tag(model.slug) }
            }
            .pickerStyle(.menu)
          }
          Text("Available models depend on your ChatGPT subscription and permitted workspace. Usage shares your ChatGPT plan limits.")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else if account.activeAccountID != nil {
        Section {
          Text("The ChatGPT account signed in successfully but has not granted the plan-use scope. You can reauthorize or use another AI provider.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      if account.activeAccountID != nil {
        Section {
          Button("Sign out of ChatGPT", role: .destructive) { account.signOut() }
            .disabled(account.isConnecting)
            .accessibilityIdentifier("chatgpt.accounts.signOut")
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
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    .background {
      LorvexChatGPTPlanBrowser(url: account.authorizationURL) { url in
        account.cancelSignIn(authorizationURL: url)
      }
      .frame(width: 0, height: 0)
    }
  }
}
#endif
