import SwiftUI
import MapKit

// GTA-VI-Karte (Leonida). Kacheln + Orte: GTA VI Mapping Community / GTADB.ORG (CC BY 4.0, https://map.gtadb.org),
// öffentlich im GitHub-Repo rolux/gtadb.org. Läuft ohne PC; jede Kachel wird nur einmal geladen.

// MARK: - Daten

struct Landmark: Hashable {
    let id: String
    let name: String
    let area: String
    let x: Double
    let y: Double
    let rname: String
    let rcity: String
    let lat: Double?
    let lon: Double?
    let type: String
    let ok: Bool
}

final class Leonida: @unchecked Sendable {
    static let shared = Leonida()
    let landmarks: [Landmark]
    let anchors: [[Double]]
    let credit: String
    lazy var warp: Warp = Warp(pairs: landmarks.filter { $0.ok && $0.lat != nil }.map { [$0.lat!, $0.lon!, $0.x, $0.y] }, anchors: anchors)

    init() {
        var lms: [Landmark] = []
        var anc: [[Double]] = []
        var cred = "GTA VI Landmarks Data (CC BY 4.0) — https://map.gtadb.org"
        if let url = Bundle.main.url(forResource: "leonida", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let c = root["credit"] as? String { cred = c }
            for case let a as [Any] in (root["anchors"] as? [Any] ?? []) where a.count >= 5 {
                let v = a[1...4].compactMap { ($0 as? NSNumber)?.doubleValue }
                if v.count == 4 { anc.append(v) }
            }
            for case let l as [Any] in (root["landmarks"] as? [Any] ?? []) where l.count >= 11 {
                func s(_ i: Int) -> String { l[i] as? String ?? "" }
                func d(_ i: Int) -> Double? { (l[i] as? NSNumber)?.doubleValue }
                guard let x = d(3), let y = d(4) else { continue }
                let ok = (l[10] as? NSNumber)?.boolValue ?? false
                lms.append(Landmark(id: s(0), name: s(1), area: s(2), x: x, y: y, rname: s(5), rcity: s(6), lat: d(7), lon: d(8), type: s(9), ok: ok))
            }
        }
        landmarks = lms
        anchors = anc
        credit = cred
    }

    /// Orte, die man auf der Karte zeigt (abgerissene/gestrichene weglassen)
    var visible: [Landmark] {
        landmarks.filter { !["demolished", "closed", "cancelled"].contains($0.type) && !$0.type.contains("doesnt") && !$0.name.isEmpty }
    }

    func nearest(x: Double, y: Double) -> Landmark? {
        landmarks.min { ($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y) < ($1.x - x) * ($1.x - x) + ($1.y - y) * ($1.y - y) }
    }

    func search(_ q: String) -> [Landmark] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return [] }
        return Array(visible.filter {
            $0.name.localizedCaseInsensitiveContains(t) || $0.area.localizedCaseInsensitiveContains(t) ||
            $0.rname.localizedCaseInsensitiveContains(t) || $0.rcity.localizedCaseInsensitiveContains(t)
        }.prefix(12))
    }
}

// MARK: - Umrechnung echtes Florida ↔ Leonida (wie im Hub: Moving Least Squares + Thin-Plate-Spline)

final class Warp: @unchecked Sendable {
    private static let LAT0 = 27.5, LON0 = -81.5
    private static let KX = 111320 * cos(27.5 * Double.pi / 180), KY = 110574.0
    static func toM(_ lat: Double, _ lon: Double) -> SIMD2<Double> { SIMD2((lon - LON0) * KX, (lat - LAT0) * KY) }
    static func fromM(_ p: SIMD2<Double>) -> (lat: Double, lon: Double) { (p.y / KY + LAT0, p.x / KX + LON0) }

    private let R: [SIMD2<Double>], G: [SIMD2<Double>]
    private let fwd: (SIMD2<Double>) -> (SIMD2<Double>, Double)
    private let back: (SIMD2<Double>) -> (SIMD2<Double>, Double)
    private let big: ((SIMD2<Double>) -> SIMD2<Double>)?
    private let bigBack: ((SIMD2<Double>) -> SIMD2<Double>)?

    /// pairs/anchors: [lat, lon, gameX, gameY]
    init(pairs: [[Double]], anchors: [[Double]], k: Int = 28, cReal: Double = 2500, cGame: Double = 250) {
        let r = pairs.map { Warp.toM($0[0], $0[1]) }
        let g = pairs.map { SIMD2($0[2], $0[3]) }
        R = r
        G = g
        fwd = Warp.mls(r, g, k: k, c: cReal)
        back = Warp.mls(g, r, k: k, c: cGame)
        let AR = anchors.map { Warp.toM($0[0], $0[1]) }, AG = anchors.map { SIMD2($0[2], $0[3]) }
        big = anchors.count >= 4 ? Warp.tps(AR, AG, unit: 100e3) : nil
        bigBack = anchors.count >= 4 ? Warp.tps(AG, AR, unit: 5e3) : nil
    }

    private static func nearestDist(_ pts: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var m = Double.infinity
        for q in pts { let d = q - p; let v = d.x * d.x + d.y * d.y; if v < m { m = v } }
        return m.squareRoot()
    }
    private static func trust(_ d: Double, _ scale: Double, _ out: Double) -> Double {
        exp(-pow(d / scale, 2)) * (out <= 1 ? 1 : exp(-pow(out - 1, 2) / 0.5))
    }
    private static func mix(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ l: Double) -> SIMD2<Double> { a * l + b * (1 - l) }

    /// Echter Ort → Spiel-Koordinaten (+ Abstand zum nächsten bekannten Gebäude in km)
    func toGame(lat: Double, lon: Double) -> (x: Double, y: Double, km: Double) {
        let p = Warp.toM(lat, lon), d = Warp.nearestDist(R, p), loc = fwd(p)
        let l = big != nil ? Warp.trust(d, 12e3, loc.1) : 1
        let r = l > 0.999 || big == nil ? loc.0 : Warp.mix(loc.0, big!(p), l)
        return (r.x, r.y, d / 1000)
    }

    /// Spiel-Koordinaten → echter Ort (+ Abstand zum nächsten bekannten Gebäude in Spiel-Metern)
    func toReal(x: Double, y: Double) -> (lat: Double, lon: Double, m: Double) {
        let p = SIMD2(x, y), d = Warp.nearestDist(G, p), loc = back(p)
        let l = bigBack != nil ? Warp.trust(d, 900, loc.1) : 1
        let m = l > 0.999 || bigBack == nil ? loc.0 : Warp.mix(loc.0, bigBack!(p), l)
        let r = Warp.fromM(m)
        return (r.lat, r.lon, d)
    }

    private static func mls(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], k: Int, c: Double) -> (SIMD2<Double>) -> (SIMD2<Double>, Double) {
        let n = src.count, kk = min(k, n)
        return { p in
            guard kk > 0 else { return (p, 99) }
            var d2 = [Double](repeating: 0, count: n)
            for i in 0..<n { let d = src[i] - p; d2[i] = d.x * d.x + d.y * d.y }
            let near = Array((0..<n).sorted { d2[$0] < d2[$1] }.prefix(kk))
            let far = d2[near[kk - 1]].squareRoot() * 1.05 + 1
            var W = 0.0
            var s = SIMD2<Double>(0, 0), t = SIMD2<Double>(0, 0)
            var w: [Double] = []
            for i in near {
                let d = d2[i].squareRoot(), tt = 1 - d / far
                let v = tt * tt / (d2[i] + c * c)
                W += v; s += v * src[i]; t += v * dst[i]; w.append(v)
            }
            s /= W; t /= W
            var a = 0.0, b = 0.0, dd = 0.0, m00 = 0.0, m01 = 0.0, m10 = 0.0, m11 = 0.0
            for (j, i) in near.enumerated() {
                let v = w[j]
                let x = src[i].x - s.x, y = src[i].y - s.y, u = dst[i].x - t.x, z = dst[i].y - t.y
                a += v * x * x; b += v * x * y; dd += v * y * y
                m00 += v * x * u; m01 += v * x * z; m10 += v * y * u; m11 += v * y * z
            }
            let det = a * dd - b * b, x = p.x - s.x, y = p.y - s.y
            let out = (x * x + y * y).squareRoot() / (((a + dd) / W).squareRoot() + 1e-9)
            if abs(det) < 1e-9 * (a * dd + 1) {
                let sc = ((m00 * m00 + m11 * m11 + 1e-12) / (a * a + dd * dd + 1e-12)).squareRoot()
                return (SIMD2(t.x + x * sc, t.y + y * sc), out)
            }
            let i00 = dd / det, i01 = -b / det, i11 = a / det
            let M00 = i00 * m00 + i01 * m10, M01 = i00 * m01 + i01 * m11
            let M10 = i01 * m00 + i11 * m10, M11 = i01 * m01 + i11 * m11
            return (SIMD2(t.x + x * M00 + y * M10, t.y + x * M01 + y * M11), out)
        }
    }

    private static func tps(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], unit: Double) -> (SIMD2<Double>) -> SIMD2<Double> {
        let n = src.count, N = n + 3
        func U(_ r: Double) -> Double { r > 0 ? r * r * log(r) : 0 }
        let P = src.map { $0 / unit }
        var A = [[Double]](repeating: [Double](repeating: 0, count: N), count: N)
        for i in 0..<n {
            for j in 0..<n { let d = P[i] - P[j]; A[i][j] = U((d.x * d.x + d.y * d.y).squareRoot()) }
            A[i][n] = 1; A[n][i] = 1
            A[i][n + 1] = P[i].x; A[n + 1][i] = P[i].x
            A[i][n + 2] = P[i].y; A[n + 2][i] = P[i].y
        }
        let base = A
        func solve(_ b: [Double]) -> [Double] {
            var M = base.enumerated().map { $0.element + [b[$0.offset]] }
            for c in 0..<N {
                var p = c
                for r in (c + 1)..<N where abs(M[r][c]) > abs(M[p][c]) { p = r }
                M.swapAt(c, p)
                for r in 0..<N where r != c {
                    let f = M[r][c] / M[c][c]
                    for k in c...N { M[r][k] -= f * M[c][k] }
                }
            }
            return (0..<N).map { M[$0][N] / M[$0][$0] }
        }
        let wx = solve(dst.map { $0.x } + [0, 0, 0]), wy = solve(dst.map { $0.y } + [0, 0, 0])
        return { q in
            let p = q / unit
            var fx = wx[n] + wx[n + 1] * p.x + wx[n + 2] * p.y
            var fy = wy[n] + wy[n + 1] * p.x + wy[n + 2] * p.y
            for i in 0..<n {
                let d = p - P[i]
                let u = U((d.x * d.x + d.y * d.y).squareRoot())
                fx += wx[i] * u; fy += wy[i] * u
            }
            return SIMD2(fx, fy)
        }
    }
}

// MARK: - Spiel-Koordinaten ↔ Kartenpunkte

/// Die GTA-Karte wird wie eine „Welt“ in MapKit gelegt: Leaflet-Zoom 0 (1024 px) = MapKit-Zoom 2
enum GameGeo {
    static var world: Double { MKMapSize.world.width }
    static func point(x: Double, y: Double) -> MKMapPoint {
        MKMapPoint(x: (x + 16384) / 32768 * world, y: (16384 - y) / 32768 * world)
    }
    static func game(_ p: MKMapPoint) -> (x: Double, y: Double) {
        (p.x / world * 32768 - 16384, 16384 - p.y / world * 32768)
    }
    static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D { point(x: x, y: y).coordinate }
    /// sichtbarer Bereich um einen Spielpunkt (Breite in Spiel-Metern)
    static func rect(x: Double, y: Double, meters: Double) -> MKMapRect {
        let c = point(x: x, y: y), w = meters / 32768 * world
        return MKMapRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w)
    }
    static var leonida: MKMapRect {
        MKMapRect(x: 136.0 / 1024 * world, y: 136.0 / 1024 * world, width: 536.0 / 1024 * world, height: 692.0 / 1024 * world)
    }
}

final class GTATileOverlay: MKTileOverlay {
    private let base = "https://raw.githubusercontent.com/rolux/gtadb.org/main/maps/tiles/6/day/"
    private let maxZ = 6     // höchste Kachelstufe bei GTADB
    private let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("gta-tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = 2
        maximumZ = 12
    }

    private func tile(z: Int, x: Int, y: Int) async -> Data? {
        let file = dir.appendingPathComponent("\(z)_\(y)_\(x).jpg")
        if let d = try? Data(contentsOf: file) { return d.isEmpty ? nil : d }
        guard let url = URL(string: "\(base)\(z)/\(z),\(y),\(x).jpg"),
              let (data, resp) = try? await URLSession.shared.data(from: url) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { try? Data().write(to: file); return nil }      // gibt es nicht (Meer) → merken
        guard code == 200 else { return nil }
        try? data.write(to: file)
        return data
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let z = path.z - 2
        guard z >= 0 else { result(nil, nil); return }
        Task {
            if z <= maxZ {
                result(await tile(z: z, x: path.x, y: path.y), nil)
                return
            }
            // tiefer als GTADB: Ausschnitt der größten Kachel vergrößern
            let d = z - maxZ, px = path.x >> d, py = path.y >> d
            guard let data = await tile(z: maxZ, x: px, y: py), let img = UIImage(data: data) else { result(nil, nil); return }
            let parts = CGFloat(1 << d), size = img.size.width / parts
            let ox = CGFloat(path.x - (px << d)) * size, oy = CGFloat(path.y - (py << d)) * size
            let out = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { _ in
                img.draw(in: CGRect(x: -ox * 256 / size, y: -oy * 256 / size, width: img.size.width * 256 / size, height: img.size.height * 256 / size))
            }
            result(out.jpegData(compressionQuality: 0.85), nil)
        }
    }
}

// MARK: - Karte (UIKit-MapKit, weil SwiftUI-Map keine eigenen Kacheln kann)

final class LandmarkPin: NSObject, MKAnnotation {
    let lm: Landmark
    let coordinate: CLLocationCoordinate2D
    var title: String? { lm.name }
    var subtitle: String? { lm.area }
    init(_ lm: Landmark) { self.lm = lm; coordinate = GameGeo.coordinate(x: lm.x, y: lm.y) }
}

final class DropPin: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    init(_ c: CLLocationCoordinate2D, _ t: String?) { coordinate = c; title = t }
}

struct MapPick: Equatable {
    var title: String
    var subtitle: String
    var gameX: Double
    var gameY: Double
    var realLat: Double?
    var realLon: Double?
    var realText: String?
    var exact: Bool
}

struct GTAMapView: UIViewRepresentable {
    @Binding var pick: MapPick?
    @Binding var flyTo: MKMapRect?
    var showLandmarks: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.addOverlay(GTATileOverlay(urlTemplate: nil), level: .aboveLabels)
        m.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.16, alpha: 1)
        m.pointOfInterestFilter = .excludingAll
        m.showsCompass = false
        m.isRotateEnabled = false
        m.isPitchEnabled = false
        m.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "lm")
        m.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "drop")
        m.setVisibleMapRect(GameGeo.leonida, edgePadding: UIEdgeInsets(top: 40, left: 10, bottom: 40, right: 10), animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        m.addGestureRecognizer(tap)
        context.coordinator.map = m
        context.coordinator.setLandmarks(showLandmarks)
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setLandmarks(showLandmarks)
        if let r = flyTo {
            m.setVisibleMapRect(r, edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 220, right: 20), animated: true)
            DispatchQueue.main.async { flyTo = nil }
        }
        context.coordinator.syncDrop(pick)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: GTAMapView
        weak var map: MKMapView?
        private var pins: [LandmarkPin] = []
        private var showing = false
        private var drop: DropPin?

        init(_ p: GTAMapView) { parent = p }

        func setLandmarks(_ on: Bool) {
            guard let m = map, on != showing else { return }
            showing = on
            if on {
                if pins.isEmpty { pins = Leonida.shared.visible.map(LandmarkPin.init) }
                m.addAnnotations(pins)
            } else {
                m.removeAnnotations(pins)
            }
        }

        func syncDrop(_ pick: MapPick?) {
            guard let m = map else { return }
            if let p = pick {
                let c = GameGeo.coordinate(x: p.gameX, y: p.gameY)
                if let d = drop { d.coordinate = c; d.title = p.title }
                else { let d = DropPin(c, p.title); drop = d; m.addAnnotation(d) }
            } else if let d = drop {
                m.removeAnnotation(d); drop = nil
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let d = annotation as? DropPin {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "drop", for: d) as! MKMarkerAnnotationView
                v.markerTintColor = .systemPink
                v.glyphImage = UIImage(systemName: "mappin")
                v.displayPriority = .required
                v.clusteringIdentifier = nil
                return v
            }
            guard let p = annotation as? LandmarkPin else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "lm", for: p) as! MKMarkerAnnotationView
            let (icon, color) = Self.style(p.lm.type)
            v.glyphImage = UIImage(systemName: icon)
            v.markerTintColor = color
            v.clusteringIdentifier = "lm"
            v.displayPriority = MKFeatureDisplayPriority(rawValue: p.lm.ok ? 250 : 240)
            v.titleVisibility = .adaptive
            v.subtitleVisibility = .hidden
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let c = view.annotation as? MKClusterAnnotation {
                mapView.showAnnotations(c.memberAnnotations, animated: true)
                mapView.deselectAnnotation(c, animated: false)
                return
            }
            guard let p = view.annotation as? LandmarkPin else { return }
            let l = p.lm
            let real = l.rname.isEmpty ? nil : ([l.rname, l.rcity].filter { !$0.isEmpty }.joined(separator: ", "))
            parent.pick = MapPick(title: l.name, subtitle: l.area, gameX: l.x, gameY: l.y, realLat: l.lat, realLon: l.lon,
                                  realText: real, exact: l.ok)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let m = map else { return }
            let pt = g.location(in: m)
            if m.hitTest(pt, with: nil) is MKAnnotationView { return }
            let gp = GameGeo.game(MKMapPoint(m.convert(pt, toCoordinateFrom: m)))
            let near = Leonida.shared.nearest(x: gp.x, y: gp.y)
            let r = Leonida.shared.warp.toReal(x: gp.x, y: gp.y)
            parent.pick = MapPick(title: near.map { $0.area.components(separatedBy: ",").first ?? $0.area } ?? "Leonida",
                                  subtitle: String(format: "x %.0f · y %.0f", gp.x, gp.y),
                                  gameX: gp.x, gameY: gp.y, realLat: r.lat, realLon: r.lon, realText: nil, exact: r.m < 400)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        static func style(_ t: String) -> (String, UIColor) {
            let s = t.lowercased()
            if s.contains("hotel") { return ("bed.double.fill", .systemIndigo) }
            if s.contains("restaurant") || s.contains("food") { return ("fork.knife", .systemOrange) }
            if s.contains("gas") { return ("fuelpump.fill", .systemYellow) }
            if s.contains("hospital") || s.contains("pharmacy") { return ("cross.fill", .systemRed) }
            if s.contains("police") || s.contains("jail") || s.contains("government") { return ("building.columns.fill", .systemBlue) }
            if s.contains("airport") || s.contains("airbase") || s.contains("blimp") { return ("airplane", .systemTeal) }
            if s.contains("marina") { return ("sailboat.fill", .systemCyan) }
            if s.contains("metro") || s.contains("train") || s.contains("bus") || s.contains("transport") { return ("tram.fill", .systemGray) }
            if s.contains("safehouse") || s.contains("residential") { return ("house.fill", .systemGreen) }
            if s.contains("retail") || s.contains("clothes") || s.contains("shoes") || s.contains("supermarket") || s.contains("guns") { return ("bag.fill", .systemPink) }
            if s.contains("club") || s.contains("bar") || s.contains("drinks") || s.contains("liquor") { return ("wineglass.fill", .systemPurple) }
            if s.contains("natural") || s.contains("agriculture") { return ("leaf.fill", .systemGreen) }
            if s.contains("industrial") || s.contains("utilities") || s.contains("construction") { return ("building.2.fill", .systemBrown) }
            if s.contains("leisure") || s.contains("golf") || s.contains("tennis") || s.contains("gym") || s.contains("racetrack") { return ("figure.run", .systemMint) }
            if s.contains("landmark") || s.contains("l1") { return ("star.fill", .systemYellow) }
            return ("mappin", UIColor(red: 0.66, green: 0.45, blue: 1, alpha: 1))
        }
    }
}

// MARK: - Bildschirm mit Suche

struct GTAMapScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pick: MapPick?
    @State private var flyTo: MKMapRect?
    @State private var query = ""
    @State private var real: [MKMapItem] = []
    @State private var searching = false
    @AppStorage("gtaLandmarks") private var showLandmarks = true

    private var gameHits: [Landmark] { Leonida.shared.search(query) }

    var body: some View {
        ZStack(alignment: .top) {
            GTAMapView(pick: $pick, flyTo: $flyTo, showLandmarks: showLandmarks)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                        .glassEffect(.regular.interactive(), in: .circle)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Ort in Leonida oder echtes Florida", text: $query)
                            .submitLabel(.search)
                            .onSubmit { Task { await searchReal() } }
                        if !query.isEmpty { Button { query = ""; real = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    Button { showLandmarks.toggle() } label: {
                        Image(systemName: showLandmarks ? "mappin.and.ellipse" : "mappin.slash").font(.headline).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                if !query.isEmpty && (!gameHits.isEmpty || !real.isEmpty || searching) { results }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .overlay(alignment: .bottom) {
            if let p = pick { card(p).transition(.move(edge: .bottom).combined(with: .opacity)) }
            else {
                Text("Karte & Orte: GTADB.ORG (CC BY 4.0)").font(.caption2).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pick)
        .preferredColorScheme(.dark)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !gameHits.isEmpty { section("In Leonida") }
                ForEach(gameHits, id: \.id) { l in
                    row(icon: "gamecontroller.fill", title: l.name, sub: l.area) { select(l) }
                }
                if !real.isEmpty { section("Echtes Florida → Leonida") }
                ForEach(Array(real.enumerated()), id: \.offset) { _, item in
                    row(icon: "globe.americas.fill", title: item.name ?? "Ort", sub: item.placemark.title ?? "") { selectReal(item) }
                }
                if searching { ProgressView().padding() }
                if real.isEmpty && !searching {
                    Button { Task { await searchReal() } } label: {
                        Label("„\(query)“ in Florida suchen", systemImage: "magnifyingglass").font(.subheadline)
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxHeight: 320)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.purple).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ l: Landmark) {
        hideKeyboard()
        let realText = l.rname.isEmpty ? nil : [l.rname, l.rcity].filter { !$0.isEmpty }.joined(separator: ", ")
        pick = MapPick(title: l.name, subtitle: l.area, gameX: l.x, gameY: l.y, realLat: l.lat, realLon: l.lon, realText: realText, exact: l.ok)
        flyTo = GameGeo.rect(x: l.x, y: l.y, meters: 1200)
        query = ""
    }

    private func selectReal(_ item: MKMapItem) {
        hideKeyboard()
        let c = item.placemark.coordinate
        let g = Leonida.shared.warp.toGame(lat: c.latitude, lon: c.longitude)
        let area = Leonida.shared.nearest(x: g.x, y: g.y)?.area.components(separatedBy: ",").first ?? "Leonida"
        pick = MapPick(title: "\(item.name ?? "Ort") in GTA", subtitle: "ungefähr: \(area)", gameX: g.x, gameY: g.y,
                       realLat: c.latitude, realLon: c.longitude, realText: [item.name, item.placemark.locality].compactMap { $0 }.joined(separator: ", "),
                       exact: g.km < 2)
        flyTo = GameGeo.rect(x: g.x, y: g.y, meters: g.km < 2 ? 1500 : 4000)
        query = ""
        real = []
    }

    private func searchReal() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        defer { searching = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 27.7, longitude: -83.7),
                                        span: MKCoordinateSpan(latitudeDelta: 7, longitudeDelta: 8))
        let items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        real = Array(items.filter {
            let c = $0.placemark.coordinate
            return c.latitude > 24.3 && c.latitude < 31.1 && c.longitude > -87.7 && c.longitude < -79.8
        }.prefix(8))
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func card(_ p: MapPick) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.title3.bold()).lineLimit(2)
                    Text(p.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { pick = nil } label: { Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            if let lat = p.realLat, let lon = p.realLon {
                HStack(spacing: 10) {
                    Image(systemName: "globe.americas.fill").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.exact ? "Echtes Vorbild" : "In echt ungefähr hier").font(.caption.weight(.bold)).foregroundStyle(.teal)
                        Text(p.realText ?? String(format: "%.4f, %.4f", lat, lon)).font(.subheadline).lineLimit(2)
                    }
                    Spacer()
                    Button {
                        let name = (p.realText ?? p.title).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(name)") { openURL(u) }
                    } label: { Image(systemName: "map.fill").frame(width: 40, height: 40) }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.teal.opacity(0.5)).interactive(), in: .circle)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
