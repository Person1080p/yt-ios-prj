import SwiftUI
import UIKit

struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var selectedKind = SourceFactory.preferredKind

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: $selectedKind) {
                    ForEach(SourceFactory.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedKind) { _, newValue in
                    SourceFactory.preferredKind = newValue
                    environment.switchSource(to: SourceFactory.make(newValue))
                }

                Text(environment.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Active source")
            }

            switch selectedKind {
            case .subsonic:
                SubsonicSettingsSection()
            case .hybrid:
                HybridSettingsSection()
                SubsonicSettingsSection()
                YouTubeSettingsSection()
            case .youTube:
                YouTubeSettingsSection()
            case .local:
                LocalLibrarySettingsSection()
            case .demo:
                EmptyView()
            }

            Section {
                NavigationLink {
                    ScrobbleSettingsView()
                } label: {
                    HStack {
                        Text("Scrobbling")
                        Spacer()
                        if environment.scrobbling.hasActiveScrobbler {
                            Text("\(environment.scrobbling.scrobblers.count) active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Off").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Listening history")
            } footer: {
                Text("Last.fm, Libre.fm, or any GNU FM server.")
            }

            Section {
                Label("This app shows no advertising and collects no analytics.",
                      systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Self-hosted

private struct SubsonicSettingsSection: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var host = SubsonicCredentials.shared.host?.absoluteString ?? ""
    @State private var username = SubsonicCredentials.shared.username ?? ""
    @State private var password = SubsonicCredentials.shared.password ?? ""
    @State private var status: ConnectionStatus = .idle

    var body: some View {
        Section {
            TextField("myserver.example.com", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $password)

            Button {
                connect()
            } label: {
                HStack {
                    Text("Connect")
                    if status == .testing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(host.isEmpty || username.isEmpty || password.isEmpty || status == .testing)

            Button("Sign out", role: .destructive) {
                SubsonicCredentials.shared.clear()
                host = ""; username = ""; password = ""
                status = .idle
            }
        } header: {
            Text("Self-hosted server")
        } footer: {
            switch status {
            case .success:
                Text("Connected.").foregroundStyle(.green)
            case .failure(let message):
                Text(message).foregroundStyle(.orange)
            default:
                Text("Works with Navidrome, Airsonic, Gonic and anything else speaking the Subsonic API. Prefer https://.")
            }
        }
    }

    private func connect() {
        guard let url = SubsonicCredentials.normalizeHost(host) else {
            status = .failure("That server address doesn't look valid.")
            return
        }

        status = .testing
        let credentials = SubsonicCredentials.shared
        credentials.host = url
        credentials.username = username
        credentials.password = password

        Task {
            let source = SubsonicSource()
            do {
                try await source.ping()
                status = .success
                host = url.absoluteString
                environment.switchSource(to: source)
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Hybrid

private struct HybridSettingsSection: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var fallback = SourceFactory.hybridFallback

    var body: some View {
        Section {
            Picker("Tracks I don't own", selection: $fallback) {
                ForEach(MatchingSource.Fallback.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: fallback) { _, newValue in
                SourceFactory.hybridFallback = newValue
                environment.switchSource(to: SourceFactory.make(.hybrid))
            }
        } header: {
            Text("Hybrid")
        } footer: {
            switch fallback {
            case .hideUnmatched:
                Text("Browse YouTube's charts and playlists, play from your own server. Anything your library doesn't have is hidden, so there are never any ads. Needs both backends set up below.")
            case .useDiscovery:
                Text("Tracks your library doesn't have stream from YouTube instead — those will play ads unless you're signed in with Premium.")
            }
        }
    }
}

// MARK: - YouTube

private struct YouTubeSettingsSection: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var apiKey = YouTubeConfiguration.shared.apiKey ?? ""
    @State private var playlistIDs = YouTubeConfiguration.shared.playlistIDs
    @State private var newPlaylist = ""
    @State private var showSignIn = false

    var body: some View {
        Group {
            Section {
                SecureField("Data API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKey)

                Button("Save key", action: saveKey)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("YouTube Data API")
            } footer: {
                Text("Create a key in Google Cloud Console with the YouTube Data API v3 enabled. The free quota is 10,000 units/day; each search costs 100.")
            }

            Section {
                ForEach(playlistIDs, id: \.self) { id in
                    Text(id).font(.caption.monospaced())
                }
                .onDelete { offsets in
                    offsets.map { playlistIDs[$0] }.forEach(YouTubeConfiguration.shared.removePlaylist)
                    playlistIDs = YouTubeConfiguration.shared.playlistIDs
                    reload()
                }

                HStack {
                    TextField("Playlist URL or ID", text: $newPlaylist)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        YouTubeConfiguration.shared.addPlaylist(newPlaylist)
                        playlistIDs = YouTubeConfiguration.shared.playlistIDs
                        newPlaylist = ""
                        reload()
                    }
                    .disabled(YouTubeConfiguration.extractPlaylistID(newPlaylist) == nil)
                }
            } header: {
                Text("Homepage playlists")
            } footer: {
                Text("The Data API exposes no personalised feed, so the homepage is the trending music chart plus the playlists you add here.")
            }

            Section {
                Button("Sign in to YouTube") { showSignIn = true }

                Button("Sign out", role: .destructive) {
                    Task { await YouTubeEmbedEngine.signOut() }
                }
            } header: {
                Text("Premium playback")
            } footer: {
                Text("The embedded player serves YouTube's ads. Signing in with a YouTube Premium account removes them, because playback is then covered by your subscription.")
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInWebView()
        }
    }

    private func saveKey() {
        YouTubeConfiguration.shared.apiKey = apiKey
        reload()
    }

    private func reload() {
        environment.switchSource(to: YouTubeSource())
    }
}

/// Hosts the real YouTube sign-in page so a Premium subscription applies to the
/// embedded player.
private struct SignInWebView: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = YouTubeEmbedEngine.makeSignInViewController()
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

// MARK: - On-device library

private struct LocalLibrarySettingsSection: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var isAuthorized = LocalLibrarySource().isConfigured

    var body: some View {
        Section {
            if isAuthorized {
                Label("Library access granted", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Button("Allow access to my music") {
                    Task {
                        isAuthorized = await LocalLibrarySource.requestAuthorization()
                        if isAuthorized {
                            environment.switchSource(to: LocalLibrarySource())
                        }
                    }
                }
            }
        } header: {
            Text("On this iPhone")
        } footer: {
            Text("Plays DRM-free music synced to the device. iOS exposes no playable file for Apple Music streaming items, so those are hidden.")
        }
    }
}

// MARK: - Shared

private enum ConnectionStatus: Equatable {
    case idle, testing, success, failure(String)
}
