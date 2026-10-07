import Foundation
import MediaPlayer
import UIKit

/// Publishes the current track to the lock screen, Control Center and CarPlay,
/// and wires the hardware/CarPlay transport buttons back to the player.
///
/// CarPlay's Now Playing screen is driven entirely by `MPNowPlayingInfoCenter`
/// and `MPRemoteCommandCenter` — there is no separate CarPlay metadata API — so
/// keeping this accurate is what makes the car UI correct.
@MainActor
final class NowPlayingCenter {

    /// Transport intents coming from outside the app (lock screen, steering
    /// wheel buttons, CarPlay, headphones).
    struct Handlers {
        var play: () -> Void = {}
        var pause: () -> Void = {}
        var next: () -> Void = {}
        var previous: () -> Void = {}
        var seek: (TimeInterval) -> Void = { _ in }
    }

    private var handlers = Handlers()
    private var artworkTask: Task<Void, Never>?
    private var artworkCacheKey: URL?

    func setHandlers(_ handlers: Handlers) {
        self.handlers = handlers
        registerCommands()
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            self?.handlers.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlers.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if MPNowPlayingInfoCenter.default().playbackState == .playing {
                self.handlers.pause()
            } else {
                self.handlers.play()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handlers.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlers.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.handlers.seek(event.positionTime)
            return .success
        }

        // Scrubbing is only offered when we actually know the duration; enabled
        // per-track in `update(...)`.
        center.changePlaybackPositionCommand.isEnabled = false
    }

    func setCommandsEnabled(canGoNext: Bool, canGoPrevious: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canGoNext
        center.previousTrackCommand.isEnabled = canGoPrevious
    }

    /// Push the full metadata payload. Called on track change and whenever
    /// play/pause or the elapsed time changes materially.
    func update(track: Track?, elapsed: TimeInterval, duration: TimeInterval?, rate: Float) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            artworkTask?.cancel()
            artworkCacheKey = nil
            return
        }

        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyAlbumTitle] = track.album
        info[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        let resolvedDuration = duration ?? track.duration
        if let resolvedDuration {
            info[MPMediaItemPropertyPlaybackDuration] = resolvedDuration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }

        // Drop stale artwork immediately on track change so the car never shows
        // the previous song's cover next to the new title.
        if artworkCacheKey != track.artworkURL {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused

        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = resolvedDuration != nil

        loadArtworkIfNeeded(for: track)
    }

    private func loadArtworkIfNeeded(for track: Track) {
        guard let url = track.artworkURL else {
            artworkTask?.cancel()
            artworkCacheKey = nil
            return
        }
        guard artworkCacheKey != url else { return }

        artworkCacheKey = url
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await ArtworkLoader.shared.image(for: url) else { return }
            guard !Task.isCancelled else { return }
            guard let self, self.artworkCacheKey == url else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { requested in
                ArtworkLoader.resize(image, to: requested)
            }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
