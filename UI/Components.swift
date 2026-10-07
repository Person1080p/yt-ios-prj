import SwiftUI

/// Async artwork backed by the shared `ArtworkLoader`, so the phone UI, the
/// lock screen and CarPlay all share one cache and one set of downloads.
struct Artwork: View {

    let url: URL?
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ArtworkLoader.shared.cachedImageSync(for: url) {
                image = cached
                return
            }
            image = await ArtworkLoader.shared.image(for: url)
        }
    }
}

/// Context menu shared by every track row in the app, so "Play next" and
/// "Add to queue" are always one long-press away.
struct TrackContextMenu: View {

    let track: Track
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Button {
            player.playNext([track])
        } label: {
            Label("Play next", systemImage: "text.insert")
        }

        Button {
            player.addToQueue([track])
        } label: {
            Label("Add to queue", systemImage: "text.append")
        }

        Divider()

        Button {
            player.play(track: track)
        } label: {
            Label("Play now", systemImage: "play.fill")
        }
    }
}

extension TimeInterval {
    /// m:ss, or h:mm:ss past an hour.
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
