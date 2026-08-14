import Foundation
import CoreBluetooth

@MainActor
final class SymbiosBLE: NSObject, ObservableObject {
    @Published var statusText = "Bereit"
    @Published var connected = false
    @Published var scanning = false
    @Published var deviceInfo: DeviceInfo? = nil
    @Published var settingsBlob: [UInt8]? = nil
    @Published var lastError: String? = nil
    @Published var log: [String] = []

    struct DeviceInfo {
        let serial: UInt32; let hwVersion: UInt8; let model: UInt8
        let battery_mV: UInt16; let pressure_mbar: UInt16; let fw: String
        var modelName: String { model == 7 ? "Handset" : (model == 1 ? "HUD" : "Modell \(model)") }
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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func addLog(_ s: String) {
        log.append(s); if log.count > 60 { log.removeFirst(log.count - 60) }
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
        guard let p = peripheral, let wc = writeChar else { addLog("send: keine writeChar"); return nil }
        let frame = SymbiosProto.buildFrame(cmd: cmd, data: data)
        rxBuf = []; pendingCmd = cmd
        addLog("TX 0x\(hex(cmd)) (\(frame.count) B) via \(wc.uuid.uuidString.prefix(8)) [\(writeType == .withResponse ? "req" : "cmd")]")
        let raw: [UInt8]? = await withCheckedContinuation { cont in
            self.continuation = cont
            p.writeValue(Data(frame), for: wc, type: writeType)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                await self?.timeoutFire(cmd)
            }
        }
        pendingCmd = nil
        guard let raw else { return nil }
        return SymbiosProto.parseResponse(raw)
    }

    private func timeoutFire(_ cmd: UInt8) {
        if let cont = continuation { continuation = nil; addLog("⏱ Timeout 0x\(hex(cmd)) (rx \(rxBuf.count) B)"); cont.resume(returning: nil) }
    }

    func refreshAll() async {
        if let r = await send(cmd: SymbiosProto.CMD_GET_STATUS) {
            addLog("STATUS: ack=\(r.isAck) crc=\(r.crcOK) len=\(r.payload.count)")
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
        guard var blob = settingsBlob else { return (false, "Erst Einstellungen lesen.") }
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            blob = r.payload; settingsBlob = blob
        }
        for c in changes where c.offset < blob.count { blob[c.offset] = c.value }
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: blob)
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            settingsBlob = r.payload
            let bad = changes.filter { $0.offset < r.payload.count && r.payload[$0.offset] != $0.value }
            if bad.isEmpty { return (true, "OK – am Gerät bestätigt.") }
            return (false, "\(bad.count) Byte(s) nicht bestätigt.")
        }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, "Nicht bestätigt (SET: \(ackTxt)).")
    }

    /// Ganzes Profil (kompletter Blob) auf einmal schreiben + am Gerät gegenlesen.
    func writeFullBlob(_ blob: [UInt8]) async -> (Bool, String) {
        guard peripheral != nil, writeChar != nil else { return (false, "Nicht verbunden.") }
        guard blob.count >= 70 else { return (false, "Profil ungültig (\(blob.count) B).") }
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: blob)
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            settingsBlob = r.payload
            let n = min(r.payload.count, blob.count)
            let diff = (0..<n).filter { r.payload[$0] != blob[$0] }.count
            if diff == 0 { return (true, "Profil aufgespielt – am Gerät bestätigt.") }
            return (false, "\(diff)/\(n) Bytes weichen ab (evtl. geräteseitig normalisiert).")
        }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, "Nicht bestätigt (SET: \(ackTxt)).")
    }

    func writeSetting(offset: Int, value: UInt8) async -> (Bool, String) {
        guard var blob = settingsBlob else { return (false, "Erst Einstellungen lesen.") }
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count >= 70 {
            blob = r.payload; settingsBlob = blob
        }
        let patched = SymbiosSettings.patched(blob, offset: offset, value: value)
        let resp = await send(cmd: SymbiosProto.CMD_SET_SETTINGS, data: patched)
        var verified = false
        if let r = await send(cmd: SymbiosProto.CMD_GET_SETTINGS), r.crcOK, r.isAck, r.payload.count > offset {
            settingsBlob = r.payload; verified = r.payload[offset] == value
        }
        if verified { return (true, "OK – am Gerät bestätigt (\(value)).") }
        let ackTxt = resp?.isAck == true ? "ACK" : (resp?.errName ?? "keine Antwort")
        return (false, "NICHT bestätigt (SET: \(ackTxt)).")
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
        MainActor.assumeIsolated { connected = false; writeChar = nil; notifyChars = []; statusText = "Getrennt"; addLog("getrennt") }
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
