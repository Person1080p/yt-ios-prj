import SwiftUI

/// The homepage: a vertical stack of horizontally scrolling shelves, which is
/// the shape of the YouTube Music feed.
struct HomeView: View {

    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if library.isLoadingHome && library.shelves.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let error = library.homeError, library.shelves.isEmpty {
                    EmptyFeedView(message: error) {
                        Task { await library.refreshHome(force: true) }
                    }
                } else {
                    ForEach(library.shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Home")
        .refreshable { await library.refreshHome(force: true) }
        .task { await library.refreshHome() }
    }
}

private struct EmptyFeedView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing to show")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}
