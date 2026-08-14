import Foundation

/// Feld-Beschreibung für den 84-Byte-Settings-Blob (Offsets aus SYMBIOS_PROTOCOL.md §5b).
struct SettingField: Identifiable {
    enum Kind {
        case boolean
        case uint(unit: String)
        case scaledBar          // u8 ÷100 = bar
        case enumMap([Int: String])
    }
    let id: String
    let label: String
    let offset: Int
    let kind: Kind
    let editable: Bool
    var group: String
    var range: ClosedRange<Double>? = nil   // Roh-Byte-Bereich → Slider im Editor
}

enum SymbiosSettings {
    static let blobLength = 84

    // Enum-Werte. „blutter-bestätigt" = Zahl-Kodierung aus dem Dart-Code der SymJunk-App
    // verifiziert (2026-08-14, siehe symbios/re/SYMJUNK_BLUTTER_FINDINGS.md). Sonst tentativ.
    static let dcModeMap = [0:"Offener Kreislauf", 1:"Geschl. Kreislauf",
                            2:"CCR Fester Sollwert", 3:"Sidemount", 4:"Grundzeitmesser"]  // blutter-bestätigt
    static let unitsMap  = [0:"Metrisch", 1:"Imperial"]                    // blutter-bestätigt
    static let orientationMap = [0:"Links", 1:"Rechts"]                    // Kodierung blutter-bestätigt (Offset 3 am Gerät prüfen)
    static let waterMap  = [0:"Salzwasser", 1:"Süßwasser", 2:"EN13319"]    // 0 bestätigt, 1/2 tentativ
    static let lastStopMap = [0:"3 m", 1:"6 m"]
    static let wirelessMap = [0:"Aus", 1:"Zusätzlich", 2:"Alle"]           // Labels bestätigt, Kodierung am Gerät prüfen
    static let ttsMap = [1:"Loop pO₂", 2:"Setpoint pO₂"]                   // Kodierung noch zu bestätigen
    // Bereit für später — Labels bestätigt, aber KEINE benannten Enums in der App (int-Index):
    // Kodierung/Offset erst am Gerät gegenprüfen, dann als Feld einhängen.
    static let gpsFormatMap  = [0:"DD", 1:"DDM", 2:"DMS"]                  // Kodierung blutter-bestätigt, Offset unbekannt
    static let styleMap      = [0:"Modern", 1:"Classic"]                   // Reihenfolge tentativ
    static let decoLayoutMap = [0:"Decke + Letzter Stopp", 1:"Decke + TTS",
                                2:"Decke + Letzter Stopp + TTS"]           // Reihenfolge tentativ

    /// Felder – gruppiert wie die offizielle App (Tauchprofil · CCR+CCR FSP · Anzeigen · Computer-Einstellungen).
    static let fields: [SettingField] = [
        // — Tauchprofil —
        .init(id:"dcMode", label:"Tauchmodus", offset:9, kind:.enumMap(dcModeMap), editable:true, group:"Tauchprofil"),
        .init(id:"gfLow", label:"GF Low", offset:8, kind:.uint(unit:"%"), editable:true, group:"Tauchprofil", range:5...95),
        .init(id:"gfHigh", label:"GF High", offset:7, kind:.uint(unit:"%"), editable:true, group:"Tauchprofil", range:5...100),
        .init(id:"ocMaxPO2Deco", label:"OC PO₂ Deco", offset:37, kind:.scaledBar, editable:true, group:"Tauchprofil", range:100...160),
        .init(id:"ocMaxPO2Bottom", label:"OC PO₂ Grund", offset:68, kind:.scaledBar, editable:true, group:"Tauchprofil", range:100...160),
        .init(id:"safetyStopEnabled", label:"Sicherheitsstopp", offset:11, kind:.boolean, editable:true, group:"Tauchprofil"),
        .init(id:"lastStopAt6Msw", label:"Letzter Stopp", offset:69, kind:.enumMap(lastStopMap), editable:true, group:"Tauchprofil"),
        .init(id:"ascentSpeedWarningEnabled", label:"Aufstiegswarnung", offset:71, kind:.boolean, editable:true, group:"Timeouts & Alarme"),
        .init(id:"diveTimeoutMin", label:"Dive-Timeout", offset:10, kind:.uint(unit:"min"), editable:true, group:"Timeouts & Alarme", range:1...30),

        // — CCR + CCR FSP —
        .init(id:"setpointLow", label:"FSP SP LOW", offset:60, kind:.scaledBar, editable:true, group:"CCR + CCR FSP", range:50...110),
        .init(id:"setpointHigh", label:"FSP SP HI", offset:61, kind:.scaledBar, editable:true, group:"CCR + CCR FSP", range:100...150),
        .init(id:"scrubberCounterEnabled", label:"Scrubber-Zähler", offset:44, kind:.boolean, editable:true, group:"CCR + CCR FSP"),
        .init(id:"scrubberCounterTimeMin", label:"Scrubber-Zähler-Timeout", offset:46, kind:.uint(unit:"min"), editable:true, group:"CCR + CCR FSP", range:0...240),
        .init(id:"ccrPO2TtsForcast", label:"CCR TTS-Prognose", offset:75, kind:.enumMap(ttsMap), editable:true, group:"CCR + CCR FSP"),

        // — Anzeigen —
        .init(id:"buddyScreen", label:"Buddy-Screen", offset:45, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"decoScreen", label:"Deko-Screen", offset:41, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"depthChartScreen", label:"Tiefenchart-Screen", offset:59, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"gfChartScreen", label:"GF-Chart-Screen", offset:58, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"gpsScreenEnabled", label:"GPS-Screen", offset:74, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"dpvScreenEnabled", label:"DPV-Screen", offset:73, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"hudSimpleCCRScreenEnabled", label:"HUD einfacher CCR-Screen", offset:77, kind:.boolean, editable:true, group:"Anzeigen"),
        .init(id:"wirelessScreen", label:"Wireless-Screen", offset:42, kind:.enumMap(wirelessMap), editable:true, group:"Anzeigen"),

        // — Computer-Einstellungen —
        .init(id:"language", label:"Sprache (Code)", offset:0, kind:.uint(unit:""), editable:true, group:"Computer-Einstellungen"),
        .init(id:"brightness", label:"Helligkeit", offset:1, kind:.uint(unit:""), editable:true, group:"Computer-Einstellungen", range:1...9),
        .init(id:"units", label:"Einheiten", offset:2, kind:.enumMap(unitsMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"displayOrientation", label:"Display-Ausrichtung", offset:3, kind:.enumMap(orientationMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"compassDeclination", label:"Kompass-Deklination", offset:6, kind:.uint(unit:"°"), editable:true, group:"Computer-Einstellungen", range:0...90),
        .init(id:"waterType", label:"Dichte", offset:36, kind:.enumMap(waterMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"vibratorAlarmEnabled", label:"Vibrationsalarm", offset:43, kind:.boolean, editable:true, group:"Timeouts & Alarme"),
        .init(id:"sleepTimeoutMin", label:"Sleep-Timeout", offset:38, kind:.uint(unit:"min"), editable:true, group:"Timeouts & Alarme", range:1...60),
        .init(id:"buttonsOff100msw", label:"Tastensperre ab 100 m", offset:70, kind:.boolean, editable:true, group:"Computer-Einstellungen"),
        .init(id:"trainingMode", label:"Trainingsmodus", offset:62, kind:.boolean, editable:true, group:"Computer-Einstellungen"),
    ]

    static let groups = ["Tauchprofil", "CCR + CCR FSP", "Timeouts & Alarme", "Anzeigen", "Computer-Einstellungen"]

    // --- Werte lesen/formatieren ---
    static func rawValue(_ blob: [UInt8], _ f: SettingField) -> Int {
        guard f.offset < blob.count else { return 0 }
        return Int(blob[f.offset])
    }
    static func display(_ blob: [UInt8], _ f: SettingField) -> String {
        let v = rawValue(blob, f)
        switch f.kind {
        case .boolean: return v != 0 ? "An" : "Aus"
        case .uint(let u): return u.isEmpty ? "\(v)" : "\(v) \(u)"
        case .scaledBar: return String(format: "%.2f bar", Double(v)/100.0)
        case .enumMap(let m): return m[v] ?? "?\(v)"
        }
    }

    /// gasTable @12-35: 8 Slots (5 OC + 3 DIL), O2[8]@12, He[8]@20, aktiv[8]@28.
    static let gasNames = ["Gas 1","Gas 2","Gas 3","Gas 4","Gas 5","Dil 1","Dil 2","Dil 3"]
    static let o2Presets = [12, 18, 25, 32, 50, 100]
    static let hePresets = [0, 35, 45, 55, 65, 70]

    /// Anzeige wie in der offiziellen App: Air / Nx32 / 18/45 / O₂.
    static func gasLabel(o2: Int, he: Int) -> String {
        if he > 0 { return "\(o2)/\(he)" }
        if o2 >= 100 { return "O₂" }
        if o2 == 21 { return "Air" }
        return "Nx\(o2)"
    }

    struct GasSlot: Identifiable {
        let id: Int
        var o2: Int, he: Int, active: Bool
        var name: String { SymbiosSettings.gasNames[id] }
        var n2: Int { max(0, 100 - o2 - he) }
        var o2Offset: Int { 12 + id }
        var heOffset: Int { 20 + id }
        var activeOffset: Int { 28 + id }
        var isEmpty: Bool { o2 == 0 && he == 0 && !active }
        /// MOD in m bei ppO₂ 1.4 (10 m ≈ 1 bar).
        var mod14: Int { o2 <= 0 ? 0 : max(0, Int((1.4 / (Double(o2)/100.0) - 1.0) * 10.0)) }
    }

    /// Alle 8 Slots (auch leere) – für den Editor.
    static func gasSlots(_ blob: [UInt8]) -> [GasSlot] {
        guard blob.count >= 36 else { return [] }
        return (0..<8).map { GasSlot(id: $0, o2: Int(blob[12+$0]), he: Int(blob[20+$0]), active: blob[28+$0] != 0) }
    }

    /// Nur belegte Slots – für die Übersicht.
    static func gasTable(_ blob: [UInt8]) -> [GasSlot] { gasSlots(blob).filter { !$0.isEmpty } }

    /// Read-modify-write: setzt EIN Byte an offset, gibt neuen Blob zurück (Länge bleibt).
    static func patched(_ blob: [UInt8], offset: Int, value: UInt8) -> [UInt8] {
        var b = blob
        if offset < b.count { b[offset] = value }
        return b
    }

    /// Beispiel-Blob (echte Aufnahme) für Demo/Simulator ohne BLE.
    static let demoBlob: [UInt8] = {
        let hex = "01050004010200580b0207011532631512151512000000232d00232d010000000001000002a005050101000100003c008888888800c0c0c0c00001014682000000000000a0000001000000020001000000000000"
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!); i = j
        }
        return out
    }()
}
