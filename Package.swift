// swift-tools-version:5.9
//
// A test harness over the portable part of the app — NOT the app itself.
//
// The target is named `Aura` to match the Xcode target, so the same test files
// compile in both places with one `@testable import Aura`.
//
// The iOS app is built from `project.yml` with XcodeGen and needs Xcode. This
// package compiles only the source and queue layers, which import nothing but
// Foundation, so the logic can be built and tested on any machine including
// Linux CI. That is deliberate: keeping adapters free of UIKit/AVFoundation is
// what makes them testable at all.
//
//   swift test     # the whole suite
//   swift build    # type-check only
//
import PackageDescription

let package = Package(
    name: "Aura",
    targets: [
        .target(
            name: "Aura",
            path: ".",
            // Everything that imports an Apple framework, plus the app itself.
            exclude: [
                "Tests",
                "App",
                "UI",
                "CarPlay",
                "docs",
                "Support/README.md",
                "project.yml",
                "README.md",
                "Core/Playback/AudioSessionManager.swift",
                "Core/Playback/NowPlayingCenter.swift",
                "Core/Playback/PlayerController.swift",
                "Core/Playback/Engines/AVPlayerEngine.swift",
                "Core/Playback/Engines/YouTubeEmbedEngine.swift",
                "Core/Sources/LocalLibrarySource.swift",
                "Core/Util/ArtworkLoader.swift",
                "Core/Util/SubsonicCredentials.swift",
                "Core/Scrobbling/ScrobbleCoordinator.swift",
                "Core/Util/ScrobblerAccountStore.swift"
            ],
            // Listed explicitly rather than by directory, because the rest of
            // Core/ imports Apple frameworks that don't exist off-device.
            sources: [
                "Core/Models.swift",
                "Core/MusicSource.swift",
                "Core/Playback/PlayQueue.swift",
                "Core/Playback/Engines/PlaybackEngine.swift",
                "Core/Util/MD5.swift",
                "Core/Util/TrackMatcher.swift",
                "Core/Util/YouTubeConfiguration.swift",
                "Core/Scrobbling/Scrobbler.swift",
                "Core/Scrobbling/ScrobbleTracker.swift",
                "Core/Scrobbling/AudioScrobblerService.swift",
                "Core/Scrobbling/ScrobbleQueue.swift",
                "Core/Sources/DemoSource.swift",
                "Core/Sources/SubsonicSource.swift",
                "Core/Sources/YouTubeSource.swift",
                "Core/Sources/MatchingSource.swift",
                "Support/PlatformShims.swift"
            ]
        ),
        .testTarget(
            name: "AuraTests",
            dependencies: ["Aura"],
            path: "Tests"
        )
    ]
)
