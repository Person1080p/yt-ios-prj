import CarPlay
import UIKit

/// Converts the source-agnostic home feed into CarPlay templates.
///
/// CarPlay allows no custom UI — only the system templates — so the homepage
/// becomes a `CPListTemplate` whose sections are the shelves. Artwork is loaded
/// asynchronously and pushed into items after the fact, because templates are
/// built synchronously and must not block the car display.
@MainActor
struct CarPlayTemplateBuilder {

    /// CarPlay enforces list limits for driver safety; exceeding them throws.
    /// We clamp rather than risk a runtime trap on an unusually large feed.
    private static var maxSections: Int { CPListTemplate.maximumSectionCount }
    private static var maxItems: Int { CPListTemplate.maximumItemCount }

    /// Rows per shelf in the car. Deliberately tighter than the phone — long
    /// scrollable lists while driving are the thing the HIG warns about.
    private static let rowsPerShelf = 12

    // MARK: - Home

    static func homeTemplate(
        shelves: [Shelf],
        nowPlayingTrackID: String?,
        onSelectTrack: @escaping ([Track], Int) -> Void,
        onSelectContainer: @escaping (Container) -> Void
    ) -> CPListTemplate {

        var sections: [CPListSection] = []

        for shelf in shelves.prefix(maxSections) {
            let visible = Array(shelf.items.prefix(rowsPerShelf))
            guard !visible.isEmpty else { continue }

            // A shelf of tracks plays as a unit, so selecting row N starts the
            // whole shelf at N — same semantics as tapping a phone shelf.
            let shelfTracks: [Track] = visible.compactMap {
                if case .track(let t) = $0 { return t }
                return nil
            }

            var items: [CPListItem] = []
            for element in visible {
                let item = CPListItem(
                    text: element.title,
                    detailText: element.subtitle,
                    image: placeholderImage(for: element)
                )

                switch element {
                case .track(let track):
                    item.isPlaying = (track.id == nowPlayingTrackID)
                    item.playingIndicatorLocation = .trailing
                    let trackIndex = shelfTracks.firstIndex { $0.id == track.id } ?? 0
                    item.handler = { _, completion in
                        onSelectTrack(shelfTracks, trackIndex)
                        completion()
                    }
                case .container(let container):
                    item.accessoryType = .disclosureIndicator
                    item.handler = { _, completion in
                        onSelectContainer(container)
                        completion()
                    }
                }

                attachArtwork(from: element.artworkURL, to: item)
                items.append(item)
            }

            sections.append(CPListSection(items: items, header: shelf.title, sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "Home", sections: sections)
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house.fill")
        if sections.isEmpty {
            template.emptyViewSubtitleVariants = ["Nothing to play yet. Open the app on your phone to set up a source."]
        }
        return template
    }

    // MARK: - Container detail

    static func containerTemplate(
        container: Container,
        tracks: [Track],
        nowPlayingTrackID: String?,
        onSelect: @escaping ([Track], Int) -> Void
    ) -> CPListTemplate {

        let visible = Array(tracks.prefix(maxItems))
        let items = visible.enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artist, image: nil)
            item.isPlaying = (track.id == nowPlayingTrackID)
            item.playingIndicatorLocation = .trailing
            item.handler = { _, completion in
                onSelect(visible, index)
                completion()
            }
            attachArtwork(from: track.artworkURL, to: item)
            return item
        }

        let template = CPListTemplate(
            title: container.title,
            sections: [CPListSection(items: items)]
        )
        return template
    }

    // MARK: - Up Next

    /// The queue, reachable from the Now Playing screen's Up Next button.
    static func queueTemplate(
        queue: PlayQueue,
        onSelect: @escaping (QueueEntry.ID) -> Void
    ) -> CPListTemplate {

        var sections: [CPListSection] = []

        if let current = queue.current {
            let item = CPListItem(text: current.track.title, detailText: current.track.artist, image: nil)
            item.isPlaying = true
            item.playingIndicatorLocation = .trailing
            item.handler = { _, completion in completion() }
            attachArtwork(from: current.track.artworkURL, to: item)
            sections.append(CPListSection(items: [item], header: "Now Playing", sectionIndexTitle: nil))
        }

        // Keep the user's explicit queue visually distinct from autoplay, the
        // same split the phone UI shows.
        let explicit = queue.pending.filter { $0.origin != .autoplay }
        let auto = queue.pending.filter { $0.origin == .autoplay }

        if !explicit.isEmpty {
            sections.append(CPListSection(
                items: explicit.prefix(maxItems).map { entry in queueItem(entry, onSelect: onSelect) },
                header: "Next in Queue",
                sectionIndexTitle: nil
            ))
        }

        if !auto.isEmpty {
            let remaining = max(0, maxItems - explicit.count)
            sections.append(CPListSection(
                items: auto.prefix(remaining).map { entry in queueItem(entry, onSelect: onSelect) },
                header: "Autoplay",
                sectionIndexTitle: nil
            ))
        }

        let template = CPListTemplate(title: "Up Next", sections: sections)
        template.emptyViewSubtitleVariants = ["Nothing queued."]
        return template
    }

    private static func queueItem(
        _ entry: QueueEntry,
        onSelect: @escaping (QueueEntry.ID) -> Void
    ) -> CPListItem {
        let item = CPListItem(text: entry.track.title, detailText: entry.track.artist, image: nil)
        item.handler = { _, completion in
            onSelect(entry.id)
            completion()
        }
        attachArtwork(from: entry.track.artworkURL, to: item)
        return item
    }

    // MARK: - Artwork

    /// Use a cached image immediately if we have one; CarPlay renders the
    /// template before any async work can finish.
    private static func placeholderImage(for item: ShelfItem) -> UIImage? {
        guard let url = item.artworkURL else { return nil }
        return ArtworkLoader.shared.cachedImageSync(for: url)
    }

    private static func attachArtwork(from url: URL?, to item: CPListItem) {
        guard let url else { return }
        let target = CPListItem.maximumImageSize
        Task {
            guard let image = await ArtworkLoader.shared.image(for: url) else { return }
            let sized = ArtworkLoader.resize(image, to: target)
            await MainActor.run { item.setImage(sized) }
        }
    }
}
