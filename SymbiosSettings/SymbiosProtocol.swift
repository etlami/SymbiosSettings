import Foundation

/// Reverse-engineerte Halcyon-Symbios BLE-Protokoll-Schicht.
/// Framing: [cmd][ack][data...][crc8].  CRC-8 Poly 0x07, init 0, über ALLES nach dem cmd-Byte (ohne crc).
enum SymbiosProto {
    // BLE-UUIDs (aus RE)
    static let advService = "18424398-7CBC-11E9-8F9E-2A86E4087070"
    static let dataService = "00000001-8C3B-4F2C-A59E-8C08224F3253"
    static let charA       = "00000101-8C3B-4F2C-A59E-8C08224F3253"  // write + notify/indicate

    // Kommandos
    static let CMD_GET_STATUS:   UInt8 = 0x01
    static let CMD_GET_SETTINGS: UInt8 = 0x02
    static let CMD_SET_SETTINGS: UInt8 = 0x03
    static let RESP_FLAG:        UInt8 = 0x80
    static let ACK: UInt8 = 0x06
    static let NAK: UInt8 = 0x15

    static let errNames = ["ERR_CRC","ERR_BOUNDARY","ERR_CMD_LENGTH","ERR_CMD_UNKNOWN","ERR_TIMEOUT","ERR_FILE","ERR_UNKNOWN"]

    /// CRC-8 (Poly 0x07, init 0)
    static func crc8(_ data: ArraySlice<UInt8>) -> UInt8 {
        var c: UInt8 = 0
        for b in data {
            c ^= b
            for _ in 0..<8 {
                if c & 0x80 != 0 { c = (c << 1) ^ 0x07 } else { c <<= 1 }
            }
        }
        return c
    }
    static func crc8(_ data: [UInt8]) -> UInt8 { crc8(data[...]) }

    /// Baut einen Sende-Frame. OHNE Daten = nur [cmd] (kein CRC – wie im echten Mitschnitt: GET_STATUS=`01`,
    /// GET_SETTINGS=`02`). MIT Daten = [cmd][data][crc8(data)] (z. B. SET_SETTINGS=`03`+84B+crc).
    static func buildFrame(cmd: UInt8, data: [UInt8] = []) -> [UInt8] {
        if data.isEmpty { return [cmd] }
        var f: [UInt8] = [cmd]
        f.append(contentsOf: data)
        f.append(crc8(data))
        return f
    }

    /// Prüft/zerlegt eine Antwort [cmd|0x80][ack][payload][crc]. Gibt (ackOK, payload) oder Fehler.
    struct Response { let cmd: UInt8; let ack: UInt8; let payload: [UInt8]; let crcOK: Bool
        var isAck: Bool { ack == SymbiosProto.ACK }
        var errName: String? { isAck ? nil : (Int(payload.first ?? 0xFF) < errNames.count ? errNames[Int(payload.first ?? 0)] : "NAK(\(payload.first ?? 0))") }
    }
    static func parseResponse(_ buf: [UInt8]) -> Response? {
        guard buf.count >= 3 else { return nil }
        let crcOK = crc8(buf[1..<(buf.count-1)]) == buf.last!
        return Response(cmd: buf[0] & 0x7F, ack: buf[1], payload: Array(buf[2..<(buf.count-1)]), crcOK: crcOK)
    }

    /// Ist der Puffer ein vollständiger Frame für erwarteten cmd? (CRC-validiert → Reassembly-Ende)
    static func isCompleteFrame(_ buf: [UInt8], expectedCmd: UInt8) -> Bool {
        guard buf.count >= 3, buf[0] == (expectedCmd | RESP_FLAG) else { return false }
        if buf[1] == NAK { return buf.count >= 4 }           // NAK ist kurz
        return crc8(buf[1..<(buf.count-1)]) == buf.last!      // ACK+data: CRC muss passen
    }
}
