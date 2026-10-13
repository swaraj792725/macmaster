# Changelog

All notable changes to MacMaster are listed here. Versions follow [Semantic Versioning](https://semver.org).
The app reads this file for its "What's New" window, so keep the format: `## [x.y.z] - YYYY-MM-DD`,
then `### Group` headings with `- ` bullets.

## [0.4.1] - 2026-10-13

### Fixed
- MacMaster could still freeze, soon after launch or while the menu bar tray was in use. It read its own menu bar icons through Accessibility, which ran interface code off the main thread. It now reads and clicks its own icons directly. Window tiling, the window switcher and Dock previews also stopped querying MacMaster's own windows through Accessibility.

## [0.4.0] - 2026-10-13

### Added
- Battery: set the charge limit (80, 85, 90, 95 or 100%) from the battery menu bar dropdown. It is macOS's own charge limit, so it keeps working when MacMaster is closed. The same control is on the Battery page (now near the top) and in Power settings.

### Changed
- While the battery is held at the charge limit, MacMaster says so ("Not charging (80% charge limit)", "Held at 80%") instead of "paused by macOS".
- The battery dropdown says "Drawing from battery" instead of "Discharging" when the Mac is on the charger, and "Idle" when no power flows.
- "Checked 5 min ago" style times now update on their own.

### Fixed
- Installed memory showed as "17.18 GB" on a 16 GB Mac. Memory is now shown the way About This Mac shows it.
- Cleaner: items in a location that can't be removed were counted as freed space. They are now listed as failures.
- Uninstaller: files that were already gone were counted as removed and added to the space freed.
- Processes: the first refresh no longer lists every process at 0% in random order.
- Disk activity no longer shows a huge spike when a drive's counters reset.
- Toolbox: a card's arrow no longer stays visible after you leave the page.
- "1 cycles", "1 days" and similar counts now read correctly.

## [0.3.0] - 2026-10-13

### Fixed
- MacMaster could freeze for good, usually while you scrolled. Saving mouse stats in the background could deadlock with the interface. Settings changes no longer make any background work wait for the interface.
- The menu bar "next event" could freeze the same way when Calendar changed, at midnight, or after a clock change.
- Turning the menu bar "next event" off and on no longer piles up duplicate refreshes.

## [0.2.0] - 2026-10-13

### Added
- Mouse: hold a button and drag to switch Spaces, open Mission Control or App Exposé, scroll (grab and drag), scroll sideways, or run your own action for each direction.
- Mouse: about 30 new button actions: tabs, windows, undo/redo, media keys, volume, Spotlight, Notification Center, screenshot, lock screen, Page Up/Down and more, grouped in the picker.
- Mouse: settings for buttons 6 to 9, and pressing a button on your mouse selects it on the Mouse page.
- Updates: MacMaster checks GitHub for new versions once a day (can be turned off), plus "Check for Updates…" in the app menu and Settings.
- What's New window with this changelog, shown once after an update.
- Menu bar tray: hide menu bar icons behind a « button or keep them always hidden.
- Drop Shelf menu bar icon. The popover accepts drops, including screenshot thumbnails.
- Optional click redirect for Apple's Control Center and Clock icons. Off by default.
- Wi-Fi: Instant Hotspot and network automations.
- Clock: world map with a live day/night line, plus calendar events.
- Battery: charge limit, more menu bar glyphs and a low power tint.
- Sidebar groups, settings search (⌘F) and a dashboard launcher.

### Changed
- Spaces, Mission Control and similar actions now use the system's own shortcuts, so they work even if you turned those shortcuts off in System Settings.
- The mouse's Back and Forward side buttons now appear in the right places on the illustration.
- The old "Gestures" card is now each button's "Hold & drag" option. Existing gesture settings are carried over.
- One MacMaster menu bar icon. Its dropdown includes the Control Center controls.

### Fixed
- Clipboard history: clicking an item pastes it into the app you were using. Before, MacMaster's own window, or the desktop, came to the front.
- Menu bar popovers give focus back to the app you were in when they close.
- Window switcher: apps in the Stage Manager side strip show a preview instead of just their icon.
- Window switcher: no longer lists closed windows that an app keeps alive in the background, such as welcome screens.
- Instant Hotspot crash.

## [0.1.0] - 2026-10-13

### Added
- First release: dashboard, live stats in the menu bar, cleaner, optimizer, uninstaller, battery and power tools, keyboard remapping, mouse smooth scrolling and button remapping, window tiling, window switcher and Dock previews, clipboard history, Drop Shelf, Wi-Fi tools and world clock.
