import SwiftUI

struct MiniPlayerView: View {

    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            // Hairline progress bar, flush to the top edge.
            GeometryReader { geometry in
                Rectangle()
                    .fill(.white)
                    .frame(width: geometry.size.width * player.progress)
            }
            .frame(height: 2)
            .background(.white.opacity(0.15))

            HStack(spacing: 12) {
                Artwork(url: player.currentTrack?.artworkURL, cornerRadius: 4)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if player.isLoading {
                    ProgressView().controlSize(.small).frame(width: 36)
                } else {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                }

                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 36)
                }
                .disabled(!player.queue.canGoForward)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
