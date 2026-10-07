import SwiftUI

/// Album / playlist / artist detail.
struct ContainerView: View {

    let container: Container

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerController

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Artwork(url: container.artworkURL,
                            cornerRadius: container.kind == .artist ? 80 : 10)
                        .frame(width: 160, height: 160)

                    Text(container.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    if let subtitle = container.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            player.play(tracks: tracks, startingAt: 0)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            player.play(tracks: tracks.shuffled(), startingAt: 0)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(tracks.isEmpty)
                    .padding(.top, 4)

                    Button {
                        player.addToQueue(tracks)
                    } label: {
                        Label("Add all to queue", systemImage: "text.append")
                            .font(.subheadline)
                    }
                    .disabled(tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowSeparator(.hidden)

            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let error {
                Text(error).foregroundStyle(.orange).font(.subheadline)
            } else {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(tracks: tracks, startingAt: index)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.subheadline)
                                        .foregroundStyle(player.currentTrack?.id == track.id
                                                         ? Color.accentColor : .primary)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                if let duration = track.duration {
                                    Text(duration.formattedDuration)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
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
        }
        .listStyle(.plain)
        .navigationTitle(container.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                tracks = try await library.tracks(in: container)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
