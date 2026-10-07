import UIKit
import os

/// Small artwork cache shared by the phone UI, the Now Playing centre and CarPlay.
///
/// The cache itself is a `nonisolated let` because `NSCache` is already
/// thread-safe, which lets CarPlay read it synchronously while template
/// construction is on the main thread. Only the network coalescing is actor-isolated.
actor ArtworkLoader {

    static let shared = ArtworkLoader()

    private nonisolated let cache: NSCache<NSURL, UIImage>
    private nonisolated let session: URLSession
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 240
        // ~64 MB of decoded images.
        cache.totalCostLimit = 64 * 1024 * 1024
        self.cache = cache

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024,
                                   diskPath: "aura-artwork")
        self.session = URLSession(configuration: config)
    }

    /// Already-decoded image, if present. Safe to call from any thread, and
    /// never touches the network — CarPlay uses this when building a template.
    nonisolated func cachedImageSync(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }

        // Coalesce concurrent requests for the same URL — the home feed asks
        // for the same album art from several shelves at once.
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                return UIImage(data: data)
            } catch {
                return nil
            }
        }
        inFlight[url] = task

        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.estimatedByteSize)
        }
        return image
    }

    /// Downscale for a requested size. `MPMediaItemArtwork` calls its handler
    /// with whatever bounds the consumer wants, including the car display.
    nonisolated static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIImage {
    var estimatedByteSize: Int {
        guard let cg = cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
