import Foundation

// MARK: - Export eines Tauchgangs an das eigene Logbuch (FastAPI /api/dives/import)
// Baut aus einem geparsten Dive das JSON und sendet es per POST. Dedup über ext_id.

enum LogbookUpload {

    struct Result { let created: Int; let dup: Int }

    /// Profil auf max. `maxPts` Punkte reduzieren: [[Sekunden, Tiefe, Temp?]]
    private static func profilePoints(_ dive: ParsedDive, maxPts: Int = 250) -> [[Double?]] {
        let s = dive.samples
        guard !s.isEmpty else { return [] }
        func pt(_ smp: DiveSample) -> [Double?] {
            [Double(smp.seconds), (smp.depth * 100).rounded() / 100, smp.temp.map { ($0 * 10).rounded() / 10 }]
        }
        if s.count <= maxPts { return s.map(pt) }
        let stride = Double(s.count) / Double(maxPts)
        var out: [[Double?]] = []
        for i in 0..<maxPts { out.append(pt(s[min(Int(Double(i) * stride), s.count - 1)])) }
        if let deepest = s.max(by: { $0.depth < $1.depth }) { out.append(pt(deepest)) }
        out.append(pt(s[s.count - 1]))
        // nach Zeit sortieren, Dubletten egal
        out.sort { ($0[0] ?? 0) < ($1[0] ?? 0) }
        return out
    }

    /// Einen Tauchgang (ggf. Session) ans Logbuch senden.
    static func send(dive: ParsedDive, serial: UInt32, diveId: UInt16,
                     groupIds: [UInt16], site: String?, baseURL: String,
                     amv: Double? = nil, ccr: Bool? = nil) async throws -> Result {
        guard let start = dive.start else { throw NSError(domain: "logbook", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Tauchgang ohne Startzeit"]) }
        let base = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/dives/import") else {
            throw NSError(domain: "logbook", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ungültige Logbuch-URL"]) }

        let isoFmt = ISO8601DateFormatter(); isoFmt.formatOptions = [.withInternetDateTime]
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.timeZone = .current

        let extId = groupIds.count > 1 ? "\(serial)-session-\(diveId)" : "\(serial)-\(diveId)"
        let startStr = isoFmt.string(from: start)
        let pts = profilePoints(dive)
        let durMin: Int? = dive.duration.map { Int(($0 / 60).rounded()) }
        let note = DiveParser.modeName(dive.mode)

        let maxd: Double = (dive.maxDepth * 100).rounded() / 100
        var payload = [String: Any]()
        payload["source"] = "symbios"
        payload["ext_id"] = extId
        payload["date"] = dayFmt.string(from: start)
        payload["start"] = startStr
        payload["maxdepth_m"] = maxd
        if let durMin { payload["duration_min"] = durMin }
        if let site, !site.isEmpty { payload["site"] = site }
        if let note { payload["notes"] = note }
        if let ccr { payload["ccr"] = ccr }
        if let amv, amv > 0 { payload["amv"] = (amv * 10).rounded() / 10 }
        if !pts.isEmpty {
            let ptsJSON: [[Any]] = pts.map { row in row.map { $0 == nil ? NSNull() : $0! as Any } }
            var prof = [String: Any]()
            prof["dur"] = pts.last?[0] ?? 0
            prof["maxd"] = maxd
            prof["pts"] = ptsJSON
            payload["profile"] = prof
        }

        let body = try JSONSerialization.data(withJSONObject: [payload])
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 25

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "logbook", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Server-Fehler \(code)"])
        }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Result(created: (j["n_created"] as? Int) ?? 0, dup: (j["n_dup"] as? Int) ?? 0)
    }
}
