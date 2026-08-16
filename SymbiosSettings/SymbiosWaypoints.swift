import SwiftUI

// MARK: - Wegpunkte → USER.GPX
// Der Symbios liest Wegpunkte aus der Datei `USER.GPX` auf seinem FAT32-USB-Speicher (bestätigt, §12/§13).
// Direkter BLE-Push (Cmd 0x0A) ist im offiziellen App-Code gestubbt und NICHT bytegenau bestätigt →
// wir erzeugen hier standardkonformes GPX und teilen es; der Nutzer legt USER.GPX per USB aufs Gerät.

struct Waypoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
}

@MainActor
final class WaypointStore: ObservableObject {
    @Published var waypoints: [Waypoint] = [] { didSet { persist() } }
    private let key = "waypoints.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let w = try? JSONDecoder().decode([Waypoint].self, from: d) { waypoints = w }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(waypoints) { UserDefaults.standard.set(d, forKey: key) }
    }
    func add(_ w: Waypoint) { waypoints.append(w) }
    func remove(at offsets: IndexSet) { waypoints.remove(atOffsets: offsets) }
    func update(_ w: Waypoint) { if let i = waypoints.firstIndex(where: { $0.id == w.id }) { waypoints[i] = w } }
}

enum GPX {
    /// Standardkonformes GPX 1.1 mit <wpt>-Punkten.
    static func build(_ wps: [Waypoint]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        var s = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        s += #"<gpx version="1.1" creator="SymbiosSettings" xmlns="http://www.topografix.com/GPX/1/1">"# + "\n"
        for w in wps {
            s += String(format: "  <wpt lat=\"%.6f\" lon=\"%.6f\">\n", w.lat, w.lon)
            s += "    <name>\(esc(w.name))</name>\n"
            s += "  </wpt>\n"
        }
        s += "</gpx>\n"
        return s
    }
}

// MARK: - Wegpunkte-UI
struct WaypointsView: View {
    @StateObject private var store = WaypointStore()
    @State private var editing: Waypoint? = nil
    @State private var showNew = false
    @State private var gpxURL: URL? = nil

    var body: some View {
        List {
            Section {
                ForEach(store.waypoints) { w in
                    Button { editing = w } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name.isEmpty ? "—" : w.name).foregroundStyle(.primary)
                            Text(String(format: "%.6f, %.6f", w.lat, w.lon))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
                .onDelete { store.remove(at: $0) }
                Button { showNew = true } label: { Label("Wegpunkt hinzufügen", systemImage: "plus") }
            } footer: {
                Text("Der Symbios liest Wegpunkte aus USER.GPX auf seinem USB-Speicher. GPX exportieren, dann USER.GPX per USB aufs Gerät kopieren. (Direkter Funk-Upload ist noch nicht bestätigt.)")
            }
            if !store.waypoints.isEmpty {
                Section {
                    if let url = gpxURL {
                        ShareLink(item: url) { Label("USER.GPX exportieren / teilen", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        .navigationTitle("Wegpunkte")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { regenerate() }
        .onChange(of: store.waypoints) { _, _ in regenerate() }
        .sheet(isPresented: $showNew) {
            WaypointEditSheet(waypoint: Waypoint(name: "", lat: 0, lon: 0), isNew: true) { store.add($0) }
        }
        .sheet(item: $editing) { w in
            WaypointEditSheet(waypoint: w, isNew: false) { store.update($0) }
        }
    }

    private func regenerate() {
        guard !store.waypoints.isEmpty else { gpxURL = nil; return }
        let gpx = GPX.build(store.waypoints)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("USER.GPX")
        try? gpx.data(using: .utf8)?.write(to: url)
        gpxURL = url
    }
}

struct WaypointEditSheet: View {
    @State var waypoint: Waypoint
    let isNew: Bool
    let onSave: (Waypoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var latStr = ""
    @State private var lonStr = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("z. B. Boot / Einstieg", text: $waypoint.name) }
                Section("Position") {
                    LabeledContent("Breite (lat)") {
                        TextField("48.123456", text: $latStr).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Länge (lon)") {
                        TextField("11.123456", text: $lonStr).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle(isNew ? "Neuer Wegpunkt" : "Wegpunkt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        waypoint.lat = parse(latStr) ?? waypoint.lat
                        waypoint.lon = parse(lonStr) ?? waypoint.lon
                        onSave(waypoint); dismiss()
                    }.disabled(parse(latStr) == nil || parse(lonStr) == nil)
                }
            }
            .onAppear {
                latStr = isNew ? "" : String(format: "%.6f", waypoint.lat)
                lonStr = isNew ? "" : String(format: "%.6f", waypoint.lon)
            }
        }
    }
    private func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
}
