import SwiftUI

struct AccountPickerView: View {
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var token = ""
    @State private var isBot = false
    @State private var accountToRemove: SavedAccount?

    var body: some View {
        List {
            ForEach(Array(authStore.accounts.enumerated()), id: \.element.id) { index, account in
                HStack(spacing: 6) {
                    Button {
                        if authStore.selectAccount(id: account.id) { dismiss() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: account.id == authStore.activeAccountID ? "checkmark.circle.fill" : "person.crop.circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.user?.displayName ?? "Account \(index + 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(account.user?.handle ?? (account.isBot ? "Bot · Not verified" : "Not verified"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) { accountToRemove = account } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(account.displayName)")
                }
            }
            Button { showAdd = true } label: {
                Label("Add Account", systemImage: "plus")
            }
            Text("Add a token here, or log in to another account on iPhone and sync it. Saved tokens stay on this watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Accounts")
        .confirmationDialog("Remove this account from this watch?", isPresented: Binding(
            get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                if let account = accountToRemove { _ = authStore.removeAccount(id: account.id) }
                accountToRemove = nil
            }
        }
        .sheet(isPresented: $showAdd) {
            ScrollView {
                VStack(spacing: 10) {
                    Text("Add Account").font(.headline)
                    SecureField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Bot Token", isOn: $isBot)
                    Button("Save and Switch") {
                        if authStore.setCredentials(token: token, isBot: isBot) {
                            token = ""
                            showAdd = false
                            dismiss()
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}
