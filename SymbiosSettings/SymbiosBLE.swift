import Foundation
import CoreBluetooth

@MainActor
final class SymbiosBLE: NSObject, ObservableObject {
    @Published var statusText = "Bereit"
    @Published var connected = false
    @Published var ready = false          // Notify aktiv → bereit für Auto-Lesen
    @Published var scanning = false
    @Published var deviceInfo: DeviceInfo? = nil
    @Published var settingsBlob: [UInt8]? = nil
    @Published var lastError: String? = nil
    @Published var log: [String] = []
    @Published var xferProgress: Double? = nil    // 0…1 während Logbuch/Dive-Download

    struct DiveIndexEntry: Identifiable, Codable {
        let id: Int          // Reihenfolge im Index
        let diveId: UInt16   // Argument für DIVELOG_REQUEST
        let raw: [UInt8]     // 32-Byte-Index-Eintrag
    }

    struct DeviceInfo {
        let serial: UInt32; let hwVersion: UInt8; let model: UInt8
        let battery_mV: UInt16; let pressure_mbar: UInt16; let fw: String
        var modelName: String { model == 7 ? "Handset" : (model == 1 ? "HUD" : "Modell \(model)") }
        /// Geschätzter Ladestand aus der Zellspannung (1-Zellen-LiPo-Kennlinie). Näherung –
        /// das Gerät sendet seinen intern berechneten SoC NICHT über BLE (Status-Bytes 19–35 = 0),
        /// daher kann der Wert leicht vom Computer abweichen. Kalibriert an 4,04 V → ~83 %.
        var batteryPct: Int {
            let v = Double(battery_mV) / 1000.0
            let pts: [(Double, Double)] = [(3.27,0),(3.61,5),(3.69,10),(3.73,20),(3.75,25),
                                           (3.77,30),(3.79,35),(3.80,40),(3.82,45),(3.84,50),
                                           (3.85,55),(3.87,60),(3.91,65),(3.95,70),(3.98,75),
                                           (4.02,80),(4.08,85),(4.11,90),(4.15,95),(4.20,100)]
            if v <= pts.first!.0 { return 0 }
            if v >= pts.last!.0 { return 100 }
            for i in 1..<pts.count where v <= pts[i].0 {
                let (v0,p0) = pts[i-1], (v1,p1) = pts[i]
                return Int((p0 + (p1-p0) * (v-v0)/(v1-v0)).rounded())
            }
            return 100
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?          // Kommandos raus
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var notifyChars: [CBCharacteristic] = []  // Antworten rein (kann CH_B sein)

    // Reassembly + In-flight-Kommando
    private var rxBuf: [UInt8] = []
    private var pendingCmd: UInt8?
    private var continuation: CheckedContinuation<[UInt8]?, Never>?
    private var pendingSeq: UInt64 = 0     // Generation je Anfrage → verhindert, dass alte Timeout-Tasks feuern

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func addLog(_ s: String) {
        log.append(s); if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func startScan() {
        guard central.state == .poweredOn else { statusText = "Bluetooth aus?"; addLog("BT-State: \(central.state.rawValue)"); return }
        let known = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: SymbiosProto.dataService)])
        if let p = known.first { addLog("bereits verbunden: \(p.name ?? "?")"); connect(p); return }
        scanning = true; statusText = "Suche Symbios…"; addLog("Scan gestartet")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() { if let p = peripheral { central.cancelPeripheralConnection(p) } }

    private func connect(_ p: CBPeripheral) {
        central.stopScan(); scanning = false
        peripheral = p; p.delegate = self
        statusText = "Verbinde…"
        central.connect(p, options: nil)
    }

    // MARK: - Kommandos (async)
    func send(cmd: UInt8, data: [UInt8] = [], timeout: TimeInterval = 8) async -> SymbiosProto.Response? {
        await sendFrame(SymbiosProto.buildFrame(cmd: cmd, data: data), expect: cmd, timeout: timeout)
    }

    /// Sendet einen fertigen Frame und wartet auf die Antwort mit Basis-Cmd `expect`.
    /// Trennung nötig fürs Block-Protokoll: Folge-Blöcke werden per bare-ACK (0x06) angefordert,
    /// antworten aber als Block-Frame (0x88/0x89) – TX-Byte ≠ erwartetes Antwort-Cmd.
    private func sendFrame(_ frame: [UInt8], expect: UInt8, timeout: TimeInterval = 8) async -> SymbiosProto.Response? {
        guard let p = peripheral, let wc = writeChar else { addLog("send: keine writeChar"); return nil }
        pendingSeq &+= 1
        let mySeq = pendingSeq
        rxBuf = []; pendingCmd = expect
        addLog("TX 0x\(hex(frame.first ?? 0)) →exp 0x\(hex(expect)) (\(frame.count) B) [\(writeType == .withResponse ? "req" : "cmd")]")
        let raw: [UInt8]? = await withCheckedContinuation { cont in
            self.continuation = cont
            p.writeValue(Data(frame), for: wc, type: writeType)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                await self?.timeoutFire(expect, seq: mySeq)
            }
        }
        pendingCmd = nil
        guard let raw else { return nil }
        return SymbiosProto.parseResponse(raw)
    }

    /// Frame senden ohne auf Antwort zu warten (finaler ACK am Blockende).
    private func writeNoWait(_ frame: [UInt8]) {
        guard let p = peripheral, let wc = writeChar else { return }
        p.writeValue(Data(frame), for: wc, type: writeType)
    }

    private func timeoutFire(_ cmd: UInt8, seq: UInt64) {
        // Nur feuern, wenn dieser Timeout zur AKTUELL laufenden Anfrage gehört (kein Alt-Timer).
        guard seq == pendingSeq, let cont = continuation else { return }
        continuation = nil; addLog("⏱ Timeout 0x\(hex(cmd)) (rx \(rxBuf.count) B)"); cont.resume(returning: nil)
    }

    func refreshAll() async {
        if let r = await send(cmd: SymbiosProto.CMD_GET_STATUS) {
            addLog("STATUS: ack=\(r.isAck) crc=\(r.crcOK) len=\(r.payload.count)")
            addLog("STATUS hex: " + r.payload.map { String(format: "%02x", $0) }.joined())
            if r.crcOK, r.isAck { deviceInfo = parseStatus(r.payload) }
        }
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS) {
            addLog("SETTINGS: ack=\(r.isAck) crc=\(r.crcOK) len=\(r.payload.count)")
            if r.crcOK, r.isAck, r.payload.count >= 70 { settingsBlob = r.payload }
        }
    }

    /// Mehrere Bytes in EINEM SET_SETTINGS schreiben (read-modify-write) + gegenlesen.
    /// Für den Gas-Editor (O₂/He/aktiv eines Slots = 3 Bytes) atomar.
    func writePatched(_ changes: [(offset: Int, value: UInt8)]) async -> (Bool, String) {
        guard var blob = settingsBlob else { return (false, LT("Erst Einstellungen lesen.")) }
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            blob = r.payload; settingsBlob = blob
        }
        for c in changes where c.offset < blob.count { blob[c.offset] = c.value }
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: blob)
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            settingsBlob = r.payload
            let bad = changes.filter { $0.offset < r.payload.count && r.payload[$0.offset] != $0.value }
            if bad.isEmpty { return (true, LT("OK – am Gerät bestätigt.")) }
            return (false, LT("\(bad.count) Byte(s) nicht bestätigt."))
        }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, LT("Nicht bestätigt (SET: \(ackTxt))."))
    }

    /// Ganzes Profil (kompletter Blob) auf einmal schreiben + am Gerät gegenlesen.
    func writeFullBlob(_ blob: [UInt8]) async -> (Bool, String) {
        guard peripheral != nil, writeChar != nil else { return (false, LT("Nicht verbunden.")) }
        guard blob.count >= 70 else { return (false, LT("Profil ungültig (\(blob.count) B).")) }
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: blob)
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            settingsBlob = r.payload
            let n = min(r.payload.count, blob.count)
            let diff = (0..<n).filter { r.payload[$0] != blob[$0] }.count
            if diff == 0 { return (true, LT("Profil aufgespielt – am Gerät bestätigt.")) }
            return (false, LT("\(diff)/\(n) Bytes weichen ab (evtl. geräteseitig normalisiert)."))
        }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, LT("Nicht bestätigt (SET: \(ackTxt))."))
    }

    func writeSetting(offset: Int, value: UInt8) async -> (Bool, String) {
        guard var blob = settingsBlob else { return (false, LT("Erst Einstellungen lesen.")) }
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            blob = r.payload; settingsBlob = blob
        }
        let patched = SymbiosSettings.patched(blob, offset: offset, value: value)
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: patched)
        var verified = false
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count > offset {
            settingsBlob = r.payload; verified = r.payload[offset] == value
        }
        if verified { return (true, LT("OK – am Gerät bestätigt (\(Int(value))).")) }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, LT("NICHT bestätigt (SET: \(ackTxt))."))
    }

    // MARK: - Uhr stellen (SET_TIME 0x07)
    /// Stellt die Geräteuhr auf die aktuelle lokale Zeit. `[Jahr-2000, Monat, Tag, Std, Min, Sek]`.
    func syncTime() async -> (Bool, String) {
        let c = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: Date())
        guard let y = c.year, let mo = c.month, let d = c.day,
              let h = c.hour, let mi = c.minute, let s = c.second else { return (false, LT("Zeit unbekannt.")) }
        let data: [UInt8] = [UInt8(clamping: y - 2000), UInt8(mo), UInt8(d), UInt8(h), UInt8(mi), UInt8(s)]
        guard let r = await send(cmd: SymbiosProto.CMD_SET_TIME, data: data) else { return (false, LT("Keine Antwort.")) }
        if r.isAck {
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm:ss"
            return (true, LT("Uhr gestellt: ") + f.string(from: Date()))
        }
        return (false, r.errName ?? LT("Vom Gerät abgelehnt."))
    }

    // MARK: - Blockdownload (Logbuch/Dive) – Mechanik autoritativ aus libdivecomputer halcyon_symbios.c
    /// REQUEST senden → 4-Byte-Gesamtlänge (LE) → Kick-off-BLOCK, dann je Block bare-ACK anfordern
    /// bis Bit 0x8000 in der Block-ID gesetzt ist. Read-only (schreibt nichts aufs Gerät).
    private func downloadBlocks(requestCmd: UInt8, requestData: [UInt8], blockCmd: UInt8) async -> [UInt8]? {
        guard let r = await send(cmd: requestCmd, data: requestData), r.crcOK, r.isAck else {
            addLog("REQUEST 0x\(hex(requestCmd)) fehlgeschlagen"); return nil
        }
        let total: Int = r.payload.count >= 4
            ? Int(UInt32(r.payload[0]) | (UInt32(r.payload[1])<<8) | (UInt32(r.payload[2])<<16) | (UInt32(r.payload[3])<<24))
            : 0
        addLog("Download 0x\(hex(requestCmd)) total=\(total) B")
        var out: [UInt8] = []
        xferProgress = 0
        var resp = await send(cmd: blockCmd)          // erster Block (Kick-off)
        var blk = 0
        while let rb = resp {
            blk += 1; if blk > 20000 { addLog("⚠︎ Block-Limit erreicht"); break }
            guard rb.crcOK, rb.isAck, rb.payload.count >= 2 else {
                addLog("Block \(blk) ungültig (crc=\(rb.crcOK) ack=\(rb.isAck) len=\(rb.payload.count))")
                xferProgress = nil; return out.isEmpty ? nil : out
            }
            let seq = UInt16(rb.payload[0]) | (UInt16(rb.payload[1]) << 8)
            let last = seq & 0x8000 != 0
            out.append(contentsOf: rb.payload[2...])
            addLog("blk \(blk) seq=0x\(String(format:"%04x",seq))\(last ? " LAST" : "") +\(rb.payload.count-2) Σ\(out.count)")
            if total > 0 { xferProgress = min(1.0, Double(out.count) / Double(total)) }
            if last { writeNoWait([SymbiosProto.ACK]); break }   // letzter Block → ACK, fertig
            resp = await sendFrame([SymbiosProto.ACK], expect: blockCmd)
        }
        if resp == nil { addLog("⏱ kein Block nach \(blk) (Timeout)") }
        xferProgress = nil
        addLog("Download fertig: \(out.count) B")
        return out.isEmpty ? nil : out
    }

    /// Logbuch-Index laden → Liste (32-Byte-Einträge, dive_id @16 u16 LE). Reiner Download (Cache = LogbookStore).
    func downloadLogbookIndex() async -> [DiveIndexEntry]? {
        guard let raw = await downloadBlocks(requestCmd: SymbiosProto.CMD_LOGBOOK_REQUEST, requestData: [],
                                             blockCmd: SymbiosProto.CMD_LOGBOOK_BLOCK) else { return nil }
        let sz = 32
        var entries: [DiveIndexEntry] = []; var i = 0; var idx = 0
        while i + sz <= raw.count {
            let e = Array(raw[i..<i+sz])
            let did = UInt16(e[16]) | (UInt16(e[17]) << 8)
            entries.append(DiveIndexEntry(id: idx, diveId: did, raw: e))
            i += sz; idx += 1
        }
        addLog("Logbuch: \(entries.count) Einträge (\(raw.count) B)")
        return entries
    }

    /// Einen Tauchgang als Roh-Record (TLV, §8) laden. Reiner Download (Cache = LogbookStore).
    func downloadDive(_ diveId: UInt16) async -> [UInt8]? {
        await downloadBlocks(requestCmd: SymbiosProto.CMD_DIVELOG_REQUEST,
                             requestData: [UInt8(diveId & 0xFF), UInt8(diveId >> 8)],
                             blockCmd: SymbiosProto.CMD_DIVELOG_BLOCK)
    }

    // MARK: - Parser
    private func parseStatus(_ d: [UInt8]) -> DeviceInfo? {
        guard d.count >= 19 else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o+1]) << 8) }
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | (UInt32(d[o+1])<<8) | (UInt32(d[o+2])<<16) | (UInt32(d[o+3])<<24) }
        return DeviceInfo(serial: u32(0), hwVersion: d[4], model: d[5],
                          battery_mV: u16(8), pressure_mbar: u16(10), fw: "\(d[16]).\(d[17]).\(d[18])")
    }
    private func hex(_ b: UInt8) -> String { String(format: "%02x", b) }
    private func propsDesc(_ p: CBCharacteristicProperties) -> String {
        var a: [String] = []
        if p.contains(.write) { a.append("write") }
        if p.contains(.writeWithoutResponse) { a.append("writeNR") }
        if p.contains(.notify) { a.append("notify") }
        if p.contains(.indicate) { a.append("indicate") }
        if p.contains(.read) { a.append("read") }
        return a.joined(separator: ",")
    }
}

// MARK: - Delegates (main-queue → assumeIsolated)
extension SymbiosBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            switch c.state {
            case .poweredOn: statusText = "Bluetooth bereit"
            case .poweredOff: statusText = "Bluetooth aus"; connected = false
            case .unauthorized: statusText = "Bluetooth nicht erlaubt"
            default: statusText = "Bluetooth: \(c.state.rawValue)"
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let isSymbios = svcs.contains(CBUUID(string: SymbiosProto.advService))
                || svcs.contains(CBUUID(string: SymbiosProto.dataService))
                || (name.count >= 8 && name.allSatisfy(\.isNumber))
            if isSymbios { addLog("gefunden: \(name.isEmpty ? "?" : name)"); connect(p) }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            connected = true; statusText = "Verbunden – suche Services…"; addLog("verbunden, discover Services")
            p.discoverServices(nil)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { connected = false; ready = false; writeChar = nil; notifyChars = []; statusText = "Getrennt"; addLog("getrennt") }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] {
                addLog("Service \(s.uuid.uuidString.prefix(8))")
                p.discoverCharacteristics(nil, for: s)   // ALLE Chars, damit CH_B nicht verpasst wird
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chaUUID = CBUUID(string: SymbiosProto.charA)   // Kommandos MÜSSEN an CH_A (00000101)
            for ch in s.characteristics ?? [] {
                addLog("Char \(ch.uuid.uuidString.prefix(8)) [\(propsDesc(ch.properties))]")
                // Schreibkanal explizit = CH_A; Antworten kommen (Indication) auf CH_B → wir lauschen auf beiden.
                if ch.uuid == chaUUID {
                    writeChar = ch
                    writeType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
                }
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    notifyChars.append(ch); p.setNotifyValue(true, for: ch)
                }
            }
            // Fallback, falls CH_A nicht gefunden: erste schreibbare Char
            if writeChar == nil {
                for ch in s.characteristics ?? [] where ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                    writeChar = ch; writeType = ch.properties.contains(.write) ? .withResponse : .withoutResponse; break
                }
            }
            if writeChar != nil { addLog("Schreibkanal = \(writeChar!.uuid.uuidString.prefix(8))"); statusText = "Verbunden ✓ (bereit zum Lesen)" }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            addLog("Notify \(ch.uuid.uuidString.prefix(8)) = \(ch.isNotifying)\(error != nil ? " ERR" : "")")
            if ch.isNotifying, writeChar != nil, !ready { ready = true }   // → ContentView löst Auto-Lesen aus
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let d = ch.value else { return }
            let bytes = [UInt8](d)
            addLog("RX \(bytes.count) B von \(ch.uuid.uuidString.prefix(8)): \(bytes.prefix(6).map { hex($0) }.joined())")
            guard let cmd = pendingCmd else { return }
            rxBuf.append(contentsOf: bytes)
            if SymbiosProto.isCompleteFrame(rxBuf, expectedCmd: cmd), let cont = continuation {
                continuation = nil; addLog("✓ Frame komplett (\(rxBuf.count) B)"); cont.resume(returning: rxBuf)
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { if let e = error { addLog("Write-Fehler: \(e.localizedDescription)") } }
    }
}
