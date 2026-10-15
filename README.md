# MX Mouse

A tiny macOS app for your MX Master 3.

|        |   MX Mouse | MX Mouse UI | Logi Options+ |
|--------|-----------:|------------:|--------------:|
| Memory | **4.3 MB** |     29.1 MB |       120+ MB |

Close the window. Only the 4.3 MB stays.

![MX Mouse Settings](docs/images/settings.png)

**Works with:** MX Master 3 for Mac, Bluetooth, Apple Silicon, macOS 13+. Other mice: not yet.

- [x] Custom buttons and shortcuts
- [x] Scroll, DPI, SmartShift
- [x] Import from Options+ (read-only)
- [x] Quit or uninstall Options+ from the app
- [x] Start at login
- [x] No account, no cloud

## Install

1. [Download](https://github.com/ruibeard/logitechdriver/releases), drag to Applications.
2. macOS gets nervous → **Open Anyway**.
3. Quit Logi Options+.
4. **Set Up…** → grant permissions.

## Uninstall

1. Turn off **Start at login**, then quit MX Mouse.
2. Stop the helper: `pkill -TERM -x mxmouse-helper`. The mouse goes back to normal.
3. Delete **MX Mouse Settings** from Applications.
4. Optional: delete `~/Library/Application Support/MX Mouse/` and remove **MX Mouse Helper** from Input Monitoring and Accessibility.

<details>
<summary>Where does 120+ MB come from?</summary>

Activity Monitor on the author's Mac: Logi Options+ 94.4 MB + updater 26.1 MB. `loginwindow` is part of macOS, so it does not count. Options+ can also run an agent process, so the real total can be higher.

![Logi Options+ in Activity Monitor](docs/images/options-plus-memory.png)

</details>

[Build](docs/setup.md) · [Add a mouse](docs/development.md#architecture-and-adding-devices) · [Credits](docs/credits.md) · [MIT License](LICENSE) · Not affiliated with Logitech.