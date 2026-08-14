# Symbios Settings — iOS-App

Eigene iOS-App (SwiftUI + CoreBluetooth) zum **Lesen und Ändern der Einstellungen** des Halcyon Symbios,
auf Basis des reverse-engineerten BLE-Protokolls (siehe `../re/SYMBIOS_PROTOCOL.md`).

## Funktionen
- Verbinden (BLE), Geräteinfo lesen (STATUS: Serial, FW, Batterie, Druck).
- Alle ~33 verankerten Einstellungen lesen + anzeigen (gruppiert), inkl. **Gastabelle**.
- Einzelne Einstellung ändern per **sicherem Read-Modify-Write**: frisch lesen → nur das Ziel-Byte im
  Ist-Puffer ändern (Länge bleibt) → `SET_SETTINGS` → **per erneutem GET verifizieren**.
- **Demo-Modus** ("Demo-Daten laden") zeigt die UI ohne Gerät (echter Beispiel-Blob).

## Bauen & aufs iPhone bringen (nötig für echtes BLE)
Der iOS-**Simulator hat kein Bluetooth** → echtes Lesen/Schreiben geht nur auf einem physischen iPhone:
1. `SymbiosSettings.xcodeproj` in **Xcode** öffnen.
2. Target „SymbiosSettings" → **Signing & Capabilities** → dein Apple-ID-Team wählen
   (Bundle-ID ggf. anpassen, z. B. `de.deinname.SymbiosSettings`).
3. iPhone per Kabel anschließen, als Ziel wählen, **Run** (⌘R).
   (Erststart: am iPhone unter Einstellungen → Allgemein → VPN & Geräteverwaltung dem Entwicklerzertifikat vertrauen.)
4. In der App **„Symbios verbinden"** → iOS fragt beim ersten Mal den **BLE-Passkey deines Geräts** ab → Einstellungen lesen/ändern.

## ⚠️ Sicherheit (bitte lesen)
Das **Schreiben** ist reverse-engineert und bislang wenig getestet. Die App sichert ab (Read-Modify-Write +
Verify + Bestätigungsdialog), aber: **jeden geänderten Wert vor einem Tauchgang am Gerät selbst prüfen.**
Empfehlung: erst unkritische Werte testen. `displayOrientation` ist als *nicht editierbar* markiert (tentativ).

## Struktur
- `SymbiosProtocol.swift` — Framing, CRC-8, Kommandos.
- `SettingsModel.swift` — 84-Byte-Blob → Felder (Offsets), Gastabelle, Read-Modify-Write, Demo-Blob.
- `SymbiosBLE.swift` — CoreBluetooth: Scan/Connect/Notify, async Kommando-Versand mit Reassembly, Write+Verify.
- `ContentView.swift` — UI (Liste, Bearbeiten-Sheet mit Warnung).

Im Simulator getestet (UI + Parser gegen echten Blob). BLE-Test am iPhone steht noch aus.
