import SwiftUI
import Charts

// MARK: - Dive-Record-Parser (TLV, autoritativ aus libdivecomputer halcyon_symbios_parser.c / §8)
// Record-Stream: [id u8][len u8][payload …]; `len` = Gesamtlänge inkl. 2-Byte-Kopf, nächster Record bei off+len.
// Zeitbasis EPOCH = 2021-01-01 UTC (1609459200). Alle Mehrbyte-Felder little-endian.

struct DiveSample: Identifiable {
    let id: Int          // laufende Sample-Nummer
    let seconds: Int     // ~ Sample-Index × Log-Intervall (Näherung)
    var depth: Double    // m
    var temp: Double?    // °C
    var ceiling: Double? // Deko-Decke m (0 = keine Deko)
    var pressure: Double? // Tankdruck bar (Sender)
    var tts: Int?        // Time-to-Surface, Sekunden (DECO @8)
    var gfNow: Int?      // GF now % (GF_DATA @2)
    var gfSurf: Int?     // Surface-GF % (GF_DATA @4)
}

struct ParsedDive {
    var number: Int?
    var start: Date?
    var end: Date?
    var maxDepth: Double = 0
    var minTemp: Double?
    var serial: UInt32?
    var model: UInt8?       // 7=Handset, 1=HUD (Header @2)
    var mode: Int?          // dcMode 0=OC…4=Gauge (Header @13, am Gerät bestätigt)
    var atmBar: Double?
    var gasCount: Int = 0
    var samples: [DiveSample] = []
    var interval: Int = 5   // s (Standard; echtes Intervall steht nur in der CSV/BLACKBOX)

    var duration: TimeInterval? {
        if let s = start, let e = end, e > s { return e.timeIntervalSince(s) }
        if !samples.isEmpty { return Double(samples.count * interval) }
        return nil
    }
}

struct TankStats {
    let startBar: Double
    let endBar: Double
    let sac: Double         // bar / Oberflächen-Minute
    let rmv: Double?        // L/min (AMV) – nur mit Flaschengröße
    var usedBar: Double { max(0, startBar - endBar) }
}

extension ParsedDive {
    var hasTank: Bool { samples.contains { $0.pressure != nil } }

    /// AMV (RMV) aus Druckabfall über die Zeit, tiefenkompensiert:
    /// SAC[bar/min Oberfläche] = Δp / Σ(ATA·dt);  AMV[L/min] = SAC × Flaschengröße[L].
    func tankStats(tankSizeL: Double?) -> TankStats? {
        let ps = samples.filter { $0.pressure != nil }
        guard let first = ps.first, let last = ps.last, ps.count >= 2 else { return nil }
        let start = first.pressure!, end = last.pressure!
        let t0 = first.seconds, t1 = last.seconds
        let dtMin = Double(interval) / 60.0
        var ataMin = 0.0
        for s in samples where s.seconds >= t0 && s.seconds <= t1 {
            ataMin += (s.depth / 10.0 + 1.0) * dtMin
        }
        let used = start - end
        let sac = (ataMin > 0 && used > 0) ? used / ataMin : 0
        let rmv = (sac > 0) ? tankSizeL.map { sac * $0 } : nil
        return TankStats(startBar: start, endBar: end, sac: sac, rmv: rmv)
    }
}

enum DiveParser {
    static let EPOCH_2021 = 1_609_459_200.0

    static func parse(_ d: [UInt8]) -> ParsedDive {
        var p = ParsedDive()
        func u16(_ a: [UInt8], _ o: Int) -> Int { Int(a[o]) | (Int(a[o+1]) << 8) }
        func u32(_ a: [UInt8], _ o: Int) -> UInt32 {
            UInt32(a[o]) | (UInt32(a[o+1]) << 8) | (UInt32(a[o+2]) << 16) | (UInt32(a[o+3]) << 24)
        }
        var i = 0
        var sampleIdx = 0
        var lastTemp: Double? = nil      // zuletzt gesehener Wert (carry-forward pro Zyklus)
        var lastCeiling: Double? = nil
        var lastPressure: Double? = nil
        var lastTts: Int? = nil
        var lastGfNow: Int? = nil
        var lastGfSurf: Int? = nil
        while i + 2 <= d.count {
            let id = d[i]; let len = Int(d[i+1])
            if len < 2 || i + len > d.count { break }
            let rec = Array(d[i..<i+len])
            switch id {
            case 0x01:  // HEADER (64): @2 model, @13 dcMode, @16 atmospheric, @18 number, @24 time_start, @28 serial
                if rec.count >= 3 { p.model = rec[2] }
                if rec.count >= 14 { p.mode = Int(rec[13]) }   // dcMode ✓ (OC=0 Dive13, CCR_FSP=2 Sample)
                if rec.count >= 18 { p.atmBar = Double(u16(rec, 16)) / 1000.0; p.number = u16(rec, 18) }
                if rec.count >= 28 { p.start = Date(timeIntervalSince1970: EPOCH_2021 + Double(u32(rec, 24))) }
                if rec.count >= 32 { p.serial = u32(rec, 28) }
            case 0x0C:  // FOOTER (16): @8 time_end
                if rec.count >= 12 { p.end = Date(timeIntervalSince1970: EPOCH_2021 + Double(u32(rec, 8))) }
            case 0x04:  // TEMPERATURE (4): @2 u16 0,1 °C
                if rec.count >= 4 {
                    let t = Double(u16(rec, 2)) / 10.0
                    lastTemp = t
                    p.minTemp = p.minTemp.map { min($0, t) } ?? t
                }
            case 0x0A:  // DECO (16): @3 u8 ceiling (m), @8 u16 tts (Sekunden)
                if rec.count >= 4 { lastCeiling = Double(rec[3]) }
                if rec.count >= 10 { lastTts = Int(u16(rec, 8)) }
            case 0x13, 0x15:  // GF_INFO / GF_DATA: @2 u16 gf_now %, @4 u16 gf_surface %
                if rec.count >= 6 { lastGfNow = Int(u16(rec, 2)); lastGfSurf = Int(u16(rec, 4)) }
            case 0x06:  // GAS_TRANSMITTER (12): @6 u16 pressure ÷10 bar
                if rec.count >= 8 { let p = Double(u16(rec, 6)) / 10.0; if p > 0 && p < 400 { lastPressure = p } }
            case 0x12:  // TANK_TRANSMITTER (8): @6 u16 pressure ÷100 bar (libdc: /10 dann /10)
                if rec.count >= 8 { let p = Double(u16(rec, 6)) / 100.0; if p > 0 && p < 400 { lastPressure = p } }
            case 0x03:  // DEPTH (4): @2 u16 cm  → ein Sample-Zyklus
                if rec.count >= 4 {
                    let m = Double(u16(rec, 2)) / 100.0
                    p.maxDepth = max(p.maxDepth, m)
                    p.samples.append(DiveSample(id: sampleIdx, seconds: sampleIdx * p.interval,
                                                depth: m, temp: lastTemp, ceiling: lastCeiling, pressure: lastPressure,
                                                tts: lastTts, gfNow: lastGfNow, gfSurf: lastGfSurf))
                    sampleIdx += 1
                }
            case 0x11:  // GAS_CONFIG
                p.gasCount += 1
            default: break
            }
            i += len
        }
        return p
    }

    /// Geräte-kompatible CSV (Index, Sekunden≈, Tiefe, Temp) + Kopfzeilen.
    static func csv(_ p: ParsedDive, diveId: UInt16) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var s = ""
        s += "DIVE ID;\(diveId)\n"
        if let n = p.number { s += "DIVE NR;\(n)\n" }
        if let d = p.start { s += "START;\(df.string(from: d))\n" }
        if let d = p.end { s += "END;\(df.string(from: d))\n" }
        s += String(format: "MAXDEPTH;%.2f;m\n", p.maxDepth)
        if let t = p.minTemp { s += String(format: "MINTEMP;%.1f;C\n", t) }
        if let b = p.atmBar { s += String(format: "SURFACE PRESSURE;%.3f;bar\n", b) }
        s += "LOG INTERVAL;\(p.interval);s (approx)\n"
        if let m = modeName(p.mode) { s += "DC MODE;\(m)\n" }
        s += "\nINDEX;SECONDS;DEPTH_M;TEMP_C;CEILING_M;PRESSURE_BAR\n"
        for smp in p.samples {
            let temp = smp.temp.map { String(format: "%.1f", $0) } ?? ""
            let ceil = smp.ceiling.map { String(format: "%.0f", $0) } ?? ""
            let pres = smp.pressure.map { String(format: "%.1f", $0) } ?? ""
            s += String(format: "%d;%d;%.2f;%@;%@;%@\n", smp.id, smp.seconds, smp.depth, temp, ceil, pres)
        }
        return s
    }

    static func modeName(_ m: Int?) -> String? {
        switch m {
        case 0: return "OC"
        case 1: return "CCR"
        case 2: return "CCR FSP"
        case 3: return "Sidemount"
        case 4: return "Gauge"
        default: return nil
        }
    }
    static func modelName(_ m: UInt8?) -> String {
        switch m { case 7: return "Handset"; case 1: return "HUD"; default: return m.map { "Modell \($0)" } ?? "?" }
    }
    static func modelShort(_ m: UInt8?) -> String {
        switch m { case 7: return "HS"; case 1: return "HUD"; default: return "?" }
    }
}

// MARK: - Merge-Modelle (HUD + Computer zusammenführen)
struct DiveMeta: Identifiable {
    let id: String            // "<serial>-<diveId>"
    let serial: UInt32
    let model: UInt8?
    let diveId: UInt16
    let start: Date?
    let maxDepth: Double
    let duration: TimeInterval?
    let mode: Int?
    let samples: Int
}

struct MergedDive: Identifiable {
    let id: String
    let start: Date?
    let maxDepth: Double
    let duration: TimeInterval?
    let mode: Int?
    let sources: [DiveMeta]   // 1 = einzeln, 2 = HUD+Computer
    var primary: DiveMeta { sources.max(by: { $0.samples < $1.samples }) ?? sources[0] }
}

enum DiveMerge {
    /// Gruppiert geladene Tauchgänge verschiedener Geräte per Startzeit (±5 min) zusammen.
    static func merge(_ metas: [DiveMeta], toleranceSec: TimeInterval = 300) -> [MergedDive] {
        let sorted = metas.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        var groups: [[DiveMeta]] = []
        for m in sorted {
            if let gi = groups.firstIndex(where: { grp in
                guard let a = grp.first?.start, let b = m.start else { return false }
                return abs(a.timeIntervalSince(b)) <= toleranceSec && !grp.contains { $0.serial == m.serial }
            }) {
                groups[gi].append(m)
            } else {
                groups.append([m])
            }
        }
        return groups.map { g in
            let prim = g.max(by: { $0.samples < $1.samples }) ?? g[0]
            return MergedDive(id: g.map { $0.id }.joined(separator: "+"),
                              start: prim.start,
                              maxDepth: g.map { $0.maxDepth }.max() ?? 0,
                              duration: prim.duration,
                              mode: prim.mode,
                              sources: g)
        }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }   // neueste zuerst
    }
}


// MARK: - Logbuch-Liste (Store-basiert, offline verfügbar)
struct LogbookView: View {
    @ObservedObject var ble: SymbiosBLE
    @ObservedObject var store: LogbookStore
    @State private var loading = false
    @State private var downloadingAll = false
    @State private var err: String? = nil
    @State private var tab = 0                    // 0 = dieses Gerät, 1 = zusammengeführt
    @State private var merged: [MergedDive] = []

    private var curSerial: UInt32 { store.serial ?? ble.deviceInfo?.serial ?? 0 }

    private func loadIndex() {
        Task {
            loading = true; err = nil
            if let s = ble.deviceInfo?.serial { store.setDevice(s) }
            if let entries = await ble.downloadLogbookIndex() { store.saveIndex(entries) }
            else { err = LT("Logbuch konnte nicht geladen werden.") }
            loading = false
        }
    }

    private func downloadAll() {
        Task {
            downloadingAll = true; err = nil
            for e in store.index where !store.hasDive(e.diveId) {
                if let raw = await ble.downloadDive(e.diveId) { store.saveDive(e.diveId, raw) }
            }
            downloadingAll = false
            rebuildMerged()
        }
    }

    private func rebuildMerged() {
        var metas: [DiveMeta] = []
        for s in store.allSerials() {
            for id in store.downloadedIds(for: s) {
                guard let raw = store.rawDive(serial: s, id: id) else { continue }
                let p = DiveParser.parse(raw)
                metas.append(DiveMeta(id: "\(s)-\(id)", serial: s, model: p.model, diveId: id,
                                      start: p.start, maxDepth: p.maxDepth, duration: p.duration,
                                      mode: p.mode, samples: p.samples.count))
            }
        }
        merged = DiveMerge.merge(metas)
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    Text("Dieses Gerät").tag(0)
                    Text("Zusammengeführt").tag(1)
                }.pickerStyle(.segmented)
            }
            if tab == 0 { deviceTab } else { mergedTab }
        }
        .navigationTitle("Logbuch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rebuildMerged() }
        .onChange(of: store.downloadedIds) { _, _ in rebuildMerged() }
    }

    // MARK: dieses Gerät
    @ViewBuilder private var deviceTab: some View {
        Section {
            Button { loadIndex() } label: {
                Label(store.index.isEmpty ? "Logbuch laden" : "Aktualisieren",
                      systemImage: store.index.isEmpty ? "arrow.down.doc" : "arrow.clockwise")
            }
            .disabled(loading || downloadingAll || !ble.connected)
            if !store.index.isEmpty && ble.connected {
                let missing = store.index.filter { !store.hasDive($0.diveId) }.count
                Button { downloadAll() } label: {
                    Label(missing > 0 ? "Alle laden (\(missing))" : "Alle geladen ✓", systemImage: "square.and.arrow.down.on.square")
                }.disabled(loading || downloadingAll || missing == 0)
            }
            if loading || downloadingAll {
                HStack { ProgressView(); Text(progressText).foregroundStyle(.secondary).font(.footnote) }
            }
            if let e = err { Text(e).foregroundStyle(.orange).font(.footnote) }
            if !ble.connected {
                Label(store.index.isEmpty
                      ? "Nicht verbunden – zum Laden mit dem Gerät verbinden."
                      : "Offline – zwischengespeicherte Tauchgänge.",
                      systemImage: store.index.isEmpty ? "wifi.slash" : "internaldrive")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            if !store.downloadedIds.isEmpty {
                Button(role: .destructive) { store.clearDives() } label: {
                    Label("Geladene Tauchgänge verwerfen (\(store.downloadedIds.count))", systemImage: "trash")
                }.disabled(loading || downloadingAll)
            }
        } footer: {
            Text("Read-only. Geladene Tauchgänge bleiben offline verfügbar (pro Gerät gespeichert). Download-Mechanik nach libdivecomputer; beim ersten Gerät gegenprüfen.")
        }
        if !store.index.isEmpty {
            Section {
                ForEach(store.index.reversed()) { e in
                    NavigationLink { DiveDetailView(ble: ble, store: store, serial: curSerial, diveId: e.diveId) } label: {
                        HStack {
                            Label { Text(verbatim: LT("Tauchgang") + " · ID \(e.diveId)") } icon: { Image(systemName: "water.waves") }
                            Spacer()
                            if store.hasDive(e.diveId) {
                                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption)
                            }
                        }
                    }
                }
            } header: { Text(verbatim: LT("Tauchgänge") + " (\(store.index.count))") }
        }
    }

    // MARK: zusammengeführt
    @ViewBuilder private var mergedTab: some View {
        if merged.isEmpty {
            Section { Text("Noch keine geladenen Tauchgänge. Im Reiter „Dieses Gerät“ laden (auch „Alle laden“), auch vom HUD.")
                .foregroundStyle(.secondary).font(.footnote) }
        } else {
            Section {
                ForEach(merged) { m in
                    NavigationLink { DiveDetailView(ble: ble, store: store, serial: m.primary.serial, diveId: m.primary.diveId) } label: {
                        mergedRow(m)
                    }
                }
            } header: { Text(verbatim: LT("Tauchgänge") + " (\(merged.count))") }
            footer: { Text("Automatisch zusammengeführt: gleiche Startzeit (±5 min) auf verschiedenen Geräten = ein Tauchgang. Uhren am besten synchronisieren.") }
        }
    }

    @ViewBuilder private func mergedRow(_ m: MergedDive) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(m.start.map { dateStr($0) } ?? "—").font(.subheadline)
                if let mode = DiveParser.modeName(m.mode) {
                    Text(mode).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
                }
                Spacer()
                ForEach(m.sources) { src in
                    Text(DiveParser.modelShort(src.model)).font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Label(String(format: "%.1f m", m.maxDepth), systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary)
                if let dur = m.duration {
                    Label(durShort(dur), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if m.sources.count > 1 {
                    Label("zusammengeführt", systemImage: "arrow.triangle.merge").font(.caption2).foregroundStyle(.green)
                }
            }
        }
    }

    private func dateStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d)
    }
    private func durShort(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60; return String(format: "%d:%02d", m, s)
    }
    private var progressText: String {
        if let x = ble.xferProgress { return "\(Int(x * 100)) %" }
        return LT("lädt…")
    }
}

// MARK: - Tauchgang-Detail (Store-Cache zuerst → offline)
struct DiveDetailView: View {
    @ObservedObject var ble: SymbiosBLE
    @ObservedObject var store: LogbookStore
    let serial: UInt32
    let diveId: UInt16
    @State private var dive: ParsedDive? = nil
    @State private var loading = false
    @State private var err: String? = nil
    @State private var csvURL: URL? = nil
    @State private var binURL: URL? = nil
    @AppStorage("tankSizeL") private var tankSizeL: Double = 12
    @State private var fullscreen = false

    private func isIncomplete(_ d: ParsedDive) -> Bool { d.end == nil || d.samples.isEmpty }
    /// Nachladen geht nur, wenn genau dieses Gerät verbunden ist.
    private var canDownload: Bool { ble.connected && ble.deviceInfo?.serial == serial }

    var body: some View {
        List {
            if loading {
                Section { HStack { ProgressView(); Text(progressText).foregroundStyle(.secondary) } }
            }
            if let err { Section { Text(err).foregroundStyle(.orange) } }
            if let d = dive, isIncomplete(d) {
                Section {
                    Label("Unvollständig geladen (vermutlich alter Teil-Download).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.footnote)
                    Button { Task { await load(force: true) } } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
                        .disabled(loading || !canDownload)
                }
            }
            if let d = dive {
                Section("Übersicht") {
                    if let n = d.number { row("Nr.", "\(n)") }
                    if let m = DiveParser.modeName(d.mode) { row("Art", m) }
                    row("Gerät", DiveParser.modelName(d.model))
                    if let s = d.start { row("Start", dateStr(s)) }
                    if let dur = d.duration { row("Dauer", durStr(dur)) }
                    row("Max. Tiefe", String(format: "%.1f m", d.maxDepth))
                    if let t = d.minTemp { row("Min. Temp", String(format: "%.1f °C", t)) }
                    if d.gasCount > 0 { row("Gase", "\(d.gasCount)") }
                    row("Samples", "\(d.samples.count)")
                }
                if d.samples.count > 1 {
                    Section {
                        ProfileChartView(dive: d)
                    } header: {
                        HStack {
                            Text("Tiefenprofil"); Spacer()
                            Button { fullscreen = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }.textCase(nil)
                        }
                    }
                }
                if d.hasTank {
                    Section {
                        Stepper(value: $tankSizeL, in: 3...30, step: 1) {
                            HStack { Text("Flaschengröße"); Spacer()
                                Text(verbatim: "\(Int(tankSizeL)) L").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        if let ts = d.tankStats(tankSizeL: tankSizeL) {
                            row("Anfangsdruck", String(format: "%.0f bar", ts.startBar))
                            row("Enddruck", String(format: "%.0f bar", ts.endBar))
                            row("Verbraucht", String(format: "%.0f bar", ts.usedBar))
                            if let rmv = ts.rmv {
                                HStack { Text("AMV").bold(); Spacer()
                                    Text(String(format: "%.1f L/min", rmv)).bold().monospacedDigit().foregroundStyle(.blue) }
                            }
                            row("SAC", String(format: "%.2f bar/min", ts.sac))
                        }
                    } header: { Text("Luftverbrauch") } footer: {
                        Text("AMV = tiefenkompensiertes Atemminutenvolumen (Δp/Zeit × Flaschengröße), auf Oberfläche normiert. Sender-Auswertung ist reverse-engineert – beim ersten Sender-Tauchgang gegenprüfen.")
                    }
                }
                Section {
                    if let url = csvURL {
                        ShareLink(item: url) { Label("Als CSV exportieren / teilen", systemImage: "square.and.arrow.up") }
                    }
                    if let b = binURL {
                        ShareLink(item: b) { Label("Rohdaten (.bin) teilen", systemImage: "doc.badge.gearshape") }
                    }
                } footer: {
                    Text("CSV-Zeit ist genähert (Sample-Index × Intervall). Datum/Tiefe/Temp sind aus dem Record. Rohdaten = unveränderter Geräte-Record (zur Diagnose).")
                }
            }
        }
        .navigationTitle(Text(verbatim: LT("Tauchgang") + " \(diveId)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canDownload {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $fullscreen) {
            if let d = dive { FullscreenChart(dive: d) { fullscreen = false } }
        }
    }

    private func load(force: Bool = false) async {
        if !force { guard dive == nil else { return } }
        guard !loading else { return }
        loading = true; err = nil
        if force { store.removeDive(diveId) }
        var raw = force ? nil : store.rawDive(serial: serial, id: diveId)   // erst Offline-Cache (außer erzwungen)
        if raw == nil {
            guard canDownload else { err = LT("Nicht gespeichert – zum Laden mit dem Gerät verbinden."); loading = false; return }
            raw = await ble.downloadDive(diveId)
            if let r = raw { store.saveDive(diveId, r) }
        }
        guard let raw else { err = LT("Tauchgang konnte nicht geladen werden."); loading = false; return }
        let parsed = DiveParser.parse(raw)
        dive = parsed
        let tmp = FileManager.default.temporaryDirectory
        let csv = DiveParser.csv(parsed, diveId: diveId)
        let curl = tmp.appendingPathComponent("dive_\(diveId).csv")
        try? csv.data(using: .utf8)?.write(to: curl); csvURL = curl
        let burl = tmp.appendingPathComponent("dive_\(diveId).bin")
        try? Data(raw).write(to: burl); binURL = burl
        loading = false
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(LocalizedStringKey(k)); Spacer(); Text(v).foregroundStyle(.secondary).monospacedDigit() }
    }
    private var progressText: String {
        if let x = ble.xferProgress { return "\(Int(x * 100)) %" }
        return LT("lädt…")
    }
    private func dateStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d)
    }
    private func durStr(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60; return String(format: "%d:%02d min", m, s)
    }
}

// MARK: - Tiefenprofil-Chart mit Scrub-Tooltip (Finger über die Linie → Werte)
struct ProfileChartView: View {
    let dive: ParsedDive
    var height: CGFloat = 220
    @State private var showDepth = true
    @State private var showCeiling = true
    @State private var showTemp = true
    @State private var showPressure = true
    @State private var selIndex: Int? = nil

    var body: some View {
        let d = dive
        let yMax = max(5.0, (d.maxDepth / 5).rounded(.up) * 5)
        let xMax = max(1.0, (d.samples.last.map { Double($0.seconds) / 60.0 } ?? 1))
        let temps = d.samples.compactMap { $0.temp }
        let tMin = temps.min() ?? 0
        let tMaxRaw = temps.max() ?? 0
        let tMax = (tMaxRaw - tMin) < 0.5 ? tMin + 1 : tMaxRaw
        let hasTemp = !temps.isEmpty
        let hasCeil = d.samples.contains { ($0.ceiling ?? 0) > 0 }
        let pressures = d.samples.compactMap { $0.pressure }
        let hasPress = !pressures.isEmpty
        let pMax = max(pressures.max() ?? 1, 1)
        let depthTicks = niceTicks(0, yMax, 3)
        let tempTickVals: [Double] = hasTemp ? niceTicks(tMin, tMax, 4) : []
        let tempTickYs = tempTickVals.map { yMax * (1 - ($0 - tMin) / (tMax - tMin)) }
        let sDepth = LT("Tiefe"), sCeil = LT("Ceiling"), sTemp = LT("Temp"), sPress = LT("Druck")
        let hasTtsData = d.samples.contains { ($0.tts ?? 0) > 0 }
        let hasGfData = d.samples.contains { $0.gfNow != nil || $0.gfSurf != nil }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                chip(sDepth, .blue, $showDepth)
                if hasCeil { chip(sCeil, .orange, $showCeiling) }
                if hasTemp { chip(sTemp, .red, $showTemp) }
                if hasPress { chip(sPress, .green, $showPressure) }
            }.font(.caption)

            Chart {
                if showDepth {
                    ForEach(d.samples) { s in
                        LineMark(x: .value("min", Double(s.seconds) / 60.0), y: .value("m", s.depth))
                            .foregroundStyle(by: .value("Serie", sDepth))
                    }
                }
                if hasCeil && showCeiling {
                    ForEach(d.samples) { s in
                        LineMark(x: .value("min", Double(s.seconds) / 60.0), y: .value("m", s.ceiling ?? 0))
                            .foregroundStyle(by: .value("Serie", sCeil))
                    }
                }
                if hasTemp && showTemp {
                    ForEach(d.samples) { s in
                        if let t = s.temp {
                            LineMark(x: .value("min", Double(s.seconds) / 60.0),
                                     y: .value("m", yMax * (1 - (t - tMin) / (tMax - tMin))))
                                .foregroundStyle(by: .value("Serie", sTemp))
                        }
                    }
                }
                if hasPress && showPressure {
                    ForEach(d.samples) { s in
                        if let p = s.pressure {
                            LineMark(x: .value("min", Double(s.seconds) / 60.0),
                                     y: .value("m", yMax * (1 - p / pMax)))
                                .foregroundStyle(by: .value("Serie", sPress))
                        }
                    }
                }
                if let i = selIndex, i >= 0, i < d.samples.count {
                    RuleMark(x: .value("min", Double(d.samples[i].seconds) / 60.0))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale([sDepth: Color.blue, sCeil: Color.orange, sTemp: Color.red, sPress: Color.green])
            .chartLegend(.hidden)
            .chartXScale(domain: 0...xMax)
            .chartYScale(domain: [yMax, 0])
            .chartYAxis {
                AxisMarks(position: .leading, values: depthTicks) { v in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let y = v.as(Double.self) { Text(verbatim: "\(Int(y)) m") } }
                }
                if hasTemp && showTemp {
                    AxisMarks(position: .trailing, values: tempTickYs) { av in
                        AxisTick()
                        AxisValueLabel {
                            if let y = av.as(Double.self) {
                                let f = 1 - (y / yMax)
                                Text(verbatim: String(format: "%.0f°", tMin + f * (tMax - tMin)))
                            }
                        }
                    }
                }
            }
            .chartXAxisLabel("min")
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let px = v.location.x - geo[proxy.plotAreaFrame].origin.x
                                    if let minute = proxy.value(atX: px, as: Double.self) {
                                        let idx = Int((minute * 60.0 / Double(max(d.interval, 1))).rounded())
                                        selIndex = min(max(idx, 0), d.samples.count - 1)
                                    }
                                }
                        )
                }
            }
            .frame(height: height)

            readout(hasTemp: hasTemp, hasPress: hasPress, hasCeil: hasCeil, hasTts: hasTtsData, hasGf: hasGfData)
        }
    }

    // Werte-Panel UNTER dem Diagramm (verdeckt nichts). Feste Slots pro Tauchgang → keine Verschiebung.
    @ViewBuilder private func readout(hasTemp: Bool, hasPress: Bool, hasCeil: Bool, hasTts: Bool, hasGf: Bool) -> some View {
        let s: DiveSample? = selIndex.flatMap { $0 >= 0 && $0 < dive.samples.count ? dive.samples[$0] : nil }
        let cols = [GridItem(.flexible(), spacing: 10, alignment: .leading),
                    GridItem(.flexible(), spacing: 10, alignment: .leading),
                    GridItem(.flexible(), spacing: 10, alignment: .leading)]
        VStack(alignment: .leading, spacing: 4) {
            if let s {
                Text(verbatim: timeStr(s.seconds)).font(.caption.bold()).foregroundStyle(.secondary)
                LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                    metric("Tiefe", String(format: "%.1f m", s.depth), .blue)
                    if hasTemp { metric("Temp", String(format: "%.1f °C", s.temp ?? 0), .red) }
                    if hasPress { metric("Druck", String(format: "%.0f bar", s.pressure ?? 0), .green) }
                    if hasCeil { metric("Ceiling", "\(Int(s.ceiling ?? 0)) m", .orange) }
                    if hasTts { metric("TTS", ttsStr(s.tts ?? 0), .gray) }
                    if hasGf {
                        metric("GF now", "\(s.gfNow ?? 0) %", .gray)
                        metric("SurfGF", "\(s.gfSurf ?? 0) %", .gray)
                    }
                }
            } else {
                Label("Zum Ablesen über das Profil ziehen", systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder private func metric(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(LocalizedStringKey(k)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: v).bold().monospacedDigit()
        }
    }

    @ViewBuilder private func chip(_ label: String, _ color: Color, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(on.wrappedValue ? color : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                Text(LocalizedStringKey(label)).foregroundStyle(on.wrappedValue ? .primary : .secondary)
            }
        }.buttonStyle(.plain)
    }

    private func timeStr(_ sec: Int) -> String { String(format: "%d:%02d min", sec / 60, sec % 60) }
    private func ttsStr(_ sec: Int) -> String { String(format: "%d:%02d", sec / 60, sec % 60) }

    private func niceTicks(_ lo: Double, _ hi: Double, _ count: Int) -> [Double] {
        guard hi > lo, count > 0 else { return [lo] }
        let raw = (hi - lo) / Double(count)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag
        var v = (lo / step).rounded(.up) * step
        var out: [Double] = []
        while v <= hi + 0.0001 && out.count < 12 { out.append(v); v += step }
        return out
    }
}

// MARK: - Vollbild (gedreht → Querformat, auch bei Portrait-Lock)
struct FullscreenChart: View {
    let dive: ParsedDive
    let close: () -> Void
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ZStack(alignment: .topTrailing) {
                    ProfileChartView(dive: dive, height: geo.size.width - 130)
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(width: geo.size.height, height: geo.size.width)
                .rotationEffect(.degrees(90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}
