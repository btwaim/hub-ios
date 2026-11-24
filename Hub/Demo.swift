import Foundation
import SwiftUI

/// Vorführmodus nur für die automatischen Screenshots im Simulator (Start mit `-demoScreen <name>`).
/// Im normalen Betrieb passiert hier nichts.
enum Demo {
    static let screen: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demoScreen"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    @MainActor
    static func setup() {
        guard let screen else { return }
        let base = "https://i.scdn.co/image/"
        func track(_ id: String, _ title: String, _ artist: String, _ img: String, _ fx: Fx?) -> Track {
            Track(id: id, uri: nil, title: title, artist: artist, cover: base + "ab67616d00004851" + img, big: base + "ab67616d0000b273" + img,
                  album: nil, duration: 212_307, fx: fx, key: nil)
        }
        let tracks = [
            track("demo1", "Insomniac", "Memo Boy, Chakra Efendi", "fd062989b0b63b82f5949524", Fx(rate: 1.1, bass: 25, reverb: false)),
            track("demo2", "My Alcoholic Friends", "The Dresden Dolls", "fd062989b0b63b82f5949524", nil),
            track("demo3", "Where Is My Mind?", "Pixies", "fd062989b0b63b82f5949524", Fx(rate: 1.25, bass: 0, reverb: false)),
        ]
        Library.shared.demo(tracks)
        let lrc = #"[[0,"Beneath soft pillows and wool"],[3000,"Pristine hearts made of gold and jewel"],[6000,"A love pure so rich and full",[[6000,"A"],[6300,"love"],[6800,"pure"],[7300,"so"],[7600,"rich"],[8200,"and"],[8500,"full"]]],[9000,"I can see it in your eyes"],[12000,"All of the things that I've lost, I will find again"],[15000,"Everything I've done doesn't define what I am"]]"#
        let lines = (try? JSONDecoder().decode([LyricLine].self, from: Data(lrc.utf8))) ?? []
        Lyrics.shared.demo("demo1", lines)
        Player.shared.demo(tracks[0], at: 7.2 / 1.1)

        let state = #"{"greeting":"Guten Abend, Demo","sleep":"1. Stunde Mi: offline 22:00, spätestens 22:30, Wecker 06:25","gta":"ist da!","nextExam":{"title":"Physikarbeit (Klausur)","when":"morgen"},"school":{"label":"Morgen","lessons":[{"start":"07:30","subject":"De","room":"K 2","kind":"normal"},{"start":"08:20","subject":"Ma","room":"K 2","kind":"cancel"},{"start":"09:25","subject":"Ph","room":"N 1","kind":"change"}]},"events":[{"title":"Physikarbeit","type":"exam","when":"morgen"},{"title":"Geburtstag Max","type":"birthday","when":"Fr"}],"watch":[{"id":"w1","title":"Code Geass","image":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx1575-hsmWM2ydNm1m.jpg","progress":"14 / 25 Folgen","pct":56,"newEp":true}]}"#
        if let s = try? JSONDecoder().decode(HubState.self, from: Data(state.utf8)) { Library.shared.demoHub(s) }
        let days = #"[{"date":"2026-11-25","free":false,"wake":"06:25","label":"Mi","period":1,"subject":"De"},{"date":"2026-11-26","free":false,"wake":"07:25","label":"Do","period":2,"subject":"Ma"},{"date":"2026-11-28","free":true,"label":"Wochenende"}]"#
        if let d = try? JSONDecoder().decode([WakeDay].self, from: Data(days.utf8)) { Alarms.shared.demo(d) }

        UserDefaults.standard.set(screen == "lyrics" ? 1 : screen == "mp3" ? 2 : 0, forKey: "playerMode")
        let nav = Nav.shared
        switch screen {
        case "music": nav.tab = 1
        case "player", "lyrics", "mp3": nav.showPlayer = true
        case "alarms": nav.showAlarms = true
        case "map": nav.showMap = true
        case "gaming": nav.tab = 4
        default: nav.tab = 0
        }
    }
}
