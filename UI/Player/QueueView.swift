import SwiftUI

/// The Up Next screen. Reorderable and swipe-to-delete, and it keeps the user's
/// explicit queue visually separate from autoplay so it's obvious what will
/// survive the next continuation refill.
struct QueueView: View {

    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    private var explicit: [QueueEntry] {
        player.queue.pending.filter { $0.origin != .autoplay }
    }

    private var autoplay: [QueueEntry] {
        player.queue.pending.filter { $0.origin == .autoplay }
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = player.queue.current {
                    Section("Now playing") {
                        QueueRow(entry: current, isCurrent: true)
                    }
                }

                if !explicit.isEmpty {
                    Section("Next in queue") {
                        ForEach(explicit) { entry in
                            QueueRow(entry: entry, isCurrent: false)
                                .onTapGesture { player.jump(to: entry.id) }
                        }
                        .onDelete { offsets in
                            offsets.map { explicit[$0].id }.forEach(player.removeFromQueue)
                        }
                        .onMove { offsets, destination in
                            player.movePending(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }

                if !autoplay.isEmpty {
                    Section {
                        ForEach(autoplay) { entry in
                            QueueRow(entry: entry, isCurrent: false)
                                .onTapGesture { player.jump(to: entry.id) }
                        }
                        .onDelete { offsets in
                            offsets.map { autoplay[$0].id }.forEach(player.removeFromQueue)
                        }
                    } header: {
                        Text("Autoplay")
                    } footer: {
                        Text("Added automatically to keep the music going. Anything you queue plays first.")
                    }
                }

                if player.queue.pending.isEmpty {
                    Section {
                        Text("Nothing queued yet. Long-press any song to add it here.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !player.queue.pending.isEmpty {
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation { isEditing.toggle() }
                        }
                        Menu {
                            Button(role: .destructive) {
                                player.clearUpNext()
                            } label: {
                                Label("Clear queue", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }
}

private struct QueueRow: View {

    let entry: QueueEntry
    let isCurrent: Bool

    @EnvironmentObject private var player: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: entry.track.artworkURL, cornerRadius: 4)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title)
                    .font(.subheadline)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(entry.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if let duration = entry.track.duration {
                Text(duration.formattedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
