import SwiftUI

/// Scrobbler accounts. Last.fm, Libre.fm and any GNU FM instance all speak the
/// same API, so adding a custom one is just an endpoint and a login.
struct ScrobbleSettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var accounts: [ScrobblerAccount] = ScrobblerAccountStore.shared.accounts()
    @State private var editing: ScrobblerAccount?
    @State private var showAddCustom = false

    var body: some View {
        Form {
            if accounts.isEmpty {
                Section {
                    Text("No scrobblers yet. Your listening history stays on your own devices until you add one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Accounts") {
                    ForEach(accounts) { account in
                        AccountRow(account: account) {
                            editing = account
                        } onToggle: { isEnabled in
                            ScrobblerAccountStore.shared.setEnabled(isEnabled, for: account.id)
                            reload()
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { accounts[$0].id }.forEach(ScrobblerAccountStore.shared.remove)
                        reload()
                    }
                }
            }

            Section("Add") {
                Button("Last.fm") {
                    editing = ScrobblerAccount.lastFM(apiKey: "", apiSecret: "")
                }
                Button("Libre.fm") {
                    editing = ScrobblerAccount.libreFM()
                }
                Button("Custom GNU FM server…") {
                    showAddCustom = true
                }
            }

            Section {
                HStack {
                    Text("Queued plays")
                    Spacer()
                    Text("\(environment.scrobbling.pendingCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if environment.scrobbling.pendingCount > 0 {
                    Button("Send now") {
                        Task { await environment.scrobbling.drain() }
                    }
                    Button("Discard queued plays", role: .destructive) {
                        Task { await environment.scrobbling.clearQueue() }
                    }
                }

                if let error = environment.scrobbling.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Queue")
            } footer: {
                Text("Plays are queued when offline and submitted later with their original timestamps, so a drive through a tunnel doesn't lose anything.")
            }

            Section {
                Text("A play is submitted once it has run for half the track's length, or four minutes, whichever comes first. Tracks under 30 seconds are never scrobbled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Scrobbling")
        .sheet(item: $editing) { account in
            ScrobblerSignInView(account: account) {
                reload()
                editing = nil
            }
        }
        .sheet(isPresented: $showAddCustom) {
            CustomScrobblerView { account in
                editing = account
                showAddCustom = false
            }
        }
    }

    private func reload() {
        accounts = ScrobblerAccountStore.shared.accounts()
        environment.reloadScrobblers()
    }
}

// MARK: - Rows

private struct AccountRow: View {

    let account: ScrobblerAccount
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.subheadline)
                if let username = account.username {
                    Text(username).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not signed in").font(.caption).foregroundStyle(.orange)
                }
                Text(account.endpoint.host() ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if account.sessionKey?.isEmpty == false {
                Toggle("", isOn: Binding(
                    get: { account.isEnabled },
                    set: onToggle
                ))
                .labelsHidden()
            } else {
                Button("Sign in", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}

// MARK: - Sign-in

private struct ScrobblerSignInView: View {

    let account: ScrobblerAccount
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String
    @State private var apiSecret: String
    @State private var username = ""
    @State private var password = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, working, failed(String)
    }

    /// Last.fm issues API keys; GNU FM servers ignore them, so the fields are
    /// only shown where they matter.
    private var needsAPICredentials: Bool { account.id == "lastfm" }

    init(account: ScrobblerAccount, onDone: @escaping () -> Void) {
        self.account = account
        self.onDone = onDone
        _apiKey = State(initialValue: account.apiKey)
        _apiSecret = State(initialValue: account.apiSecret)
        _username = State(initialValue: account.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsAPICredentials {
                    Section {
                        TextField("API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Shared secret", text: $apiSecret)
                    } header: {
                        Text("API credentials")
                    } footer: {
                        Text("Create these at last.fm/api/account/create. They identify this app, not you.")
                    }
                }

                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("Sign in to \(account.displayName)")
                } footer: {
                    switch status {
                    case .failed(let message):
                        Text(message).foregroundStyle(.orange)
                    default:
                        Text("Your password is exchanged for a session key and is not stored.")
                    }
                }

                Section {
                    Button {
                        signIn()
                    } label: {
                        HStack {
                            Text("Sign in")
                            if status == .working {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(account.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard status != .working, !username.isEmpty, !password.isEmpty else { return false }
        return needsAPICredentials ? !apiKey.isEmpty && !apiSecret.isEmpty : true
    }

    private func signIn() {
        status = .working

        var candidate = account
        candidate.apiKey = apiKey.isEmpty ? "aura" : apiKey
        candidate.apiSecret = apiSecret.isEmpty ? "aura" : apiSecret

        let service = AudioScrobblerService(account: candidate)
        Task {
            do {
                try await service.authenticate(username: username, password: password)
                ScrobblerAccountStore.shared.save(service.account)
                onDone()
                dismiss()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Custom server

private struct CustomScrobblerView: View {

    let onCreate: (ScrobblerAccount) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""

    private var normalized: URL? { ScrobblerAccount.normalizeEndpoint(host) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("fm.example.com", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("GNU FM server")
                } footer: {
                    if let normalized {
                        Text("API endpoint: \(normalized.absoluteString)")
                            .font(.caption.monospaced())
                    } else {
                        Text("Anything implementing the AudioScrobbler 2.0 API works. The /2.0/ path is added automatically.")
                    }
                }

                Section {
                    Button("Continue") {
                        guard let account = ScrobblerAccount.custom(
                            id: "custom-\(UUID().uuidString.prefix(8))",
                            displayName: name.isEmpty ? (normalized?.host() ?? "Custom") : name,
                            host: host
                        ) else { return }
                        onCreate(account)
                    }
                    .disabled(normalized == nil)
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Helpers

/// `sheet(item:)` for a non-Identifiable-by-default payload.
private extension View {
    func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}
