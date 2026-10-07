import SwiftUI

struct RootView: View {

    @EnvironmentObject private var player: PlayerController
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        // The mini player floats above the tab bar and stays put across tabs,
        // which is what makes playback feel continuous.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView(onTap: { showNowPlaying = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: player.currentTrack?.id)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
