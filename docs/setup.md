# Setup and signing

## Build and install

Requires macOS 13+, Xcode Command Line Tools, and Python 3. Builds target the host architecture.

```sh
python3 scripts/build.py
open 'build/MX Mouse Settings.app'
```

For a first installation:

```sh
python3 scripts/build.py --install
open '/Applications/MX Mouse Settings.app'
```

The installer refuses to replace a running Settings app or helper. Install in Applications before enabling login startup or granting permissions. For a rebuild, quit Settings first, then gracefully stop the helper before installing:

```sh
pkill -TERM -x mxmouse-helper
python3 scripts/build.py --install
```

If the helper restarts through its login item, disable **Start at login** before quitting Settings. Do not force-kill the helper; it restores native mouse reporting during graceful shutdown.

1. Quit Logi Options+ and other mouse controllers. The helper refuses to configure the mouse while OpenLogi Agent or Logi Options+ Agent is running.
2. Click **Set Up…** if permissions are missing. Grant **Input Monitoring** and **Accessibility** to **MX Mouse Helper**, using the sheet’s links to the correct System Settings pages. The helper icon can be dragged into a permission list.
3. Mouse controls start automatically when permission checks pass. Enable **Start at login** if desired.

If the helper is already enabled in System Settings but access is still denied after upgrading an old ad-hoc build, remove its old entry with **−**, add the installed helper again with **+**, and enable it. When access is needed, drag the **MX Mouse Helper** icon into the macOS permission list. Once access is ready, setup controls disappear and only permission labels and checkmarks remain. Return to Settings to refresh the status. Accessibility trust and permission to post input events are checked separately; a switch being on does not always mean the current build has access.

Permissions belong to **MX Mouse Helper**, not the Settings app. The helper is embedded at `MX Mouse Settings.app/Contents/Library/LoginItems/MX Mouse Helper.app`.

Closing Settings exits its process and leaves the helper running. Reopen Settings to make changes. Settings save automatically; sliders apply on release.

From v0.2.0, one helper is used for all connected compatible mice. When more than one is detected, choose a mouse at the top of Settings to edit its own profile. The other mice keep their own active bindings. Devices with no matching artwork use a control list populated from the hardware; unsupported or absent controls are hidden, including the thumb button on newer M705 variants.

Existing top-level settings remain the defaults for a mouse without its own profile. Editing a detected mouse saves to `settings.plist` under `devices[deviceID]`, preserving those defaults and the other profiles. Additional controls are stored by hexadecimal HID++ control ID. Per-unit hardware identity is preferred; devices without a usable identity fall back to their transport and receiver slot, so moving those devices can select a different profile.

Builds automatically choose an existing Apple Development or Developer ID Application signing certificate and remember its fingerprint in `~/Library/Application Support/MX Mouse/signing-identity.txt`. Subsequent builds reuse that certificate, including after source changes. Keep installing at the same Applications path. Switching from an old ad-hoc build requires granting the helper permissions once again; persistence across later builds still needs verification on your Mac.

Set `MX_SIGN_IDENTITY` to override the certificate for a build. If the remembered certificate becomes unavailable, the build stops instead of silently switching identities. Restore the certificate or explicitly select a replacement; changing certificates can require new permission grants. The build never creates certificates or changes Keychain trust. Without a suitable certificate, it stops with setup instructions. `MX_SIGN_IDENTITY=- python3 scripts/build.py` explicitly permits an ad-hoc development build, whose permissions can be lost after rebuilding.

