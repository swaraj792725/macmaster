# MacMaster

All-in-one native macOS utility (SwiftUI, Apple Silicon, macOS 14+).

| Area | What it does |
|---|---|
| Uninstaller | Deep app removal (containers, group containers, launch agents/daemons, helpers, receipts, crash logs) + **Leftover Hunter** that finds files of apps you already deleted (e.g. Chrome, Chrome for Testing, Keystone, puppeteer/playwright browsers) |
| Cleaner | Smart scan of caches, logs, developer junk (DerivedData, npm, pip, Homebrew, Gradle…), installers, TM snapshots; scheduled auto-clean |
| Battery | Custom battery glyphs, health, cycles, capacities, live power/voltage/temperature, history charts, alerts |
| System Stats | CPU (per core), memory, GPU, disk, network, sensors, fans, processes + configurable menu bar items |
| Health Monitor | Background watchdog: runaway processes, leaks, memory pressure, disk, thermal, battery drain, crash loops; notifications + one-click fixes; security checkup |
| Mouse | Smooth scrolling, mouse-only reverse scroll, button remapping, drag gestures (Mac Mouse Fix style) |
| Window Preview | Dock hover window thumbnails + Option-Tab window switcher |
| Toolbox | Large files, duplicates, startup manager, Keep Awake, clipboard history, quick maintenance actions |

## Build (Command Line Tools only — no Xcode needed)

```bash
scripts/build-app.sh release --install --run
```

Optional one-time: `scripts/create-signing-cert.sh` creates a local signing identity so permission grants survive rebuilds.

Fast typecheck of one feature: `scripts/typecheck.sh Battery`

## Permissions
- **Full Disk Access** — Uninstaller / Leftover Hunter / Cleaner (to see containers and protected Library folders)
- **Accessibility** — Mouse engine, Window Preview, hung-app detection
- **Screen Recording** — window thumbnails

## Layout
```
Sources/MacMaster/
  App/        entry, sidebar, dashboard, menu bar panel, settings
  Core/       design system, shell/permissions/notifications, hardware readers & monitors
  Features/   Uninstaller, Cleaner, Battery, Stats, Health, Mouse, WindowPreview, Tools
```

## License

Copyright © 2026 Swaraj.

MacMaster is free software, released under the [GNU General Public License v3.0](LICENSE).
You may use, study, share and modify it. If you distribute a modified version, it must also be
released under GPL-3.0 with its source code, and keep the original copyright notice.

MacMaster uses no third-party code. Some techniques (reading Apple Silicon temperature sensors,
the private CGS hotkey API for the window switcher) follow approaches documented by open-source
apps such as [Stats](https://github.com/exelban/stats) and [AltTab](https://github.com/lwouis/alt-tab-macos).
