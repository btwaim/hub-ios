import SwiftUI

@main
struct HubApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = Player()
    @StateObject private var lyrics = Lyrics()
    @StateObject private var alarms = Alarms()
    @State private var setUp = Config.isSetUp
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if setUp {
                    RootView()
                } else {
                    SetupView { setUp = true; Task { await start() } }
                }
            }
            .environmentObject(library)
            .environmentObject(player)
            .environmentObject(lyrics)
            .environmentObject(alarms)
            .tint(.purple)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                if Config.apply(link: url) { setUp = true; Task { await start() } }
            }
            .task {
                player.library = library
                if setUp { await start() }
            }
            .onChange(of: phase) { _, p in
                if p == .active && setUp { Task { await start() } }
            }
        }
    }

    /// Beim Öffnen: Playlist + fehlende Songs vom PC, Weckzeiten, Lyrics vorab (alles nur, wenn der PC erreichbar ist)
    @MainActor
    private func start() async {
        player.library = library
        await library.refresh()
        await alarms.refresh()
        if library.pcOnline { await lyrics.prefetch(library.tracks) }
    }
}
