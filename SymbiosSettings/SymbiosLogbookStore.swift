import Foundation

// MARK: - Persistenter Logbuch-Cache (offline verfügbar)
// Speichert Index + Roh-Records je Gerät-Seriennummer in Documents/logbook/.
// Index: logbook_<serial>.json   ·   Tauchgang: dive_<serial>_<diveId>.bin

@MainActor
final class LogbookStore: ObservableObject {
    @Published private(set) var serial: UInt32? = nil
    @Published private(set) var index: [SymbiosBLE.DiveIndexEntry] = []
    @Published private(set) var downloadedIds: Set<UInt16> = []

    private let fm = FileManager.default
    private var dir: URL {
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logbook", isDirectory: true)
        if !fm.fileExists(atPath: d.path) { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        return d
    }

    init() {
        let s = UserDefaults.standard.integer(forKey: "lastSerial")
        if s > 0 { serial = UInt32(s); reload() }
    }

    /// Beim Verbinden aufrufen: aktives Gerät setzen (lädt dessen Offline-Index).
    func setDevice(_ serial: UInt32) {
        guard serial > 0 else { return }
        if self.serial != serial {
            self.serial = serial
            UserDefaults.standard.set(Int(serial), forKey: "lastSerial")
        }
        reload()
    }

    private func indexURL(_ s: UInt32) -> URL { dir.appendingPathComponent("logbook_\(s).json") }
    private func diveURL(_ s: UInt32, _ id: UInt16) -> URL { dir.appendingPathComponent("dive_\(s)_\(id).bin") }

    /// Offline-Daten des aktuellen Geräts von der Platte laden.
    func reload() {
        guard let s = serial else { index = []; downloadedIds = []; return }
        if let d = try? Data(contentsOf: indexURL(s)),
           let e = try? JSONDecoder().decode([SymbiosBLE.DiveIndexEntry].self, from: d) {
            index = e
        } else { index = [] }
        // welche Tauchgänge liegen als .bin vor?
        var ids = Set<UInt16>()
        let prefix = "dive_\(s)_"
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix(prefix) && f.hasSuffix(".bin") {
                let mid = f.dropFirst(prefix.count).dropLast(4)
                if let v = UInt16(mid) { ids.insert(v) }
            }
        }
        downloadedIds = ids
    }

    func saveIndex(_ entries: [SymbiosBLE.DiveIndexEntry]) {
        index = entries
        guard let s = serial, let d = try? JSONEncoder().encode(entries) else { return }
        try? d.write(to: indexURL(s))
    }

    func hasDive(_ id: UInt16) -> Bool { downloadedIds.contains(id) }

    // MARK: geräteübergreifend (für Zusammenführung)
    /// Alle Seriennummern mit geladenen Tauchgängen.
    func allSerials() -> [UInt32] {
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var s = Set<UInt32>()
        for f in files where f.hasPrefix("dive_") && f.hasSuffix(".bin") {
            let mid = f.dropFirst(5).dropLast(4)              // "<serial>_<id>"
            if let head = mid.split(separator: "_").first, let v = UInt32(head) { s.insert(v) }
        }
        return Array(s)
    }
    func downloadedIds(for serial: UInt32) -> [UInt16] {
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix = "dive_\(serial)_"
        var ids: [UInt16] = []
        for f in files where f.hasPrefix(prefix) && f.hasSuffix(".bin") {
            if let v = UInt16(f.dropFirst(prefix.count).dropLast(4)) { ids.append(v) }
        }
        return ids
    }
    func rawDive(serial: UInt32, id: UInt16) -> [UInt8]? {
        guard let d = try? Data(contentsOf: diveURL(serial, id)) else { return nil }
        return [UInt8](d)
    }

    func loadDive(_ id: UInt16) -> [UInt8]? {
        guard let s = serial, let d = try? Data(contentsOf: diveURL(s, id)) else { return nil }
        return [UInt8](d)
    }

    func saveDive(_ id: UInt16, _ raw: [UInt8]) {
        guard let s = serial else { return }
        try? Data(raw).write(to: diveURL(s, id))
        downloadedIds.insert(id)
    }

    /// Nur die geladenen Tauchgang-Records löschen (Index bleibt) → beim Öffnen wird neu geladen.
    func clearDives() {
        guard let s = serial else { return }
        for id in downloadedIds { try? fm.removeItem(at: diveURL(s, id)) }
        downloadedIds = []
    }

    /// Einen einzelnen Tauchgang-Record löschen (für gezieltes Neu-Laden).
    func removeDive(_ id: UInt16) {
        guard let s = serial else { return }
        try? fm.removeItem(at: diveURL(s, id))
        downloadedIds.remove(id)
    }

    /// Alle Offline-Daten des aktuellen Geräts löschen.
    func clearCurrent() {
        guard let s = serial else { return }
        try? fm.removeItem(at: indexURL(s))
        for id in downloadedIds { try? fm.removeItem(at: diveURL(s, id)) }
        index = []; downloadedIds = []
    }

    var isOffline: Bool { serial != nil && !index.isEmpty }
}
