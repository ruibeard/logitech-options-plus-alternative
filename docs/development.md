# Development

## Footprint

The current signed build has a **78,144-byte helper executable** (about 78 KB) and a **199,616-byte Settings executable** (about 200 KB) on disk. On 2026-10-15, the installed helper measured **4.31 MiB physical footprint** and **11.05 MiB RSS** with an MX Master 3 for Mac connected over Bluetooth, after about 38 minutes of uptime (five samples, stable). With the same build, Settings measured **29.08 MiB physical footprint** (**78.86 MiB RSS**) while open and releases that memory when closed. An earlier offline helper run (no HID access) measured **2.47 MiB footprint** and **7.94 MiB RSS**. Measurements vary by machine and build.

Physical footprint is the "Memory" value in Activity Monitor. Physical footprint and RSS measure different things, and executable size is not RAM usage.

The helper uses callbacks instead of an input-polling loop. It has no repeating status timer while Settings is closed; its smoothing timer runs only during an active scroll animation.

```sh
python3 scripts/measure.py
```

The script reports footprint, RSS, and executable sizes separately. When sampling an offline helper, it uses a temporary home directory to preserve your settings and status. Offline sampling does not open HID and can run alongside Options+.

## Tests and diagnostics

```sh
python3 scripts/test.py
```

C tests run with AddressSanitizer and UndefinedBehaviorSanitizer. They cover the observed BLE report layout, HID global PUSH / POP, truncated descriptors, report-ID normalization, held buttons, DPI ranges, and malformed settings.

Importer tests exercise isolated Options+ database fixtures and verify read-only access, supported mappings, and preservation of unsupported settings.

The embedded helper accepts these diagnostic options:

| Option | Purpose |
| --- | --- |
| `--probe` | Query Bluetooth HID++ capabilities without changing settings; exits after a query or 15 seconds. |
| `--check-permissions` | Check helper permissions without requesting access or opening HID. |
| `--permissions` | Request helper permissions without changing the running helper’s status. |
| `--offline --duration 10` | Run without HID access for lifecycle and memory checks. |
| `--baseline --duration 5` | Measure the framework baseline. |
| `--duration 30` | Run normally for 30 seconds, then cleanly restore native reporting. |
| `--verbose` | Log button presses. |

Configuration and logs live in `~/Library/Application Support/MX Mouse/`: `settings.plist`, `status.plist`, `permissions.plist`, and `helper.log`. Status is a snapshot, not a heartbeat or proof that the helper is alive.

The helper uses non-persistent HID++ diversion. Graceful shutdown releases diverted controls and restores native wheel reporting. Force-killing can prevent cleanup; power-cycle the mouse if a control stops working. The helper does not change firmware or request persistent diversion.

## Architecture and adding devices

The goal is one small shared helper, with model-specific definitions rather than a separate background process for every supported model. That foundation exists, but the current implementation still assumes one direct-Bluetooth mouse with five configurable controls.

| Location | Responsibility |
| --- | --- |
| `src/device.[ch]` | Device registry: vendor/product IDs, model name, and HID++ button control IDs. |
| `src/helper.c` | HID discovery, HID++ feature negotiation, control diversion, reconnect, and cleanup. |
| `src/core.[ch]` | Report parsing, button state, configuration types, and validation. |
| `src/storage.[ch]` | Configuration persistence and helper status/permission snapshots. |
| `src/settings.m` | Native settings UI, shortcut recording, permissions, and login item. |
| `src/mouse_view.[hm]` | Mouse artwork and control callouts. |
| `src/import_options.[hm]` | Read-only Options+ settings import. |

### Contributing another Logitech model

1. **Identify the exact model and connection.** Collect its vendor/product IDs, HID report descriptor, and available HID++ features from real hardware. Bluetooth and receiver connections need separate verification. Do not guess IDs from similar product names.
2. **Add a device definition** in `src/device.c`, using verified control IDs. Update `tests/device_test.c`, which currently expects a single registered model. For a model that shares the existing five-control layout and direct-Bluetooth HID++ behavior, this is the starting point. Unknown models are deliberately ignored.
3. **Check protocol compatibility** in `src/helper.c`. Report sizes and feature indices are discovered dynamically, but feature layouts and packet routing still have assumptions. Probe only after registering the device; `--probe` does not discover unregistered models. Stop the normal helper and competing controllers before probing.
4. **Handle model capabilities explicitly.** Unsupported wheel, DPI, or extra-button features must be hidden or left native. More than five configurable controls requires changes across configuration/storage, helper state, and UI; preserve existing saved configurations when changing the schema.
5. **Update the UI artwork and callouts** in `src/mouse_view.m` and the build resources if the physical layout differs. Images belong in Settings, not the resident helper.
6. **Add regression tests**, run `python3 scripts/test.py`, and build with `python3 scripts/build.py`. Include malformed/truncated reports and unsupported-feature cases where relevant.
7. **Validate on the actual mouse.** Check button press/release, shortcuts, both wheels, native clicks/pointer movement, unplug/reconnect, sleep/wake, and native behavior after a clean helper shutdown. Report the model, transport, macOS version, and what was actually tested in your contribution.

For example, a future MX Master 3S addition should reuse the shared implementation wherever its verified protocol matches. It is not currently supported or hardware-tested by this project.

### Work needed for the wider MX family

- **MX Master / 2S / 3 / 3S / 4 variants:** verified model definitions and capability checks, followed by hardware validation for each variant.
- **Bolt and Unifying receivers:** transport discovery and per-device routing. Packets currently use the direct-device address `0xff`; adding a receiver ID alone will not work. The registry’s `bluetooth_direct` field is currently descriptive and does not implement another transport.
- **MX Master 4 extra controls and haptics:** additional control definitions and verified protocol handling, plus a UI/configuration that can represent them.
- **Multiple simultaneous mice:** per-device connection state and configuration; the current helper has one active device and global settings.
- **Other vendors:** a separate protocol backend for vendor-specific settings; Logitech HID++ handling cannot be assumed to apply.

Keep shared parsing and lifecycle logic reusable, put model differences in device definitions/capabilities, and keep new UI assets out of the helper. Contributions should include evidence of compatibility, rather than broad support claims based only on device detection.

