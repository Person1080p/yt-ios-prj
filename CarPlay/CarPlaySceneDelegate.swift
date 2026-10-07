import CarPlay
import Combine
import UIKit
import os

/// Owns the CarPlay scene.
///
/// Requires the `com.apple.developer.carplay-audio` entitlement, which Apple
/// grants per developer account on request. Without it this scene never
/// connects — the app still shows up on CarPlay's Now Playing screen via
/// `MPNowPlayingInfoCenter`, but cannot present its own templates.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: "com.example.aura", category: "carplay")

    /// The home template is rebuilt when the feed loads or the playing track
    /// changes, so we keep a handle to swap it in place.
    private var homeTemplate: CPListTemplate?
    private var tabBar: CPTabBarTemplate?
    private var lastRenderedTrackID: String?

    private var environment: AppEnvironment { AppEnvironment.shared }

    // MARK: - Connection

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        log.info("CarPlay connected")

        MainActor.assumeIsolated {
            configureNowPlayingTemplate()
            installRootTemplate()
            observeState()

            // The feed may not have loaded yet if CarPlay connected first.
            Task { await environment.library.refreshHome() }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay disconnected")
        cancellables.removeAll()
        self.interfaceController = nil
        homeTemplate = nil
        tabBar = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: - Templates

    @MainActor
    private func installRootTemplate() {
        let home = makeHomeTemplate()
        homeTemplate = home

        let search = makeSearchTemplate()

        // Three tabs keeps the car UI within glanceable limits; CarPlay allows
        // up to CPTabBarTemplate.maximumTabCount.
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.tabTitle = "Playing"
        nowPlaying.tabImage = UIImage(systemName: "play.circle.fill")

        let tabs = CPTabBarTemplate(templates: [home, search, nowPlaying])
        tabBar = tabs
        interfaceController?.setRootTemplate(tabs, animated: false, completion: nil)
    }

    @MainActor
    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.add(self)
        // Surfaces the queue in the car, which is the CarPlay half of the
        // "easily addable queue" requirement.
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons()
    }

    @MainActor
    private func makeHomeTemplate() -> CPListTemplate {
        CarPlayTemplateBuilder.homeTemplate(
            shelves: environment.library.shelves,
            nowPlayingTrackID: environment.player.currentTrack?.id,
            onSelectTrack: { [weak self] tracks, index in
                self?.playAndShowNowPlaying(tracks: tracks, index: index)
            },
            onSelectContainer: { [weak self] container in
                self?.pushContainer(container)
            }
        )
    }

    @MainActor
    private func makeSearchTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        return template
    }

    // MARK: - Navigation

    @MainActor
    private func pushContainer(_ container: Container) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await self.environment.library.tracks(in: container)
                let template = CarPlayTemplateBuilder.containerTemplate(
                    container: container,
                    tracks: tracks,
                    nowPlayingTrackID: self.environment.player.currentTrack?.id,
                    onSelect: { [weak self] tracks, index in
                        self?.playAndShowNowPlaying(tracks: tracks, index: index)
                    }
                )
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
            } catch {
                self.presentError(error)
            }
        }
    }

    @MainActor
    private func playAndShowNowPlaying(tracks: [Track], index: Int) {
        environment.player.play(tracks: tracks, startingAt: index)
        // Jumping straight to Now Playing after a selection is the expected
        // CarPlay flow and keeps interaction count low while driving.
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    @MainActor
    private func presentError(_ error: Error) {
        let alert = CPAlertTemplate(
            titleVariants: [error.localizedDescription],
            actions: [CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Observation

    @MainActor
    private func observeState() {
        // Rebuild the home list when the feed arrives.
        environment.library.$shelves
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHomeTemplate() }
            .store(in: &cancellables)

        // Keep the playing indicator on the correct row.
        environment.player.$queue
            .map { $0.current?.track.id }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trackID in
                guard let self else { return }
                guard trackID != self.lastRenderedTrackID else { return }
                self.lastRenderedTrackID = trackID
                self.refreshHomeTemplate()
                self.updateNowPlayingButtons()
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func refreshHomeTemplate() {
        guard let homeTemplate else { return }
        let sections = makeHomeTemplate().sections
        // Updating sections in place avoids resetting the car's scroll position.
        homeTemplate.updateSections(sections)
    }

    @MainActor
    private func updateNowPlayingButtons() {
        let player = environment.player
        let shuffle = CPNowPlayingShuffleButton { _ in
            MainActor.assumeIsolated { player.toggleShuffle() }
        }
        let repeatButton = CPNowPlayingRepeatButton { _ in
            MainActor.assumeIsolated { player.cycleRepeatMode() }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, repeatButton])
    }
}

// MARK: - Up Next

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            let template = CarPlayTemplateBuilder.queueTemplate(
                queue: environment.player.queue,
                onSelect: { [weak self] entryID in
                    MainActor.assumeIsolated {
                        self?.environment.player.jump(to: entryID)
                        self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    }
                }
            )
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }
}

// MARK: - Search

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        guard searchText.count >= 2 else {
            completionHandler([])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler([])
                return
            }
            do {
                let results = try await self.environment.library.search(searchText)
                let tracks = Array(results.tracks.prefix(CPListTemplate.maximumItemCount))
                let items = tracks.enumerated().map { index, track -> CPListItem in
                    let item = CPListItem(text: track.title, detailText: track.artist, image: nil)
                    item.handler = { [weak self] _, completion in
                        self?.playAndShowNowPlaying(tracks: tracks, index: index)
                        completion()
                    }
                    return item
                }
                completionHandler(items)
            } catch {
                completionHandler([])
            }
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // The incremental results above are already the full result set.
    }
}
