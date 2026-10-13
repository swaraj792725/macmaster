<div align="center">

<img src="docs/screenshots/icon.png" width="96" alt="">

# MacMaster

**One free, native app for cleaning, monitoring and tuning your Mac.**

Cleaner · Uninstaller · Optimizer · System Stats · Health Monitor · Battery & charge limit · Power ·
Mouse · Keyboard · Window Switcher · Window Tiling · Menu Bar · Clock · Toolbox

[**Download the latest release**](https://github.com/swaraj792725/macmaster/releases/latest) ·
macOS 14 Sonoma or later · Apple Silicon ·
[GPL-3.0](LICENSE)

<img src="docs/screenshots/dashboard.png" width="900" alt="MacMaster dashboard">

</div>

MacMaster replaces a drawer full of small utilities with one SwiftUI app. It has no account, no
subscription, no telemetry and no third-party code. Nothing you scan, clean or monitor leaves your Mac.

---

## Features

### Clean & optimize

| | |
|---|---|
| <img src="docs/screenshots/cleaner.png" width="440" alt="Cleaner"> | **Cleaner.** A smart scan of caches, logs, developer junk (Xcode DerivedData, npm, pip, Homebrew, Gradle…), old installers and Time Machine local snapshots. You review everything before it goes. Auto-clean can run on a schedule. |
| <img src="docs/screenshots/uninstaller.png" width="440" alt="Uninstaller"> | **Uninstaller.** Removes an app together with its containers, group containers, launch agents and daemons, helpers, receipts and crash logs. **Leftover Hunter** finds files from apps you already deleted. |
| <img src="docs/screenshots/optimizer.png" width="440" alt="Optimizer"> | **Optimizer.** Plain-language recommendations for memory, CPU, disk and startup items, each with the expected gain. One click applies them. |

### Monitor

| | |
|---|---|
| <img src="docs/screenshots/stats.png" width="440" alt="System Stats"> | **System Stats.** CPU per core, memory, GPU, disk, network, temperature sensors, fans and processes. Each one can be a menu bar item with its own detail popover. |
| <img src="docs/screenshots/health.png" width="440" alt="Health Monitor"> | **Health Monitor.** A background watchdog for runaway processes, memory leaks, memory pressure, low disk space, heat, battery drain and crash loops. It notifies you and offers one-click fixes, plus a security checkup. |
| <img src="docs/screenshots/battery.png" width="440" alt="Battery"> | **Battery.** Health, cycles, capacities, live power, voltage and temperature, history charts and alerts. Set the **charge limit** (80, 85, 90, 95 or 100%) right here or from the menu bar. |
| <img src="docs/screenshots/power.png" width="440" alt="Power"> | **Power.** Shows what is using energy, schedules sleep and wake, and lets you edit every power setting with plain-language names. |

### Battery charge limit

<img src="docs/screenshots/popover-battery.png" width="300" align="right" alt="Battery menu bar dropdown with charge limit">

Click the battery item in the menu bar and pick a limit. Charging stops there, which slows battery
aging when your Mac lives on the charger.

- This is **macOS's own charge limit**, the same setting as System Settings → Battery → Charge Limit.
  It keeps working when MacMaster is closed, and it needs no helper, root password or SMC writes.
- macOS currently allows 80–100% in 5% steps. 100% means no limit.
- The Battery page and Power settings have the same control. While the battery is held at the limit,
  the status reads "Not charging (80% charge limit)" instead of a vague "not charging".

<br clear="right">

### Input & windows

| | |
|---|---|
| <img src="docs/screenshots/mouse.png" width="440" alt="Mouse"> | **Mouse.** Smooth scrolling and reverse scrolling for external mice only (trackpads are untouched), button remapping with 30+ actions, and hold-and-drag actions such as switching Spaces or Mission Control. |
| <img src="docs/screenshots/keyboard.png" width="440" alt="Keyboard"> | **Keyboard.** A Hyper key (Caps Lock becomes ⌃⌥⇧⌘, or Escape when tapped alone), app shortcuts, hot corners and extras. |
| <img src="docs/screenshots/tiling.png" width="440" alt="Window Tiling"> | **Window Tiling.** Drag windows to snap zones, use snap layouts or keyboard shortcuts, move windows with a modifier key, and save layouts. |
| | **Window Switcher.** Option-Tab switching with live window previews, plus window thumbnails when you hover over the Dock. |

### Menu bar & tools

| | |
|---|---|
| <img src="docs/screenshots/popover.png" width="300" alt="Menu bar control center"> | **Menu bar control center.** Health score, live CPU, RAM, GPU and disk gauges, quick toggles (Keep Awake, Dark Mode, Wi-Fi, Bluetooth, hidden files, Low Power…), display and sound sliders and one-click actions. **Menu Bar Icons** hides other apps' icons behind a « button. |
| <img src="docs/screenshots/tools.png" width="440" alt="Toolbox"> | **Toolbox.** Large & old files, a duplicate finder, a startup manager, Keep Awake, quick maintenance actions (flush DNS, restart Dock or Finder…), clipboard history and system info. |
| <img src="docs/screenshots/clock.png" width="440" alt="Clock"> | **Clock.** A configurable menu bar clock, a second time zone, world clocks with a day/night map, a calendar and your upcoming events. |

Also included: Wi-Fi details with network automations and Instant Hotspot, and a Drop Shelf for files you drag around.

---

## Install

1. Download `MacMaster-x.y.z.dmg` from [Releases](https://github.com/swaraj792725/macmaster/releases/latest).
2. Open it and drag **MacMaster** to **Applications**.
3. The app is not notarized yet (that needs a paid Apple Developer account), so macOS blocks the first launch.
   Use one of these:
   - Right-click MacMaster in Applications → **Open** → **Open**, or
   - System Settings → Privacy & Security → scroll down → **Open Anyway**, or
   - in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/MacMaster.app
     ```

MacMaster checks GitHub for new versions once a day (you can turn this off in Settings). It never installs anything by itself.

## Permissions

MacMaster asks for a permission only when you turn on a feature that needs it.

| Permission | Used by |
|---|---|
| **Full Disk Access** | Cleaner, Uninstaller and Leftover Hunter, to see containers and protected Library folders |
| **Accessibility** | Mouse, Keyboard, Window Switcher, Window Tiling, hung-app detection |
| **Screen Recording** | Window thumbnails in the switcher and Dock previews |
| **Location** | Wi-Fi rules that match a network by name (macOS hides network names without it) |
| **Calendars** | Upcoming events in the menu bar clock |

## Privacy

- No account, no analytics, no crash reporting and no ads.
- The only network request MacMaster makes on its own is the daily update check to the GitHub Releases API, and you can turn it off.
- Nothing is removed until you review it. The Uninstaller moves apps and their files to the Trash by default.

## Build from source

You only need the Command Line Tools. Xcode is not required.

```bash
git clone https://github.com/swaraj792725/macmaster.git
```

```bash
cd macmaster && scripts/build-app.sh release --install --run
```

- `scripts/create-signing-cert.sh` (optional, one time) creates a local signing identity, so permission grants survive rebuilds.
- `scripts/typecheck.sh Battery` quickly typechecks one feature.
- `scripts/make-dmg.sh` builds a DMG. See [docs/RELEASE.md](docs/RELEASE.md) for the release steps.

```
Sources/MacMaster/
  App/        entry point, sidebar, dashboard, menu bar panel, settings
  Core/       design system, shell, permissions, notifications, hardware readers and monitors
  Features/   one folder per feature (Battery, Cleaner, Mouse, Tiling, …)
```

## Support

MacMaster is free and made by one person. If it saves you time or money, star the repo and tell a
friend. Bug reports and ideas are welcome in [Issues](https://github.com/swaraj792725/macmaster/issues).

<!-- Donation link goes here once set up, e.g. GitHub Sponsors or Ko-fi. -->

## License

Copyright © 2026 Swaraj.

MacMaster is free software, released under the [GNU General Public License v3.0](LICENSE).
You may use, study, share and modify it. If you distribute a modified version, it must also be
released under GPL-3.0 with its source code, and keep the original copyright notice.

MacMaster uses no third-party code. Some techniques (reading Apple Silicon temperature sensors,
the private CGS hotkey API for the window switcher) follow approaches documented by open-source
apps such as [Stats](https://github.com/exelban/stats) and [AltTab](https://github.com/lwouis/alt-tab-macos).
