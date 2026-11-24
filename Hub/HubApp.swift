import SwiftUI

/// Was gerade offen ist (damit Widgets / Dynamic Island direkt in den Player springen können)
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var showPlayer = false
}

@main
struct HubApp: App {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var lyrics = Lyrics.shared
    @ObservedObject private var alarms = Alarms.shared
    @ObservedObject private var nav = Nav.shared
    @State private var setUp = Config.isSetUp
    @Environment(\.scenePhase) private var phase

    init() {
        // Player sofort bereit – auch wenn iOS die App nur im Hintergrund für einen Widget-Knopf startet
        Player.shared.library = Library.shared
        Player.shared.lyrics = Lyrics.shared
    }

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
            .environmentObject(nav)
            .tint(.purple)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                if url.scheme == "hubapp", url.host == "player" { nav.showPlayer = true; return }
                if Config.apply(link: url) { setUp = true; Task { await start() } }
            }
            .task { if setUp { await start() } }
            .onChange(of: phase) { _, p in
                if p == .active && setUp { Task { await start() } }
            }
        }
    }

    /// Beim Öffnen: Playlist + fehlende Songs vom PC, Weckzeiten, Lyrics vorab (alles nur, wenn der PC erreichbar ist)
    @MainActor
    private func start() async {
        await library.refresh()
        await alarms.refresh()
        if library.pcOnline { await lyrics.prefetch(library.tracks) }
    }
}
