import SwiftUI
import LorvexMobile

/// A normal Lorvex account replaces iPad pairing codes. Login credentials
/// are sent only over TLS and the session is retained in the device Keychain.
@MainActor
struct LorvexCloudAccountSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var cloud: LorvexCloudAccountState
  @State private var email = ""
  @State private var password = ""
  @State private var showSignOut = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Lorvex Cloud") {
          Label(cloud.status, systemImage: cloud.accountID == nil
                ? "person.crop.circle" : "checkmark.icloud")
          Text("Tasks, projects, calendar and habits live in your Lorvex Cloud account. ChatGPT can manage them even if your iPad is switched off.")
            .font(.callout).foregroundStyle(.secondary)
        }

        if cloud.accountID == nil {
          Section("Sign in or create an account") {
            TextField("Email",text:$email)
              .textContentType(.emailAddress)
              .autocorrectionDisabled()
            SecureField("Password (at least 12 characters)",text:$password)
              .textContentType(.password)
            Button("Sign in") { authenticate(register:false) }
              .disabled(cloud.isSigningIn || email.isEmpty || password.isEmpty)
            Button("Create Lorvex account") { authenticate(register:true) }
              .disabled(cloud.isSigningIn || email.isEmpty || password.count<12)
            if cloud.isSigningIn { ProgressView("Connecting…") }
          }
        } else {
          Section("Connected account") {
            LabeledContent("Account",value:cloud.email)
            if let lastSync=cloud.lastSync {
              LabeledContent("Last synchronized",value:lastSync,
                             format:.dateTime.day().month().hour().minute())
              LabeledContent("Received",value:String(cloud.lastReceived))
              LabeledContent("Sent",value:String(cloud.lastSent))
              LabeledContent("Conflicts reconciled",value:String(cloud.lastConflicts))
            }
            Button {
              Task { await cloud.syncNow() }
            } label: {
              Label(cloud.isSyncing ? "Synchronizing…" : "Sync now",
                    systemImage:"arrow.triangle.2.circlepath")
            }
            .disabled(cloud.isSyncing)
            Button("Sign out",role:.destructive) { showSignOut=true }
          }
        }

        Section("ChatGPT connection") {
          Text("In ChatGPT connect the Lorvex Cloud MCP service. You will see this same Lorvex account login page. No pairing code or iPad approval is needed for ordinary task changes.")
            .font(.callout)
          Text("Your local database stays available offline. The first synchronization merges your existing tasks into this account. CloudKit sync is disabled while Lorvex Cloud is active to avoid competing sync transports.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Lorvex Cloud")
      .toolbar {
        ToolbarItem(placement:.confirmationAction) {
          Button("Done"){dismiss()}
        }
      }
      .confirmationDialog("Sign out of Lorvex Cloud?",
                          isPresented:$showSignOut,titleVisibility:.visible) {
        Button("Sign out",role:.destructive) {
          Task {await cloud.signOut()}
        }
        Button("Cancel",role:.cancel){}
      } message: {
        Text("Your local tasks will remain. Another cloud account cannot take over this database without a separate export and reset.")
      }
      .onAppear {
        if email.isEmpty { email=cloud.email }
      }
    }
  }

  private func authenticate(register:Bool) {
    let enteredEmail=email
    let enteredPassword=password
    password = ""
    Task {
      await cloud.signIn(email:enteredEmail,password:enteredPassword,register:register)
    }
  }
}
