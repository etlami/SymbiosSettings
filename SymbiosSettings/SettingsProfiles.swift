import SwiftUI

/// Ein gespeichertes Settings-Profil = kompletter 84-Byte-Blob unter einem Namen.
struct SettingsProfile: Identifiable, Codable {
    var id = UUID()
    var name: String
    var hex: String
    var saved: Date
    var isAuto: Bool = false

    var blob: [UInt8] { SettingsProfile.bytes(hex) }
    var byteCount: Int { hex.count / 2 }

    static func hex(_ blob: [UInt8]) -> String { blob.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }; i = j
        }
        return out
    }
}

/// Persistente Profil-Verwaltung (UserDefaults). Manuelle Profile + automatische Backups.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [SettingsProfile] = []   // manuell, neueste zuerst
    @Published private(set) var autoBackups: [SettingsProfile] = [] // automatisch beim Lesen

    private let keyManual = "symbios.profiles.v1"
    private let keyAuto   = "symbios.autobackups.v1"
    private let maxAuto   = 5

    init() { load() }

    private func load() {
        let d = UserDefaults.standard
        if let raw = d.data(forKey: keyManual), let v = try? JSONDecoder().decode([SettingsProfile].self, from: raw) { profiles = v }
        if let raw = d.data(forKey: keyAuto), let v = try? JSONDecoder().decode([SettingsProfile].self, from: raw) { autoBackups = v }
    }
    private func persist() {
        let d = UserDefaults.standard
        if let raw = try? JSONEncoder().encode(profiles) { d.set(raw, forKey: keyManual) }
        if let raw = try? JSONEncoder().encode(autoBackups) { d.set(raw, forKey: keyAuto) }
    }

    func save(name: String, blob: [UInt8]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = SettingsProfile(name: clean.isEmpty ? "Profil \(profiles.count + 1)" : clean,
                                hex: SettingsProfile.hex(blob), saved: Date())
        profiles.insert(p, at: 0); persist()
    }
    func delete(_ p: SettingsProfile) {
        profiles.removeAll { $0.id == p.id }; autoBackups.removeAll { $0.id == p.id }; persist()
    }
    func rename(_ p: SettingsProfile, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines); persist()
    }

    /// Automatisches Backup beim erfolgreichen Lesen. Dedupliziert (kein Backup wenn identisch zum letzten).
    func autoBackup(_ blob: [UInt8]) {
        let h = SettingsProfile.hex(blob)
        if autoBackups.first?.hex == h { return }
        let df = DateFormatter(); df.dateFormat = "dd.MM. HH:mm"
        let p = SettingsProfile(name: "Auto \(df.string(from: Date()))", hex: h, saved: Date(), isAuto: true)
        autoBackups.insert(p, at: 0)
        if autoBackups.count > maxAuto { autoBackups.removeLast(autoBackups.count - maxAuto) }
        persist()
    }
}

/// Liste der Profile mit Aufspielen (voller Blob) + Löschen.
struct ProfilesView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var ble: SymbiosBLE
    var onApply: (SettingsProfile) -> Void
    @State private var confirmProfile: SettingsProfile?

    var body: some View {
        List {
            if store.profiles.isEmpty && store.autoBackups.isEmpty {
                Text("Noch keine Profile. Oben mit „Aktuelle Einstellungen sichern“ anlegen.")
                    .foregroundStyle(.secondary)
            }
            if !store.profiles.isEmpty {
                Section("Gespeicherte Profile") {
                    ForEach(store.profiles) { p in row(p) }
                        .onDelete { $0.map { store.profiles[$0] }.forEach(store.delete) }
                }
            }
            if !store.autoBackups.isEmpty {
                Section("Automatische Backups (letzte 5)") {
                    ForEach(store.autoBackups) { p in row(p) }
                        .onDelete { $0.map { store.autoBackups[$0] }.forEach(store.delete) }
                }
            }
        }
        .navigationTitle("Profile")
        .toolbar { EditButton() }
        .alert("Profil aufspielen?", isPresented: Binding(get: { confirmProfile != nil },
                                                          set: { if !$0 { confirmProfile = nil } })) {
            Button("Abbrechen", role: .cancel) { confirmProfile = nil }
            Button("Aufspielen", role: .destructive) {
                if let p = confirmProfile { onApply(p) }; confirmProfile = nil
            }
        } message: {
            Text("Profil „\(confirmProfile?.name ?? "")“ überschreibt ALLE Einstellungen am Gerät (inkl. Gastabelle). Vor dem Tauchgang prüfen.")
        }
    }

    private func row(_ p: SettingsProfile) -> some View {
        Button { confirmProfile = p } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).foregroundStyle(.primary)
                    Text("\(p.byteCount) B · \(p.saved.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if ble.connected {
                    Label("Aufspielen", systemImage: "square.and.arrow.up.on.square")
                        .labelStyle(.iconOnly).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ble.connected)
    }
}

/// Editor für einen Gas-Slot (O₂/He/aktiv). Schreibt 3 Bytes atomar.
struct GasEditSheet: View {
    let slot: SymbiosSettings.GasSlot
    let onWrite: (SymbiosSettings.GasSlot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var o2 = 21
    @State private var he = 0
    @State private var active = false
    @State private var confirm = false

    private var n2: Int { max(0, 100 - o2 - he) }
    private var mod: Int { o2 <= 0 ? 0 : max(0, Int((1.4 / (Double(o2)/100.0) - 1.0) * 10.0)) }
    private func clampHe() { if o2 + he > 100 { he = max(0, 100 - o2) } }
    private func clampO2() { if o2 + he > 100 { o2 = max(5, 100 - he) } }

    /// Schnellwahl-Chips wie in der offiziellen App.
    private func presetRow(_ vals: [Int], current: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(vals, id: \.self) { v in
                let sel = current == v
                Button { action(v) } label: {
                    Text("\(v)")
                        .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(sel ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(sel ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(slot.name) {
                    Toggle("Aktiv", isOn: $active)
                    Stepper("O₂: \(o2) %", value: $o2, in: 5...100).onChange(of: o2) { _, _ in clampHe() }
                    presetRow(SymbiosSettings.o2Presets, current: o2) { o2 = $0; clampHe() }
                    Stepper("He: \(he) %", value: $he, in: 0...95).onChange(of: he) { _, _ in clampO2() }
                    presetRow(SymbiosSettings.hePresets, current: he) { he = $0; clampO2() }
                    LabeledContent("Gemisch", value: SymbiosSettings.gasLabel(o2: o2, he: he))
                    LabeledContent("N₂", value: "\(n2) %")
                    LabeledContent("MOD (ppO₂ 1.4)", value: "\(mod) m")
                }
                Section {
                    Label("Schreiben ist reverse-engineert und wenig getestet. Vor dem Tauchgang am Gerät prüfen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Gas ändern")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Schreiben") { confirm = true } }
            }
            .alert("Auf Gerät schreiben?", isPresented: $confirm) {
                Button("Abbrechen", role: .cancel) {}
                Button("Schreiben", role: .destructive) {
                    onWrite(SymbiosSettings.GasSlot(id: slot.id, o2: o2, he: he, active: active))
                }
            } message: {
                Text("\(slot.name) → \(o2)% O₂ / \(he)% He\(active ? " · aktiv" : "")")
            }
            .onAppear { o2 = max(5, slot.o2); he = slot.he; active = slot.active }
        }
    }
}
