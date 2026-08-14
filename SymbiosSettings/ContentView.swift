import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var ble = SymbiosBLE()
    @StateObject private var store = ProfileStore()
    @State private var busy = false
    @State private var editing: SettingField?
    @State private var toast: String?
    @State private var showDebug = false
    @State private var showSaveDialog = false
    @State private var newProfileName = ""
    @State private var editingGas: SymbiosSettings.GasSlot?

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if !ble.connected, ble.settingsBlob != nil {
                    Section {
                        Label("Offline-Entwurf – Änderungen bleiben nur lokal. Als Profil sichern und bei Verbindung aufspielen.",
                              systemImage: "pencil.and.outline")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if ble.settingsBlob != nil {
                    Section("Konfiguration") {
                        ForEach(SymbiosSettings.groups, id: \.self) { g in
                            NavigationLink { groupDetail(g) } label: {
                                Label(g, systemImage: groupIcon(g))
                            }
                        }
                        NavigationLink { gasDetail() } label: {
                            Label("Gastabelle", systemImage: "cylinder.split.1x2")
                        }
                        NavigationLink { CustomFieldsView(ble: ble, onToggle: writeCustomField) } label: {
                            Label("Custom-Felder (Screen)", systemImage: "square.grid.2x2")
                        }
                    }
                } else if ble.connected {
                    Section { HStack { ProgressView(); Text("Einstellungen werden gelesen…").foregroundStyle(.secondary) } }
                } else {
                    Section { Text("Verbinde dich oder starte einen Offline-Entwurf.").foregroundStyle(.secondary) }
                }
                profilesSection
                Section {
                    Link(destination: URL(string: "https://buymeacoffee.com/etlami")!) {
                        Label("Buy me a Coffee ☕", systemImage: "cup.and.saucer.fill")
                    }
                } header: { Text("Unterstützen") }
                if showDebug, let blob = ble.settingsBlob {
                    Section {
                        Text(blob.map { String(format: "%02x", $0) }.joined())
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = blob.map { String(format: "%02x", $0) }.joined()
                            showToast("Rohdaten kopiert (\(blob.count) B)")
                        } label: { Label("Rohdaten kopieren (Hex)", systemImage: "doc.on.doc") }
                    } header: { Text("Settings-Blob (für Offset-Diff)") }
                }
                if showDebug && !ble.log.isEmpty {
                    Section {
                        ForEach(Array(ble.log.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        HStack {
                            Text("Protokoll (Debug)")
                            Spacer()
                            Button {
                                UIPasteboard.general.string = ble.log.joined(separator: "\n")
                                showToast("Protokoll kopiert (\(ble.log.count) Zeilen)")
                            } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                                .font(.caption).textCase(nil)
                            Button(role: .destructive) { ble.log.removeAll() } label: {
                                Image(systemName: "trash")
                            }.font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Symbios Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDebug.toggle() } label: {
                        Image(systemName: showDebug ? "ladybug.fill" : "ladybug")
                    }
                }
            }
            .overlay(alignment: .bottom) { toastView }
            .onChange(of: ble.ready) { _, r in
                guard r else { return }
                Task {                                   // Auto-Lesen sobald verbunden + Notify aktiv
                    busy = true
                    await ble.refreshAll()
                    if let b = ble.settingsBlob { store.autoBackup(b) }
                    busy = false
                }
            }
            .sheet(item: $editing) { f in
                EditSheet(field: f, blob: ble.settingsBlob ?? [], onWrite: writeField)
            }
            .sheet(item: $editingGas) { g in
                GasEditSheet(slot: g, onWrite: writeGas)
            }
            .alert("Profil speichern", isPresented: $showSaveDialog) {
                TextField("Name (z. B. Tec 100)", text: $newProfileName)
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") {
                    if let blob = ble.settingsBlob { store.save(name: newProfileName, blob: blob); showToast("Profil gesichert.") }
                }
            } message: { Text("Sichert die aktuell gelesenen Einstellungen als Profil.") }
        }
    }

    // MARK: Profile
    @ViewBuilder private var profilesSection: some View {
        Section("Profile") {
            if ble.settingsBlob != nil {
                Button { newProfileName = ""; showSaveDialog = true } label: {
                    Label("Aktuelle Einstellungen sichern", systemImage: "square.and.arrow.down")
                }.disabled(busy)
            }
            NavigationLink {
                ProfilesView(store: store, ble: ble, onApply: applyProfile, onLoadDraft: loadDraft)
            } label: {
                Label("Profile & Backups", systemImage: "folder")
                    .badge(store.profiles.count + store.autoBackups.count)
            }
        }
    }

    private func writeCustomField(_ cf: SymbiosSettings.CustomField, _ on: Bool) {
        guard let blob = ble.settingsBlob else { return }
        let newByte = SymbiosSettings.cfPatchedByte(blob, cf, on)
        if ble.connected {
            Task {
                busy = true
                let (ok, msg) = await ble.writeSetting(offset: cf.offset, value: newByte)
                busy = false
                showToast((ok ? "✅ " : "⚠️ ") + "\(cf.name) \(on ? "an" : "aus")" + (ok ? "" : " – \(msg)"))
            }
        } else if var b = ble.settingsBlob, cf.offset < b.count {
            b[cf.offset] = newByte; ble.settingsBlob = b       // Offline-Entwurf
            showToast("📝 Entwurf: \(cf.name) \(on ? "an" : "aus")")
        }
    }

    private func loadDraft(_ p: SettingsProfile) {
        ble.settingsBlob = p.blob          // Offline-Entwurf zum Weiterbearbeiten
        showToast("📝 „\(p.name)“ als Entwurf geladen.")
    }

    private func applyProfile(_ p: SettingsProfile) {
        guard ble.connected else { showToast("Nur mit verbundenem Gerät aufspielbar."); return }
        Task {
            busy = true
            let (ok, msg) = await ble.writeFullBlob(p.blob)
            busy = false
            showToast((ok ? "✅ " : "⚠️ ") + msg)
        }
    }

    // MARK: Sections
    private var connectionSection: some View {
        Section("Verbindung") {
            HStack(spacing: 8) {
                Circle().fill(ble.connected ? .green : .secondary).frame(width: 9, height: 9)
                Text(ble.statusText).font(.subheadline)
                Spacer()
                if ble.scanning || busy { ProgressView() }
            }
            if ble.connected, let i = ble.deviceInfo {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(i.modelName) · SN \(i.serial)").font(.subheadline)
                    Text("FW \(i.fw)  ·  \(i.batteryPct) % Akku  ·  \(String(format: "%.2f", Double(i.pressure_mbar)/1000)) bar")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !ble.connected {
                Button { ble.startScan() } label: { Label("Symbios verbinden", systemImage: "antenna.radiowaves.left.and.right") }
                if ble.settingsBlob == nil {
                    Button { ble.settingsBlob = SymbiosSettings.demoBlob } label: {
                        Label("Offline-Entwurf starten", systemImage: "square.and.pencil")
                    }.foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) { ble.settingsBlob = nil } label: {
                        Label("Entwurf verwerfen", systemImage: "trash")
                    }
                }
            } else {
                HStack {
                    Button { Task { busy = true; await ble.refreshAll(); if let b = ble.settingsBlob { store.autoBackup(b) }; busy = false } } label: {
                        Label("Neu lesen", systemImage: "arrow.clockwise")
                    }.disabled(busy)
                    Spacer()
                    Button(role: .destructive) { ble.disconnect() } label: { Label("Trennen", systemImage: "xmark.circle") }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private func fieldRow(_ f: SettingField, blob: [UInt8]) -> some View {
        if f.editable, f.range != nil, f.kind.isNumeric {
            // Inline-Slider direkt in der Zeile (GF, PO₂, Helligkeit, Timeouts …)
            SliderFieldRow(field: f, blob: blob, busy: busy, onCommit: setRaw)
        } else {
            switch f.kind {
            case .boolean:
            // Direkt in der Tabelle ein/aus schalten
            Toggle(isOn: Binding(
                get: { SymbiosSettings.rawValue(blob, f) != 0 },
                set: { setRaw(f, $0 ? 1 : 0) }
            )) { Text(f.label) }
            .disabled(!f.editable || busy)
        case .enumMap(let m) where f.editable:
            if m.count <= 2 {
                // 2 Optionen → Segmented Control (beide sichtbar, ein Tipp)
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.label)
                    Picker("", selection: Binding(
                        get: { SymbiosSettings.rawValue(blob, f) },
                        set: { setRaw(f, UInt8(clamping: $0)) }
                    )) {
                        ForEach(f.enumOrder ?? m.keys.sorted(), id: \.self) { k in Text(m[k] ?? "\(k)").tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(busy)
                }
            } else {
                // Mehr Optionen → Inline-Dropdown
                Picker(selection: Binding(
                    get: { SymbiosSettings.rawValue(blob, f) },
                    set: { setRaw(f, UInt8(clamping: $0)) }
                )) {
                    ForEach(m.keys.sorted(), id: \.self) { k in Text(m[k] ?? "\(k)").tag(k) }
                } label: { Text(f.label) }
                .pickerStyle(.menu)
                .disabled(busy)
            }
        default:
            Button { if f.editable { editing = f } } label: {
                HStack {
                    Text(f.label).foregroundStyle(.primary)
                    Spacer()
                    Text(SymbiosSettings.display(blob, f)).foregroundStyle(.secondary)
                    if f.editable { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)   // sonst färbt SwiftUI die ganze Zeile blau
            .disabled(!f.editable)
            }
        }
    }

    /// Roh-Byte direkt schreiben (verbunden) bzw. lokal spiegeln (Demo). Für Toggles & Inline-Dropdowns.
    private func setRaw(_ f: SettingField, _ v: UInt8) {
        if ble.connected {
            Task {
                busy = true
                let (ok, msg) = await ble.writeSetting(offset: f.offset, value: v)
                busy = false
                showToast((ok ? "✅ " : "⚠️ ") + f.label + ": " + msg)
            }
        } else if var b = ble.settingsBlob, f.offset < b.count {
            b[f.offset] = v; ble.settingsBlob = b   // Demo-Vorschau ohne Gerät
        }
    }

    private func groupIcon(_ g: String) -> String {
        switch g {
        case "Tauchprofil": return "water.waves"
        case "CCR + CCR FSP": return "lungs"
        case "Timeouts & Alarme": return "alarm"
        case "Anzeigen": return "display"
        case "Computer-Einstellungen": return "gearshape"
        default: return "slider.horizontal.3"
        }
    }

    @ViewBuilder private func groupDetail(_ g: String) -> some View {
        List {
            ForEach(SymbiosSettings.fields.filter { $0.group == g }) { f in
                fieldRow(f, blob: ble.settingsBlob ?? [])
            }
        }
        .navigationTitle(g)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func gasDetail() -> some View {
        List { gasSection(ble.settingsBlob ?? []) }
            .navigationTitle("Gastabelle")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func gasSection(_ blob: [UInt8]) -> some View {
        Section {
            ForEach(SymbiosSettings.gasSlots(blob)) { g in
                Button { editingGas = g } label: {
                    HStack {
                        Text(g.name).foregroundStyle(g.active ? .primary : .secondary)
                        if g.active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                        Spacer()
                        Text(SymbiosSettings.gasLabel(o2: g.o2, he: g.he))
                            .bold().foregroundStyle(g.active ? .primary : .secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: { Text("Gastabelle") }
        footer: { Text("Tippen zum Bearbeiten (O₂/He/aktiv). Schreiben ist RE – vor dem Tauchgang am Gerät prüfen.") }
    }

    private func writeGas(_ slot: SymbiosSettings.GasSlot) {
        editingGas = nil
        let changes: [(offset: Int, value: UInt8)] = [
            (slot.o2Offset, UInt8(clamping: slot.o2)),
            (slot.heOffset, UInt8(clamping: slot.he)),
            (slot.activeOffset, slot.active ? 1 : 0),
        ]
        if ble.connected {
            Task {
                busy = true
                let (ok, msg) = await ble.writePatched(changes)
                busy = false
                showToast((ok ? "✅ " : "⚠️ ") + slot.name + ": " + msg)
            }
        } else if var b = ble.settingsBlob {
            for c in changes where c.offset < b.count { b[c.offset] = c.value }
            ble.settingsBlob = b                               // Offline-Entwurf: nur lokal
            showToast("📝 Entwurf: \(slot.name) = \(SymbiosSettings.gasLabel(o2: slot.o2, he: slot.he))")
        }
    }

    private var toastView: some View {
        Group {
            if let t = toast {
                Text(t).padding(10).background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8).transition(.opacity)
            }
        }
    }

    // MARK: Write
    private func writeField(_ f: SettingField, _ value: UInt8) {
        editing = nil
        if ble.connected {
            Task {
                busy = true
                let (ok, msg) = await ble.writeSetting(offset: f.offset, value: value)
                busy = false
                showToast((ok ? "✅ " : "⚠️ ") + msg)
            }
        } else if var b = ble.settingsBlob, f.offset < b.count {
            b[f.offset] = value; ble.settingsBlob = b          // Offline-Entwurf: nur lokal
            showToast("📝 Entwurf: \(f.label) = \(SymbiosSettings.display(b, f))")
        }
    }
    private func showToast(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); withAnimation { toast = nil } }
    }
}

/// Bearbeitungs-Sheet für ein Feld – mit Sicherheitswarnung fürs Schreiben.
struct EditSheet: View {
    let field: SettingField
    let blob: [UInt8]
    let onWrite: (SettingField, UInt8) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var raw: Double = 0
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section(field.label) { editor }
                Section {
                    Label("Schreiben ist reverse-engineert und wenig getestet. Vor dem Tauchgang am Gerät prüfen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Ändern")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Schreiben") { confirm = true } }
            }
            .alert("Auf Gerät schreiben?", isPresented: $confirm) {
                Button("Abbrechen", role: .cancel) {}
                Button("Schreiben", role: .destructive) { onWrite(field, UInt8(raw)) }
            } message: { Text("\(field.label) → \(previewText)") }
            .onAppear { raw = Double(field.offset < blob.count ? blob[field.offset] : 0) }
        }
    }

    @ViewBuilder private var editor: some View {
        switch field.kind {
        case .boolean:
            Toggle("An", isOn: Binding(get: { raw != 0 }, set: { raw = $0 ? 1 : 0 }))
        case .enumMap(let m):
            Picker("Wert", selection: Binding(get: { Int(raw) }, set: { raw = Double($0) })) {
                ForEach(m.keys.sorted(), id: \.self) { k in Text(m[k] ?? "\(k)").tag(k) }
            }
        case .scaledBar:
            valueControl(text: String(format: "%.2f bar", raw/100))
        case .uint(let u):
            valueControl(text: u.isEmpty ? "\(Int(raw))" : "\(Int(raw)) \(u)")
        case .sint(let u):
            valueControl(text: u.isEmpty ? "\(Int(raw))" : "\(Int(raw)) \(u)")
        }
    }

    /// Slider wenn Wertebereich bekannt, sonst Stepper.
    @ViewBuilder private func valueControl(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.title3).monospacedDigit()
            if let r = field.range {
                Slider(value: $raw, in: r, step: 1) {
                    Text(field.label)
                } minimumValueLabel: { Text("\(Int(r.lowerBound))").font(.caption2) }
                maximumValueLabel: { Text("\(Int(r.upperBound))").font(.caption2) }
            } else {
                Stepper("", value: $raw, in: 0...255, step: 1).labelsHidden()
            }
        }
    }

    private var previewText: String {
        switch field.kind {
        case .boolean: return raw != 0 ? "An" : "Aus"
        case .enumMap(let m): return m[Int(raw)] ?? "\(Int(raw))"
        case .scaledBar: return String(format: "%.2f bar", raw/100)
        case .uint(let u): return u.isEmpty ? "\(Int(raw))" : "\(Int(raw)) \(u)"
        case .sint(let u): return u.isEmpty ? "\(Int(raw))" : "\(Int(raw)) \(u)"
        }
    }
}
