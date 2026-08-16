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
}

struct ParsedDive {
    var number: Int?
    var start: Date?
    var end: Date?
    var maxDepth: Double = 0
    var minTemp: Double?
    var serial: UInt32?
    var model: UInt8?       // 7=Handset, 1=HUD (Header @2)
    var mode: Int?          // dcMode 0=OC…4=Gauge (Header @11, PROVISORISCH – noch zu bestätigen)
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
        while i + 2 <= d.count {
            let id = d[i]; let len = Int(d[i+1])
            if len < 2 || i + len > d.count { break }
            let rec = Array(d[i..<i+len])
            switch id {
            case 0x01:  // HEADER (64): @2 model, @11 dcMode(?), @16 atmospheric, @18 number, @24 time_start, @28 serial
                if rec.count >= 3 { p.model = rec[2] }
                if rec.count >= 12 { p.mode = Int(rec[11]) }   // PROVISORISCH (Kandidaten @11/@13/@14)
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
            case 0x0A:  // DECO (16): @3 u8 ceiling (m)
                if rec.count >= 4 { lastCeiling = Double(rec[3]) }
            case 0x03:  // DEPTH (4): @2 u16 cm  → ein Sample-Zyklus
                if rec.count >= 4 {
                    let m = Double(u16(rec, 2)) / 100.0
                    p.maxDepth = max(p.maxDepth, m)
                    p.samples.append(DiveSample(id: sampleIdx, seconds: sampleIdx * p.interval,
                                                depth: m, temp: lastTemp, ceiling: lastCeiling))
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
        s += "\nINDEX;SECONDS;DEPTH_M;TEMP_C;CEILING_M\n"
        for smp in p.samples {
            let temp = smp.temp.map { String(format: "%.1f", $0) } ?? ""
            let ceil = smp.ceiling.map { String(format: "%.0f", $0) } ?? ""
            s += String(format: "%d;%d;%.2f;%@;%@\n", smp.id, smp.seconds, smp.depth, temp, ceil)
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
                    Section("Tiefenprofil") { profileChart(d) }
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

    // Tiefe links (m), Temperatur rechts (°C), Deko-Decke (m) – gemeinsame Meter-Domain,
    // Temperatur wird in den Tiefen-Koordinatenraum abgebildet (warm oben, kalt unten).
    @ViewBuilder private func profileChart(_ d: ParsedDive) -> some View {
        let dMax = max(d.maxDepth, 1)
        let temps = d.samples.compactMap { $0.temp }
        let tMin = temps.min() ?? 0
        let tMaxRaw = temps.max() ?? 0
        let tMax = (tMaxRaw - tMin) < 0.5 ? tMin + 1 : tMaxRaw
        let hasTemp = !temps.isEmpty
        let hasCeil = d.samples.contains { ($0.ceiling ?? 0) > 0 }
        let tempTickVals: [Double] = hasTemp ? niceTicks(tMin, tMax, 4) : []
        let tempTickYs = tempTickVals.map { dMax * (1 - ($0 - tMin) / (tMax - tMin)) }
        let sDepth = LT("Tiefe"), sCeil = LT("Decke"), sTemp = LT("Temp")

        Chart {
            ForEach(d.samples) { s in
                LineMark(x: .value("min", Double(s.seconds) / 60.0), y: .value("m", s.depth))
                    .foregroundStyle(by: .value("Serie", sDepth))
            }
            if hasCeil {
                ForEach(d.samples) { s in
                    LineMark(x: .value("min", Double(s.seconds) / 60.0), y: .value("m", s.ceiling ?? 0))
                        .foregroundStyle(by: .value("Serie", sCeil))
                }
            }
            if hasTemp {
                ForEach(d.samples) { s in
                    if let t = s.temp {
                        LineMark(x: .value("min", Double(s.seconds) / 60.0),
                                 y: .value("m", dMax * (1 - (t - tMin) / (tMax - tMin))))
                            .foregroundStyle(by: .value("Serie", sTemp))
                    }
                }
            }
        }
        .chartForegroundStyleScale([sDepth: Color.blue, sCeil: Color.orange, sTemp: Color.red])
        .chartYScale(domain: .automatic(includesZero: true, reversed: true))
        .chartYAxis {
            AxisMarks(position: .leading)   // Tiefe (m)
            if hasTemp {
                AxisMarks(position: .trailing, values: tempTickYs) { axisValue in
                    AxisTick()
                    AxisValueLabel {
                        if let y = axisValue.as(Double.self) {
                            let f = 1 - (y / dMax)
                            Text(String(format: "%.0f°", tMin + f * (tMax - tMin)))
                        }
                    }
                }
            }
        }
        .chartXAxisLabel("min")
        .frame(height: 210)
    }

    /// „Schöne" Tick-Werte (1/2/5×10ⁿ) zwischen lo und hi.
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
