import Foundation
import Network

/// WiZ-Lampen direkt im WLAN schalten (UDP 38899, wie der Hub am PC). In der WiZ-App muss „Lokale Kommunikation“ an sein.
/// Szene 9 = „Aufwachen“ (Wake-up): dimmt langsam von dunkel/lila-warm bis hell.
enum WiZ {
    static let wakeScene = 9

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// einen Befehl schicken; true = Lampe hat geantwortet
    static func send(_ ip: String, _ params: [String: Any]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["method": "setPilot", "params": params]),
              let port = NWEndpoint.Port(rawValue: 38899) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let q = DispatchQueue(label: "wiz.\(ip)")
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .udp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: data, completion: .contentProcessed { err in
                        if err != nil { finish(false); return }
                        conn.receiveMessage { d, _, _, _ in finish(d != nil) }
                    })
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }

    /// an alle Lampen, je zweimal versuchen (UDP kann verloren gehen); Ergebnis = wie viele geantwortet haben
    static func all(_ ips: [String], _ params: [String: Any]) async -> Int {
        var ok = 0
        for ip in ips {
            if await send(ip, params) { ok += 1 } else if await send(ip, params) { ok += 1 }
        }
        return ok
    }

    static func wake(_ ips: [String]) async -> Int { await all(ips, ["state": true, "sceneId": wakeScene, "speed": 100, "dimming": 100]) }
    static func off(_ ips: [String]) async -> Int { await all(ips, ["state": false]) }
}
