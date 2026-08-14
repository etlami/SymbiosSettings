# Symbios Settings — iOS app

An independent iOS app (SwiftUI + CoreBluetooth) to **read and change the settings** of the
Halcyon Symbios dive computer, based on the reverse-engineered BLE protocol.

> ⚠️ Reverse-engineered and lightly tested. Writing to the device is at your own risk —
> always verify on the computer itself before diving.

## Features
- Connect over BLE, read device info (serial, firmware, battery, pressure).
- Read and display all anchored settings, grouped (Dive profile · CCR/FSP · Timeouts & alarms ·
  Displays · Computer settings).
- Change settings via a safe **read-modify-write** (fetch fresh → patch one byte → `SET_SETTINGS`
  → verify with a re-read).
- **Gas-table editor** — 8 slots (OC1–5, Dil1–3); O₂/He with quick-select chips and steppers,
  enable toggle, live N₂ and MOD; written atomically per slot.
- **Custom-fields editor** (CF Content screen) — 22 toggle fields mapped to the settings blob.
- **Settings profiles + backup** — save the full settings blob under a name, auto-backup on every
  read, apply a profile in one write.
- **Offline-draft mode** — build a complete configuration (incl. gases and custom fields) without a
  device, save it as a profile, and apply it later when connected.
- **Demo/offline preview** works without hardware (real sample blob).

## Build & run on iPhone (required for real BLE)
The iOS **Simulator has no Bluetooth**, so reading/writing only works on a physical iPhone:
1. Open `SymbiosSettings.xcodeproj` in **Xcode**.
2. Target “SymbiosSettings” → **Signing & Capabilities** → pick your Apple-ID team
   (adjust the bundle ID if needed).
3. Connect the iPhone, select it as the run destination, **Run** (⌘R).
   (First launch: trust the developer certificate under Settings → General → VPN & Device Management.)
4. In the app tap **“Connect Symbios”** → on first pairing iOS asks for the **device BLE passkey** →
   read/change settings.

## Install without Xcode (sideloading)
A development-signed `.ipa` is attached to each [GitHub Release](../../releases). Sideload it with
AltStore / SideStore / Sideloadly (it gets re-signed with your own Apple ID).
AltStore/SideStore source:

```
https://raw.githubusercontent.com/etlami/SymbiosSettings/main/source.json
```

## Support
If this app is useful to you: [Buy me a Coffee ☕](https://buymeacoffee.com/etlami)

## License
Licensed under the **PolyForm Noncommercial License 1.0.0** — you may use, modify and share it for
**noncommercial** purposes only. Commercial use is not permitted. Provided **as-is, without warranty**.
See [`LICENSE.md`](LICENSE.md).

## Disclaimer
Unofficial, community-made app — **not affiliated with, endorsed by, or supported by Halcyon Dive
Systems**. “Halcyon” and “Symbios” are trademarks of their respective owners and are used here only
descriptively. The BLE protocol was reverse-engineered; writing to the device is at your own risk and
must be verified on the computer itself before diving. This is **not** a dive-planning or safety tool.

## Protocol
BLE framing `[cmd][data][crc8]` (CRC-8 poly 0x07). Commands on characteristic
`00000101-8C3B-4F2C-A59E-8C08224F3253`, responses via indication. Settings are an 84-byte blob
(`GET_SETTINGS` / `SET_SETTINGS`). The reverse-engineering notes live outside this app repo.
