import SwiftUI

struct NowPlayingView: View {

    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    /// While the user drags, show their position rather than the player's.
    @State private var scrubPosition: TimeInterval?

    private var track: Track? { player.currentTrack }

    var body: some View {
        VStack(spacing: 0) {
            handle

            Spacer(minLength: 12)

            Artwork(url: track?.artworkURL, cornerRadius: 12)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 32)
                .shadow(radius: 24, y: 8)

            Spacer(minLength: 24)

            titleBlock
            scrubber
            transportControls
            secondaryControls

            Spacer(minLength: 8)
        }
        .padding(.bottom, 24)
        .background(.black)
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }

    private var handle: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
            }
            Spacer()
            if let error = player.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .foregroundStyle(.white)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? "Nothing playing")
                .font(.title2.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(track?.artist ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 32)
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.elapsed },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration ?? 1, 1),
                onEditingChanged: { editing in
                    // Commit on release so we don't fire a seek per pixel.
                    if !editing, let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
            )
            .disabled(player.duration == nil)
            .tint(.white)

            HStack {
                Text((scrubPosition ?? player.elapsed).formattedDuration)
                Spacer()
                Text((player.duration ?? track?.duration ?? 0).formattedDuration)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.title)
            }

            Button(action: player.togglePlayPause) {
                ZStack {
                    Circle().fill(.white).frame(width: 68, height: 68)
                    if player.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.black)
                    }
                }
            }

            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.title)
            }
            .disabled(!player.queue.canGoForward)
        }
        .foregroundStyle(.white)
        .padding(.top, 20)
    }

    private var secondaryControls: some View {
        HStack(spacing: 44) {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.queue.isShuffled ? Color.accentColor : .secondary)
            }

            Button(action: player.cycleRepeatMode) {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.queue.repeatMode == .off ? .secondary : Color.accentColor)
            }

            Button { showQueue = true } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title3)
        .padding(.top, 24)
    }
}
