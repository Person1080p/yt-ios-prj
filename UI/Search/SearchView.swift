import SwiftUI

struct SearchView: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerController

    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if isSearching && results.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }

            if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            if !results.tracks.isEmpty {
                Section("Songs") {
                    ForEach(Array(results.tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(tracks: results.tracks, startingAt: index)
                        } label: {
                            SearchTrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackContextMenu(track: track) }
                        .swipeActions(edge: .trailing) {
                            Button {
                                player.addToQueue([track])
                            } label: {
                                Label("Queue", systemImage: "text.append")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }

            containerSection("Albums", results.albums)
            containerSection("Artists", results.artists)
            containerSection("Playlists", results.playlists)

            if !query.isEmpty, results.isEmpty, !isSearching, error == nil {
                Text("No results for “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Songs, albums, artists")
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    @ViewBuilder
    private func containerSection(_ title: String, _ containers: [Container]) -> some View {
        if !containers.isEmpty {
            Section(title) {
                ForEach(containers) { container in
                    NavigationLink {
                        ContainerView(container: container)
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: container.artworkURL,
                                    cornerRadius: container.kind == .artist ? 22 : 4)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(container.title).font(.subheadline).lineLimit(1)
                                if let subtitle = container.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Debounced so typing doesn't fire a request per keystroke.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = SearchResults()
            error = nil
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            isSearching = true
            error = nil
            do {
                let found = try await library.search(trimmed)
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                results = SearchResults()
            }
            isSearching = false
        }
    }
}

private struct SearchTrackRow: View {

    let track: Track
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, cornerRadius: 4)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .foregroundStyle(player.currentTrack?.id == track.id ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
