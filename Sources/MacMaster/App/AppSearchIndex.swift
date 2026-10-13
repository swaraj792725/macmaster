import Foundation

/// Every individual setting the global search can find. Feature pages themselves are added from `AppSection`.
///
/// `anchor` must match a `.searchAnchor("...")` on the page; `tab` must match what the page's `.searchTab` /
/// `.onSearchTab` accepts. Entries with neither just open the page. Pages owned by other work streams
/// (Menu Bar Icons, Control Center, Clock, Battery, Drop Shelf) are indexed at page level only.
enum AppSearchIndex {
    /// Pseudo tab: opens the Settings window instead of a page.
    static let appSettingsTab = "app-settings"

    static let settings: [SearchEntry] = optimizer + cleaner + uninstaller + monitor + input + menuBar + utilities + setup + app

    // MARK: Clean & Optimize

    private static let optimizer: [SearchEntry] = [
        SearchEntry(.optimizer, crumb: "Optimize", "Scan and optimize", "free memory purge ram cpu startup recommendations speed up", tab: "optimize"),
        SearchEntry(.optimizer, crumb: "Optimize", "Auto-optimize", "automatic background memory pressure", tab: "optimize"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Hide Dock launch bounce", "dock animation bounce launch", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Fast minimize effect", "dock minimize genie scale", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Instant Dock auto-hide", "dock autohide delay", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Faster Mission Control", "expose animation spaces", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Disable window open/close animations", "window animation speed", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Instant window resize", "window resize time animation", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Instant Quick Look", "quicklook preview animation", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Disable Finder animations", "finder animation", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Faster key repeat", "keyboard repeat rate delay", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Reduce motion", "accessibility animation", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Tweaks", "Reduce transparency", "accessibility blur translucency", tab: "tweaks"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Flush DNS cache", "dns network resolver", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Reset Quick Look cache", "quicklook thumbnails", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Rebuild Launch Services", "open with duplicates", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Clear font caches", "fonts", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Verify startup volume", "disk first aid", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "Maintenance", "Reset home folder permissions", "permissions repair", tab: "maintenance"),
        SearchEntry(.optimizer, crumb: "History", "Optimization history", "log past runs", tab: "history"),
    ]

    private static let cleaner: [SearchEntry] = [
        SearchEntry(.cleaner, crumb: "Smart Scan", "Smart Scan", "scan junk caches logs developer xcode trash", tab: "Smart Scan"),
        SearchEntry(.cleaner, crumb: "Smart Scan", "Disk usage", "storage free space available", tab: "Smart Scan"),
        SearchEntry(.cleaner, crumb: "Auto-Clean", "Run every", "schedule interval automatic cleaning daily weekly", anchor: "cleaner.auto", tab: "Auto-Clean"),
        SearchEntry(.cleaner, crumb: "Auto-Clean", "Only when plugged in to power", "auto clean battery charger", anchor: "cleaner.auto", tab: "Auto-Clean"),
        SearchEntry(.cleaner, crumb: "Auto-Clean", "Only when the Mac is idle", "auto clean idle input", anchor: "cleaner.auto", tab: "Auto-Clean"),
        SearchEntry(.cleaner, crumb: "Auto-Clean", "Notify me after cleaning", "notification auto clean", anchor: "cleaner.auto", tab: "Auto-Clean"),
        SearchEntry(.cleaner, crumb: "Auto-Clean", "Cleaning history", "log past cleans", anchor: "cleaner.auto", tab: "Auto-Clean"),
    ]

    private static let uninstaller: [SearchEntry] = [
        SearchEntry(.uninstaller, crumb: "Applications", "Applications list", "installed apps sort filter size last used unused large", tab: "Applications"),
        SearchEntry(.uninstaller, crumb: "Applications", "Reset app data", "reset keep app remove data only", tab: "Applications"),
        SearchEntry(.uninstaller, crumb: "Leftover Hunter", "Leftover Hunter", "orphan files deleted apps remains", tab: "Leftover Hunter"),
        SearchEntry(.uninstaller, crumb: "Leftover Hunter", "Broken login items & launch agents", "startup orphan agents", tab: "Leftover Hunter"),
        SearchEntry(.uninstaller, crumb: "Settings", "Delete immediately (skip Trash)", "permanent delete trash", tab: "settings"),
        SearchEntry(.uninstaller, crumb: "Settings", "Show low-confidence matches", "leftovers confidence", tab: "settings"),
        SearchEntry(.uninstaller, crumb: "Settings", "Scan system locations (/Library)", "library system scan", tab: "settings"),
        SearchEntry(.uninstaller, crumb: "Settings", "Offer to clean up after deleted apps", "watch deletions trash", tab: "settings"),
    ]

    // MARK: Monitor

    private static let monitor: [SearchEntry] = [
        SearchEntry(.stats, crumb: "CPU", "CPU usage", "processor load cores", anchor: "stats.cpu"),
        SearchEntry(.stats, crumb: "Memory", "Memory usage", "ram swap pressure wired compressed", anchor: "stats.memory"),
        SearchEntry(.stats, crumb: "GPU", "GPU usage", "graphics", anchor: "stats.gpu"),
        SearchEntry(.stats, crumb: "Disk", "Disk activity", "read write storage io", anchor: "stats.disk"),
        SearchEntry(.stats, crumb: "Network", "Network traffic", "download upload bandwidth speed", anchor: "stats.network"),
        SearchEntry(.stats, crumb: "Sensors", "Temperatures and fans", "thermal heat fan rpm sensors", anchor: "stats.sensors"),
        SearchEntry(.stats, crumb: "Power", "Power draw", "watts energy consumption", anchor: "stats.power"),
        SearchEntry(.stats, crumb: "Processes", "Process explorer", "top apps kill quit activity monitor", anchor: "stats.processes"),
        SearchEntry(.stats, crumb: "Menu bar", "Menu bar stats style", "menu bar graph text sparkline style", anchor: "stats.menubar"),
        SearchEntry(.stats, crumb: "Menu bar", "Show time remaining (Text styles)", "menu bar battery text", anchor: "stats.menubar"),
        SearchEntry(.stats, "Refresh interval", "update rate 1 s 2 s 5 s speed sampling"),

        SearchEntry(.health, crumb: "Issues", "Active issues", "problems warnings critical", anchor: "health.issues"),
        SearchEntry(.health, crumb: "Checklist", "Security & maintenance", "checklist filevault firewall updates gatekeeper", anchor: "health.checklist"),
        SearchEntry(.health, crumb: "Activity", "Last hour", "activity chart history", anchor: "health.activity"),
        SearchEntry(.health, crumb: "Activity", "Apps preventing sleep", "sleep assertions caffeinate", anchor: "health.activity"),
        SearchEntry(.health, crumb: "Event log", "Event log", "history issues past", anchor: "health.log"),
        SearchEntry(.health, crumb: "Settings", "Monitor my Mac in the background", "watchdog enable background", anchor: "health.settings"),
        SearchEntry(.health, crumb: "Settings", "Send notifications for warnings and critical issues", "alerts notify", anchor: "health.settings"),
        SearchEntry(.health, crumb: "Settings", "Do not disturb (quiet hours)", "quiet hours schedule night", anchor: "health.settings"),
        SearchEntry(.health, crumb: "Settings", "Sensitivity", "thresholds rules strict relaxed", anchor: "health.settings"),

        SearchEntry(.battery, crumb: "Health", "Battery health", "capacity cycles wear design full charge condition"),
        SearchEntry(.battery, crumb: "Live electrical", "Live electrical", "voltage amperage watts temperature"),
        SearchEntry(.battery, crumb: "Cells", "Cell voltages", "cells pack"),
        SearchEntry(.battery, crumb: "Estimates", "Time remaining estimates", "time left discharge projected"),
        SearchEntry(.battery, crumb: "History", "Battery history", "chart range day week"),
        SearchEntry(.battery, crumb: "Apps using energy", "Apps using energy", "energy impact drain"),
        SearchEntry(.battery, crumb: "Alerts", "Notify when battery is low", "low battery alert notification"),
        SearchEntry(.battery, crumb: "Alerts", "Notify when charged to…", "full charge alert notification limit"),
        SearchEntry(.battery, "Menu bar battery icon", "glyph style percentage icon menu bar"),

        SearchEntry(.power, crumb: "Overview", "Power overview", "sleep display now actions top energy users", tab: "overview"),
        SearchEntry(.power, crumb: "Overview", "Top energy users", "apps energy impact", tab: "overview"),
        SearchEntry(.power, crumb: "Schedule", "Schedule sleep, restart or shutdown", "timer action when time", tab: "schedule"),
        SearchEntry(.power, crumb: "Schedule", "Sleep when battery is low", "automation battery percent", tab: "schedule"),
        SearchEntry(.power, crumb: "Schedule", "Act after an app or process quits", "automation quit process shutdown", tab: "schedule"),
        SearchEntry(.power, crumb: "Schedule", "Shut down when the Mac is idle", "automation idle minutes", tab: "schedule"),
        SearchEntry(.power, crumb: "Schedule", "System schedule", "pmset repeat wake power on", tab: "schedule"),
        SearchEntry(.power, crumb: "Sleep", "Sleep and wake history", "log wake reasons", tab: "sleep"),
        SearchEntry(.power, crumb: "Sleep", "Top wake reasons", "why mac woke", tab: "sleep"),
        SearchEntry(.power, crumb: "Sleep", "Stay awake for a duration", "keep awake caffeinate timer", tab: "sleep"),
        SearchEntry(.power, crumb: "Settings", "pmset power settings", "display sleep disk sleep wake on lan power nap standby hibernate", tab: "settings"),
        SearchEntry(.power, crumb: "Settings", "Battery charge limit", "optimized battery charging 80 percent", tab: "settings"),

        SearchEntry(.wifi, crumb: "Speed", "Speed test", "download upload ping internet", anchor: "wifi.speed"),
        SearchEntry(.wifi, crumb: "Networks", "Nearby networks", "scan ssid channel signal", anchor: "wifi.networks"),
        SearchEntry(.wifi, crumb: "Automations", "Wi-Fi automations", "join leave network actions", anchor: "wifi.automations"),
        SearchEntry(.wifi, crumb: "Settings", "Show Wi-Fi in menu bar", "menu bar icon enable", anchor: "wifi.settings"),
        SearchEntry(.wifi, crumb: "Settings", "Update interval", "refresh seconds", anchor: "wifi.settings"),
        SearchEntry(.wifi, crumb: "Settings", "Show public IP", "ip address ipify", anchor: "wifi.settings"),
        SearchEntry(.wifi, crumb: "Settings", "Icon style", "classic bars menu bar glyph", anchor: "wifi.settings"),
        SearchEntry(.wifi, crumb: "Settings", "Hide Apple's Wi-Fi icon", "replace system icon control center", anchor: "wifi.settings"),
    ]

    // MARK: Input & Windows

    private static let input: [SearchEntry] = [
        SearchEntry(.mouse, crumb: "Scrolling", "Reverse vertical scrolling", "natural scroll direction wheel", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Reverse horizontal scrolling", "natural scroll direction", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Smooth scrolling", "smoothness animation glide", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Scroll speed", "faster slower", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Scroll acceleration", "faster spins", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Inertia", "keep gliding wheel stops momentum", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Shift + scroll scrolls horizontally", "modifier keys horizontal", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Option + scroll is slow and precise", "modifier keys precise", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Control + scroll is fast", "modifier keys fast", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Scrolling", "Command + scroll passes through untouched", "zoom modifier", anchor: "mouse.scrolling"),
        SearchEntry(.mouse, crumb: "Buttons", "Button remapping", "extra buttons back forward middle click double click hold actions", anchor: "mouse.buttons"),
        SearchEntry(.mouse, crumb: "Gestures", "Click and drag gestures", "gesture button drag left right up down distance", anchor: "mouse.gestures"),
        SearchEntry(.mouse, crumb: "Pointer", "Disable pointer acceleration", "flat movement tracking speed", anchor: "mouse.pointer"),
        SearchEntry(.mouse, crumb: "Pointer", "Custom pointer speed", "cursor speed sensitivity", anchor: "mouse.pointer"),
        SearchEntry(.mouse, crumb: "Test area", "Test area", "try scrolling buttons device", anchor: "mouse.test"),

        SearchEntry(.keyboard, crumb: "Hyper Key", "Hyper key", "caps lock remap control option shift command", tab: "hyper"),
        SearchEntry(.keyboard, crumb: "Hyper Key", "Tap alone sends Escape", "esc caps lock hyper", tab: "hyper"),
        SearchEntry(.keyboard, crumb: "App Shortcuts", "App shortcuts", "global hotkeys launch open folder url command", tab: "shortcuts"),
        SearchEntry(.keyboard, crumb: "Hot Corners", "Hot corners", "screen corner action dwell modifier", tab: "corners"),
        SearchEntry(.keyboard, crumb: "Hot Corners", "Dwell delay", "corner hover time", tab: "corners"),
        SearchEntry(.keyboard, crumb: "Hot Corners", "Corner flash", "corner animation", tab: "corners"),
        SearchEntry(.keyboard, crumb: "Extras", "Cleaning mode", "lock keyboard trackpad wipe clean screen", anchor: "kbd.cleaning", tab: "extras"),
        SearchEntry(.keyboard, crumb: "Extras", "Text expansion", "snippets trigger abbreviation autocorrect", anchor: "kbd.snippets", tab: "extras"),
        SearchEntry(.keyboard, crumb: "Extras", "Key press visualizer", "show keys screen recording presentation", anchor: "kbd.viz", tab: "extras"),
        SearchEntry(.keyboard, crumb: "Extras", "Hold ⌘Q to quit", "command q guard accidental quit", anchor: "kbd.viz", tab: "extras"),

        SearchEntry(.windows, crumb: "Window switcher", "Enable window switcher", "cmd tab alt tab previews", anchor: "windows.switcher"),
        SearchEntry(.windows, crumb: "Window switcher", "Switcher shortcut", "command tab option tab modifier", anchor: "windows.switcher"),
        SearchEntry(.windows, crumb: "Window switcher", "Switcher thumbnail size", "preview size", anchor: "windows.switcher"),
        SearchEntry(.windows, crumb: "While the switcher is open", "Switcher keys", "arrows quit close minimize hide keyboard", anchor: "windows.keys"),
        SearchEntry(.windows, crumb: "Dock previews", "Show previews when hovering Dock icons", "dock hover thumbnails", anchor: "windows.dock"),
        SearchEntry(.windows, crumb: "Dock previews", "Dock hover delay", "delay seconds", anchor: "windows.dock"),
        SearchEntry(.windows, crumb: "Dock previews", "Dock thumbnail size", "preview size", anchor: "windows.dock"),

        SearchEntry(.tiling, crumb: "Drag to Snap", "Snap windows by dragging", "edges preview release", anchor: "tiling.snap"),
        SearchEntry(.tiling, crumb: "Drag to Snap", "Edge and corner snap zones", "halves quarters maximize thirds top bottom left right", anchor: "tiling.snap"),
        SearchEntry(.tiling, crumb: "Drag to Snap", "Zone sensitivity", "edge distance", anchor: "tiling.snap"),
        SearchEntry(.tiling, crumb: "Drag to Snap", "Restore size when dragged away", "unsnap previous size", anchor: "tiling.snap"),
        SearchEntry(.tiling, crumb: "Drag to Snap", "Window gap", "spacing padding between windows", anchor: "tiling.snap"),
        SearchEntry(.tiling, crumb: "Snap Layouts", "Show layouts on green button hover", "zoom button popover", anchor: "tiling.layouts"),
        SearchEntry(.tiling, crumb: "Keyboard Shortcuts", "Tiling global shortcuts", "hotkeys halves thirds maximize center", anchor: "tiling.keys"),
        SearchEntry(.tiling, crumb: "Modifier Drag", "Move and resize with a modifier", "linux style alt drag", anchor: "tiling.modifier"),
        SearchEntry(.tiling, crumb: "Extras", "Focus follows mouse", "raise window under pointer", anchor: "tiling.extras"),
        SearchEntry(.tiling, crumb: "Extras", "Double-click title bar to maximize", "title bar maximize restore", anchor: "tiling.extras"),
        SearchEntry(.tiling, crumb: "Extras", "Tile all windows", "grid arrange", anchor: "tiling.extras"),
        SearchEntry(.tiling, crumb: "Saved Layouts", "Saved layouts", "save restore window arrangement", anchor: "tiling.saved"),
    ]

    // MARK: Menu Bar (page-level targets: pages owned elsewhere)

    private static let menuBar: [SearchEntry] = [
        SearchEntry(.menubar, crumb: "Behaviour", "Auto-rehide", "hide icons again after seconds"),
        SearchEntry(.menubar, crumb: "Behaviour", "Menu bar manager shortcut", "global shortcut hotkey toggle hidden icons"),
        SearchEntry(.menubar, crumb: "Dropdown", "Include macOS items", "apple items dropdown"),
        SearchEntry(.menubar, crumb: "Dropdown bar", "Use dropdown bar", "hidden icons tray panel"),
        SearchEntry(.menubar, crumb: "Spacing", "Item spacing", "menu bar icon padding tight"),
        SearchEntry(.menubar, crumb: "Spacing", "Selection padding", "highlight padding"),
        SearchEntry(.menubar, crumb: "Spacing", "Restart menu bar services", "refresh systemuiserver"),
        SearchEntry(.menubar, crumb: "Appearance", "Toggle glyph", "chevron icon collapse button"),
        SearchEntry(.menubar, crumb: "Appearance", "Show divider glyph", "separator"),
        SearchEntry(.menubar, "Hide menu bar icons", "collapse bartender declutter notch"),
        SearchEntry(.menubar, "Rearrange menu bar icons", "drag order zones visible hidden always hidden"),

        SearchEntry(.controlcenter, crumb: "Apple's icons", "Apple's Control Center opens MacMaster", "redirect clicks apple icon dropdown"),
        SearchEntry(.controlcenter, crumb: "Apple's icons", "Apple's clock opens MacMaster's Clock", "redirect clicks apple clock"),
        SearchEntry(.controlcenter, crumb: "Hide Apple's icons", "Open Menu Bar settings", "hide apple menu bar items system settings"),

        SearchEntry(.clock, crumb: "Format", "Show in menu bar", "clock enable menu bar"),
        SearchEntry(.clock, crumb: "Presets", "Clock presets", "format preset"),
        SearchEntry(.clock, crumb: "Format", "24-hour time", "military time"),
        SearchEntry(.clock, crumb: "Format", "Show AM/PM", "12 hour"),
        SearchEntry(.clock, crumb: "Format", "Show seconds", "seconds clock timer"),
        SearchEntry(.clock, crumb: "Format", "Show date", "date menu bar"),
        SearchEntry(.clock, crumb: "Format", "Show weekday", "day of week"),
        SearchEntry(.clock, crumb: "Format", "Week numbers in calendar", "iso week"),
        SearchEntry(.clock, crumb: "Custom pattern", "Custom clock pattern", "unicode date format EEE"),
        SearchEntry(.clock, crumb: "Second time zone", "Second time zone", "zone label other city"),
        SearchEntry(.clock, crumb: "World clocks", "World clocks", "cities map day night time zones"),
        SearchEntry(.clock, crumb: "Calendar events", "Calendar events", "calendar access agenda"),
        SearchEntry(.clock, crumb: "Apple's menu bar clock", "Apple's menu bar clock", "hide system clock replace"),
    ]

    // MARK: Utilities

    private static let utilities: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Large & Old Files", "Large & Old Files", "biggest oldest files space", tab: "largeFiles"),
        SearchEntry(.tools, crumb: "Duplicate Finder", "Duplicate Finder", "identical files copies", tab: "duplicates"),
        SearchEntry(.tools, crumb: "Startup Manager", "Startup Manager", "login items launch agents daemons", tab: "startup"),
        SearchEntry(.tools, crumb: "Keep Awake", "Keep Awake", "prevent sleep caffeinate amphetamine timer", tab: "keepAwake"),
        SearchEntry(.tools, crumb: "Quick Actions", "Quick Actions", "flush dns restart dock finder rebuild spotlight", tab: "quickActions"),
        SearchEntry(.tools, crumb: "Clipboard History", "Clipboard History", "copied paste history pin", tab: "clipboard"),
        SearchEntry(.tools, crumb: "System Info", "System Info", "about this mac chip memory displays serial", tab: "systemInfo"),

        SearchEntry(.shelf, crumb: "Drop Shelf", "Enable Drop Shelf", "watch file drags"),
        SearchEntry(.shelf, crumb: "Menu bar", "Show Drop Shelf in menu bar", "item count badge"),
        SearchEntry(.shelf, crumb: "Open the shelf", "Shake to open", "wiggle drag"),
        SearchEntry(.shelf, crumb: "Open the shelf", "Screen edge hot zone", "drag edge"),
        SearchEntry(.shelf, crumb: "Behavior", "Close when empty", "auto close"),
    ]

    // MARK: Setup

    private static let setup: [SearchEntry] = [
        SearchEntry(.permissions, crumb: "Accessibility", "Accessibility permission", "event tap windows keyboard mouse", anchor: "perm.accessibility"),
        SearchEntry(.permissions, crumb: "Screen Recording", "Screen Recording permission", "thumbnails previews capture", anchor: "perm.screenRecording"),
        SearchEntry(.permissions, crumb: "Full Disk Access", "Full Disk Access permission", "protected folders mail safari", anchor: "perm.fullDiskAccess"),
        SearchEntry(.permissions, crumb: "Notifications", "Notifications permission", "alerts banners", anchor: "perm.notifications"),
        SearchEntry(.permissions, crumb: "Location", "Location permission", "wi-fi network names ssid", anchor: "perm.location"),
        SearchEntry(.permissions, crumb: "Calendars", "Calendars permission", "events clock agenda", anchor: "perm.calendars"),
    ]

    // MARK: App settings (Settings window)

    private static let app: [SearchEntry] = [
        SearchEntry(.permissions, "Launch at login", "startup open automatically login item", tab: appSettingsTab),
        SearchEntry(.permissions, "Hide Dock icon", "dock menu bar only agent", tab: appSettingsTab),
        SearchEntry(.permissions, "Show menu bar icon", "status item tray", tab: appSettingsTab),
        SearchEntry(.permissions, "Sample interval", "refresh rate monitoring cpu", tab: appSettingsTab),
        SearchEntry(.permissions, "MacMaster settings", "preferences app settings window", tab: appSettingsTab),
    ]
}

extension SearchEntry {
    /// True for entries that open the Settings window rather than a page.
    var opensAppSettings: Bool { tab == AppSearchIndex.appSettingsTab }
}
