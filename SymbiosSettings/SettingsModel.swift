import Foundation

/// Feld-Beschreibung für den 84-Byte-Settings-Blob (Offsets aus SYMBIOS_PROTOCOL.md §5b).
struct SettingField: Identifiable {
    enum Kind {
        case boolean
        case uint(unit: String)
        case scaledBar          // u8 ÷100 = bar
        case enumMap([Int: String])
        /// Zahlenwert → als Inline-Slider darstellbar (wenn range gesetzt).
        var isNumeric: Bool {
            switch self { case .uint, .scaledBar: return true; default: return false }
        }
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
    static let waterMap  = [0:"Salzwasser", 1:"Süßwasser", 2:"EN13319"]    // off36: 0+1 am Gerät bestätigt, 2 abgeleitet
    static let lastStopMap = [0:"3 m", 1:"6 m"]
    static let wirelessMap = [0:"Aus", 1:"Zusätzlich", 2:"Alle"]           // Labels bestätigt, Kodierung am Gerät prüfen
    static let ttsMap = [1:"Loop pO₂", 2:"Setpoint pO₂"]                   // Kodierung noch zu bestätigen
    // Bereit für später — Labels bestätigt, aber KEINE benannten Enums in der App (int-Index):
    // Kodierung/Offset erst am Gerät gegenprüfen, dann als Feld einhängen.
    static let gpsFormatMap  = [0:"DD", 1:"DDM", 2:"DMS"]                  // Kodierung blutter-bestätigt, Offset unbekannt
    static let styleMap      = [0:"Classic", 1:"Modern"]                   // Offset 4, am Gerät bestätigt ✅
    static let customFuncMap = [0:"Aus", 1:"Best Gas", 2:"Stop Watch", 3:"Heading"]  // Offset 40, am Gerät bestätigt ✅
    // Hinweis: „Deco Layout" existiert am Gerät NICHT als Enum – Menü hat nur DECO SCRN (bool, = decoScreen@41).

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
        .init(id:"style", label:"Stil", offset:4, kind:.enumMap(styleMap), editable:true, group:"Anzeigen"),

        // — Computer-Einstellungen —
        .init(id:"language", label:"Sprache (Code)", offset:0, kind:.uint(unit:""), editable:true, group:"Computer-Einstellungen"),
        .init(id:"brightness", label:"Helligkeit", offset:1, kind:.uint(unit:""), editable:true, group:"Computer-Einstellungen", range:1...9),
        .init(id:"units", label:"Einheiten", offset:2, kind:.enumMap(unitsMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"displayOrientation", label:"Display-Ausrichtung", offset:3, kind:.enumMap(orientationMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"customFunc", label:"Benutzerdef. Funktion (Taste B)", offset:40, kind:.enumMap(customFuncMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"compassDeclination", label:"Kompass-Deklination", offset:6, kind:.uint(unit:"°"), editable:true, group:"Computer-Einstellungen", range:0...90),
        .init(id:"waterType", label:"Dichte", offset:36, kind:.enumMap(waterMap), editable:true, group:"Computer-Einstellungen"),
        .init(id:"vibratorAlarmEnabled", label:"Vibrationsalarm", offset:43, kind:.boolean, editable:true, group:"Timeouts & Alarme"),
        .init(id:"sleepTimeoutMin", label:"Sleep-Timeout", offset:38, kind:.uint(unit:"min"), editable:true, group:"Timeouts & Alarme", range:1...60),
        .init(id:"buttonsOff100msw", label:"Tastensperre ab 100 m", offset:70, kind:.boolean, editable:true, group:"Computer-Einstellungen"),
        .init(id:"trainingMode", label:"Trainingsmodus", offset:62, kind:.boolean, editable:true, group:"Computer-Einstellungen"),
    ]

    static let groups = ["Tauchprofil", "CCR + CCR FSP", "Timeouts & Alarme", "Anzeigen", "Computer-Einstellungen"]

    // MARK: Custom-Felder (Screen "CF Content") — Bitmaske über Byte 48/53/63.
    struct CustomField: Identifiable {
        let id: String
        let name: String
        let offset: Int
        let bit: Int
        let group: String
        var note: String? = nil        // Verfügbarkeit (Handbuch)
    }
    static let customFields: [CustomField] = [
        // Byte 48 (empirisch bestätigt)
        .init(id:"cfAvgDepth", name:"Average Depth", offset:48, bit:0, group:"Allgemein"),
        .init(id:"cfBatSoc",   name:"Battery SOC",   offset:48, bit:1, group:"Allgemein"),
        .init(id:"cfCns",      name:"CNS",           offset:48, bit:2, group:"Allgemein"),
        .init(id:"cfTemp",     name:"Temperature",   offset:48, bit:3, group:"Allgemein"),
        .init(id:"cfAscSpeed", name:"Ascent Speed",  offset:48, bit:4, group:"Allgemein"),
        .init(id:"cfHeading",  name:"Heading",       offset:48, bit:5, group:"Allgemein", note:"nur Handset"),
        .init(id:"cfGfNow",    name:"GF Now",        offset:48, bit:6, group:"Allgemein"),
        .init(id:"cfGfSurf",   name:"GF Surface",    offset:48, bit:7, group:"Allgemein"),
        // Byte 53 (Gas / Deco / CCR)
        .init(id:"cfGasDens",  name:"Gas Density",   offset:53, bit:0, group:"Gas / Deco / CCR"),
        .init(id:"cfCcrFo2",   name:"CCR FO₂",       offset:53, bit:1, group:"Gas / Deco / CCR", note:"nur FSP/CCR"),
        .init(id:"cfBtPo2",    name:"BT PO₂",        offset:53, bit:2, group:"Gas / Deco / CCR", note:"nur Bottom-Timer"),
        .init(id:"cfBtTime",   name:"BT Time",       offset:53, bit:3, group:"Gas / Deco / CCR", note:"nur Bottom-Timer"),
        .init(id:"cfDilPo2",   name:"Diluent PO₂",   offset:53, bit:4, group:"Gas / Deco / CCR", note:"nur CCR"),
        .init(id:"cfCcrSp",    name:"CCR Setpoint",  offset:53, bit:5, group:"Gas / Deco / CCR", note:"nur CCR/FSP"),
        .init(id:"cfCeiling",  name:"Ceiling",       offset:53, bit:6, group:"Gas / Deco / CCR"),
        .init(id:"cfTts5",     name:"TTS +5",        offset:53, bit:7, group:"Gas / Deco / CCR"),
        // Byte 63 (Licht / Verbrauch / Zeit)
        .init(id:"cfLampSoc",  name:"LAMP SOC",      offset:63, bit:0, group:"Licht / Verbrauch / Zeit", note:"Licht nötig"),
        .init(id:"cfLampRrt",  name:"LAMP RRT",      offset:63, bit:1, group:"Licht / Verbrauch / Zeit", note:"Licht nötig"),
        .init(id:"cfSgc",      name:"SGC (SCR)",     offset:63, bit:2, group:"Licht / Verbrauch / Zeit", note:"nicht in CCR"),
        .init(id:"cfRgt",      name:"RGT",           offset:63, bit:3, group:"Licht / Verbrauch / Zeit", note:"nicht in CCR"),
        .init(id:"cfBuddyGas", name:"Buddy Gas",     offset:63, bit:4, group:"Licht / Verbrauch / Zeit", note:"Sender nötig"),
        .init(id:"cfTime",     name:"Time",          offset:63, bit:5, group:"Licht / Verbrauch / Zeit"),
    ]
    static let customFieldGroups = ["Allgemein", "Gas / Deco / CCR", "Licht / Verbrauch / Zeit"]

    static func cfEnabled(_ blob: [UInt8], _ cf: CustomField) -> Bool {
        cf.offset < blob.count && (blob[cf.offset] >> cf.bit) & 1 == 1
    }
    /// Neuer Byte-Wert für ein gesetztes/gelöschtes Feld-Bit.
    static func cfPatchedByte(_ blob: [UInt8], _ cf: CustomField, _ on: Bool) -> UInt8 {
        let cur = cf.offset < blob.count ? blob[cf.offset] : 0
        return on ? (cur | (1 << cf.bit)) : (cur & ~(UInt8(1) << cf.bit))
    }

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

    /// WUD Standard Gases (+ Air) — setzen O₂/He in einem Griff.
    struct StdGas { let name: String; let o2: Int; let he: Int }
    static let standardGases: [StdGas] = [
        .init(name:"Air",   o2:21,  he:0),
        .init(name:"EAN50", o2:50,  he:0),
        .init(name:"O₂",    o2:100, he:0),
        .init(name:"35/25", o2:35,  he:25),
        .init(name:"21/35", o2:21,  he:35),
        .init(name:"18/45", o2:18,  he:45),
        .init(name:"15/55", o2:15,  he:55),
        .init(name:"12/65", o2:12,  he:65),
        .init(name:"10/70", o2:10,  he:70),
    ]

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
