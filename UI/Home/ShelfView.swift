import SwiftUI

struct ShelfView: View {

    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title)
                    .font(.title3.bold())
                if let subtitle = shelf.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            switch shelf.style {
            case .quickPicks:
                QuickPicksRow(shelf: shelf)
            case .cards:
                CardsRow(shelf: shelf, circular: false)
            case .circles:
                CardsRow(shelf: shelf, circular: true)
            }
        }
    }
}

/// Paged columns of four track rows, the way Quick Picks works in YouTube Music.
private struct QuickPicksRow: View {

    let shelf: Shelf
    @EnvironmentObject private var player: PlayerController

    private var tracks: [Track] {
        shelf.items.compactMap {
            if case .track(let t) = $0 { return t }
            return nil
        }
    }

    private var columns: [[Track]] {
        stride(from: 0, to: tracks.count, by: 4).map {
            Array(tracks[$0..<min($0 + 4, tracks.count)])
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 0) {
                        ForEach(column) { track in
                            TrackRow(track: track) {
                                // Starting here plays the whole shelf onward,
                                // not just the one track.
                                let index = tracks.firstIndex { $0.id == track.id } ?? 0
                                player.play(tracks: tracks, startingAt: index)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in width - 60 }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

private struct TrackRow: View {

    let track: Track
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerController

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, cornerRadius: 4)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Menu {
                TrackContextMenu(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { TrackContextMenu(track: track) }
    }
}

private struct CardsRow: View {

    let shelf: Shelf
    let circular: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(shelf.items) { item in
                    if case .container(let container) = item {
                        NavigationLink {
                            ContainerView(container: container)
                        } label: {
                            CardView(container: container, circular: circular)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct CardView: View {

    let container: Container
    let circular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: container.artworkURL, cornerRadius: circular ? 70 : 8)
                .frame(width: 140, height: 140)

            Text(container.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle = container.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
    }
}
