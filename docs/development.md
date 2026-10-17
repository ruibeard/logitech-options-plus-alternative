# Development

## Footprint

The earlier signed build measured on 2026-10-15 had a **78,144-byte helper executable** (about 78 KB) and a **199,616-byte Settings executable** (about 200 KB) on disk. On 2026-10-15, the installed helper measured **4.31 MiB physical footprint** and **11.05 MiB RSS** with an MX Master 3 for Mac connected over Bluetooth, after about 38 minutes of uptime (five samples, stable). With the same build, Settings measured **29.08 MiB physical footprint** (**78.86 MiB RSS**) while open and releases that memory when closed. An earlier offline helper run (no HID access) measured **2.47 MiB footprint** and **7.94 MiB RSS**. These are historical measurements of the earlier implementation, not measurements of the new multi-device build. Current multi-device measurements are reported below; measurements vary by machine and build.

Physical footprint is the "Memory" value in Activity Monitor. Physical footprint and RSS measure different things, and executable size is not RAM usage.

On 2026-10-16, the development helper executable measured **96,096 bytes**, compared with **95,136 bytes** for the installed reconnect-fix baseline (**960 bytes larger**). Five alternating offline runs of each final build had median physical footprints of **2.47 MiB** and **2.44 MiB** respectively, a **32 KiB** difference with overlapping sample ranges. During the no-device test on that date, the installed development helper measured **2.50 MiB** physical footprint across five samples with Settings closed. This is not a connected-device result. A live test with connected mice has been approved with a **5 MiB idle physical-footprint ceiling**. On 2026-10-17, with one M705 active through a Unifying receiver and an additional paired MX Master 3 offline, the installed helper held at **4.39 MiB physical footprint** across five samples with Settings closed. The receiver exposed the M705’s actual eight-control inventory and a 55% battery reading. After correcting offline paired-device status and the default Settings selection, the rebuilt helper measured **96,144 bytes** on disk; its first connected-device samples after restart were about **3.1 MiB**. Fresh-process and longer-running samples are reported separately; both were below the approved ceiling. Simultaneous operation with two awake mice, physical button/scroll interaction, reconnect and sleep/wake checks remain pending.

The persistent application state is **2,264 bytes per mouse** and **256 bytes per transport** on arm64, allocated only for discovered devices. macOS framework/HID allocations are additional and must be measured; these structure sizes are not a prediction of total memory. The previous 2 KiB persistent report-size array has been replaced with two report-width bytes per transport.

The helper uses callbacks instead of an input-polling loop. It has no repeating status timer while Settings is closed; its smoothing timer runs only during an active scroll animation.

If a discovered mouse does not answer its initial HID++ handshake, the helper retries after 1, 2, 4, 8, 16, then 30 seconds between attempts. Retries stop on connection, removal, or shutdown. This handles Bluetooth discovery arriving before the link can accept commands; changing a setting or waking the Mac also permits an immediate retry.

```sh
python3 scripts/measure.py
# Verify the approved ceiling with two connected mice; fails if either is absent.
python3 scripts/measure.py --samples 5 --require-connected 2 --max-footprint-mib 5
```

The script reports footprint, RSS, and executable sizes separately. When sampling an offline helper, it uses a temporary home directory to preserve your settings and status. Offline sampling does not open HID and can run alongside Options+.

## Tests and diagnostics

```sh
python3 scripts/test.py
```

C tests run with AddressSanitizer and UndefinedBehaviorSanitizer. They cover the observed BLE report layout, HID global PUSH / POP, truncated descriptors, report-ID normalization, held buttons, DPI ranges, and malformed settings.

Importer tests exercise isolated Options+ database fixtures and verify read-only access, supported mappings, and preservation of unsupported settings.

Multi-device tests cover receiver-slot and transport response isolation, same-model replacement without cleanup writes to another unit, actual control inventories, missing thumb buttons, optional-feature failures, and independent reconnect timers. Native Settings integration tests exercise separate profiles, device switching/removal, distinct gesture and Haptic panel bindings, hidden unsupported controls, and profile-scoped Options+ imports.

The embedded helper accepts these diagnostic options:

| Option | Purpose |
| --- | --- |
| `--probe` | Query connected HID++ capabilities without changing settings; exits after 15 seconds. |
| `--check-permissions` | Check helper permissions without requesting access or opening HID. |
| `--permissions` | Request helper permissions without changing the running helper’s status. |
| `--offline --duration 10` | Run without HID access for lifecycle and memory checks. |
| `--baseline --duration 5` | Measure the framework baseline. |
| `--duration 30` | Run normally for 30 seconds, then cleanly restore native reporting. |
| `--verbose` | Log button presses. |

Configuration and logs live in `~/Library/Application Support/MX Mouse/`: `settings.plist`, `status.plist`, `permissions.plist`, and `helper.log`. Per-device profiles are stored separately from the legacy defaults; Settings selects a mouse by its identity, while the helper maintains the configurations of all connected mice. Status is a snapshot, not a heartbeat or proof that the helper is alive.

The helper uses non-persistent HID++ diversion. Graceful shutdown releases diverted controls and restores native wheel reporting. Force-killing can prevent cleanup; power-cycle the mouse if a control stops working. The helper does not change firmware or request persistent diversion.

## Architecture and adding devices

One native C helper process manages all discovered mice. A transport record owns each compatible HID interface, its report descriptor and one outstanding request; each direct mouse or paired receiver slot owns its connection, configuration, controls, scrolling and reconnect state. Requests share the main run loop. No process or worker thread is started for another mouse.

Direct devices use HID++ address `0xff`. Receiver management uses `0xff`, while paired devices use slots `1` through `6`. The receiver registry separates Bolt's pairing register format from Unifying-compatible receivers, including registered Nano and Lightspeed transports. Recognizing a receiver does not imply that every device paired to it exposes the supported mouse features.

Logitech interfaces with compatible HID++ output reports can be interrogated without adding their model to an allowlist. Positive mouse identity and a successful HID++ 2.0-or-newer handshake precede configuration. Feature indices and `0x1b04` control IDs are read from the device. The name registry supplies familiar names; its presence does not grant capabilities or invent controls. Unknown or unsupported features stay native.

| Location | Responsibility |
| --- | --- |
| `src/device.[ch]` | Optional model names, receiver protocol identities, pairing decoders, and control classification. |
| `src/helper.c` | Shared HID transports, per-mouse lifecycle, feature negotiation, control diversion, reconnect, and cleanup. |
| `src/core.[ch]` | Report parsing, configuration types, legacy logical bindings and sparse CID overrides. |
| `src/storage.[ch]` | Per-device configuration persistence and helper status/permission snapshots. |
| `src/settings.m` | Device selection, capability-driven controls, shortcut recording, permissions, and login item. |
| `src/mouse_view.[hm]` | Settings artwork and optional control callouts. |
| `src/import_options.[hm]` | Read-only Options+ settings import. |

### Capability and verification tiers

Protocol compatibility, a passing fixture test and a physical hardware test are different evidence. The current changes are built and tested against pure parser/configuration tests. The new helper has discovered and configured one M705 on hardware; multiple simultaneously awake mice and the other new model/transport paths still need physical testing.

| Family or path | Implemented path and evidence | Remaining limits |
| --- | --- | --- |
| MX Master 3 for Mac, direct Bluetooth | Existing project hardware evidence for the previous helper; shared feature-based path retained. | New multi-device lifecycle still needs a connected-device regression test. |
| Newer M705 (`406d`, M-R0073) | Generic HID++ 2.0+ discovery; Solaar identifies protocol 4.5. Actual control inventory determines the UI. | No thumb button is assumed. The new helper needs testing against this specific unit. |
| Older M705 (`101b`, thumb-button variant) | On 2026-10-17, the new helper discovered eight controls, applied the saved configuration, and read 55% battery through a Unifying receiver; idle footprint was 4.39 MiB. | Physical button/scroll interaction and simultaneous-device/reconnect tests remain pending. Solaar labels its `101b` descriptor HID++ 1.0; the actual successful 2.0+ handshake governs this unit. Devices that answer only 1.0 need a separate settings backend. |
| MX Master 3S and MX Master 4 | Their upstream OpenLogi captures provide reference control tables and feature layouts; the shared implementation can probe them over compatible direct or registered receiver transports. | This project has not physically verified those model/transport combinations. |
| MX Master 4 Haptic panel | CID `01a0` is represented as an independent configurable control, alongside gesture CID `00c3`. A basic shortcut can be bound if the device reports temporary diversion support. | Haptic feedback, force/touch tuning and raw-XY gestures are not implemented. |
| Earlier MX Master / 2S, Anywhere, Vertical, Lift and trackballs | Feature discovery can expose compatible buttons, DPI, wheels and battery information without a model-specific button list. | Each feature and transport needs hardware verification. Older Gestures2 thumbwheel handling is not implemented. |
| Registered Nano and Lightspeed receivers | Shared Unifying-compatible routing and paired-device discovery. | Receiver admission is not full gaming-mouse support. Alternative control, DPI and battery protocols need additional implementations. |

The supported feature paths are reprogrammable controls V4 (`1b04`), high-resolution wheel (`2121`), thumbwheel (`2150`), adjustable DPI (`2201`), SmartShift (`2110` / `2111`) and battery (`1000` / `1004`). The UI must reflect successful discovery, including a mouse with only a subset of those features. The five existing logical binding slots remain compatible with saved settings; additional controls use their actual CIDs and default to native behavior. A missing thumb control on an M705 is absent from the available controls even if an older profile contains a thumb shortcut.

### Contributing another Logitech model

1. **Collect evidence for the exact model and connection.** Record its vendor/product IDs, HID report descriptor, marketing identity, protocol version, feature table and actual control inventory. Bluetooth and receiver connections require separate verification; do not guess IDs from similar names.
2. **Try the generic discovery path first.** A new model name is optional when its reported features match the existing implementations. Add a registry entry only for a grounded identity or receiver-protocol distinction, with corresponding parser tests.
3. **Add missing protocol features explicitly.** Keep feature-specific wire layouts separate from model names. Older `6501` Gestures2 thumbwheels and HID++ 1.0 devices need additional handling; assigning a product ID does not enable them.
4. **Keep controls and settings per device.** Preserve existing profiles and use sparse CID overrides for additional controls. Never manufacture a control from artwork or a marketing family's expected layout.
5. **Keep Settings resources out of the helper.** Generic mice can use a textual control list. Artwork and physical callouts are optional UI additions.
6. **Run appropriate tests and build.** Use `python3 scripts/test.py` and `python3 scripts/build.py`; cover malformed replies, unsupported features, identity replacement and existing configuration migration where relevant.
7. **Validate the physical device.** Check press/release, shortcuts, native pointer/click behavior, supported wheels and DPI, simultaneous mice, receiver slot replacement, unplug/reconnect, sleep/wake and native behavior after graceful shutdown. Include model, transport, macOS version and measured resident memory with the report.

Keep model claims proportional to the evidence. Wider HID++ feature coverage can be added without a resident framework, background web UI or another helper process; connected-device memory still needs measurement before adopting a build with a higher footprint.


## Installed Options+ resource references

Options+ stores its device catalog in `/Library/Application Support/Logi/LogiOptionsPlus/devices.json` and downloaded artwork in `depots/<build>/<device-depot>/`. The locally reviewed build `881239` (Options+ `2.9.994631`) contains a 191-entry device catalog; downloaded device artwork is limited to the devices it has fetched.

Useful files are `manifest.json` (model-to-image mapping), `core_metadata.json` (image dimensions and button marker percentages), and the referenced WebP images. The M705 layout uses `m705_lcc/side.webp` and its metadata. The catalog distinguishes old M705 `4101b` controls 82/83/86/89/91/93 from newer `4406d` controls 82/83/86/91/93. The Master 4 entries list controls 82/83/86/195/196/416, but their artwork depots were not downloaded at inspection time.

Use these as artwork/layout references, with credits recorded separately. The helper continues to discover actual device capabilities over HID++; catalog entries alone do not establish device support. Only Settings loads the selected bundled artwork; the resident helper does not load the catalog, image files, or Options+ components.


Settings remembers discovered mouse names, controls, and capabilities in `~/Library/Application Support/MX Mouse/known-devices.plist`. This is separate from shortcut profiles in `settings.plist`. Offline devices remain selectable and editable using their last known layout, including after Settings or the helper restarts; fresh connected discovery replaces the cached layout. Connection and battery readings are never restored as live values. Existing MX Master 3 model IDs have a baseline button layout for upgrading installations that predate this cache. Unknown models require an initial successful connection with Settings open. The helper does not load this Settings-only cache.
