import SwiftUI
import Observation

// MARK: - Entry

/// One searchable thing: a whole feature page or a single setting on a page.
struct SearchEntry: Identifiable, Hashable {
    let section: AppSection
    /// Optional card / area label between the section and the title, e.g. "Scrolling".
    let crumb: String?
    let title: String
    let keywords: String
    /// `.searchAnchor` id to scroll to and highlight. nil = open the page only.
    let anchor: String?
    /// Raw value of the tab to switch to first (see `.onSearchTab`).
    let tab: String?
    let isFeature: Bool

    var id: String { "\(section.rawValue)|\(crumb ?? "")|\(title)" }

    /// Breadcrumb shown under the title, e.g. "Menu Bar › Clock › Show seconds".
    var path: String {
        if opensAppSettings { return "App Settings › " + title }
        if isFeature { return section.group == .overview ? "Home" : section.group.title }
        var parts = [section.group.title, section.title]
        if let crumb, crumb != title, crumb != section.title { parts.append(crumb) }
        parts.append(title)
        return parts.joined(separator: " › ")
    }

    // Pre-folded text for matching.
    fileprivate let hayTitle: String
    fileprivate let hayContext: String
    fileprivate let hayKeywords: String

    init(_ section: AppSection, crumb: String? = nil, _ title: String, _ keywords: String = "",
         anchor: String? = nil, tab: String? = nil, feature: Bool = false) {
        self.section = section; self.crumb = crumb; self.title = title; self.keywords = keywords
        self.anchor = anchor; self.tab = tab; self.isFeature = feature
        hayTitle = AppSearch.fold(title)
        hayContext = AppSearch.fold(tab == AppSearchIndex.appSettingsTab
            ? "app settings preferences"
            : [section.title, section.group.title, crumb ?? ""].joined(separator: " "))
        hayKeywords = AppSearch.fold(keywords)
    }
}

// MARK: - Engine

enum AppSearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Whole-app index: one entry per feature page plus every indexed setting.
    static let all: [SearchEntry] = {
        let features = AppSection.allCases.map {
            SearchEntry($0, $0.title, $0.blurb + " " + $0.searchWords, feature: true)
        }
        return features + AppSearchIndex.settings
    }()

    static func results(for query: String, limit: Int = 40) -> [SearchEntry] {
        let tokens = fold(query).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(SearchEntry, Int)] = []
        for e in all {
            var total = 0
            var ok = true
            for t in tokens {
                var best = 0
                if e.hayTitle.hasPrefix(t) { best = 100 }
                else if e.hayTitle.contains(" " + t) { best = 85 }
                else if e.hayTitle.contains(t) { best = 70 }
                else if e.hayContext.contains(t) { best = 35 }
                else if e.hayKeywords.contains(t) { best = 20 }
                if best == 0 { ok = false; break }
                total += best
            }
            guard ok else { continue }
            if e.isFeature { total += 12 }
            scored.append((e, total))
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.title.count < b.0.title.count
        }
        return scored.prefix(limit).map(\.0)
    }
}

// MARK: - Router

/// Carries a search result to the page that owns the setting.
/// Flow: `go(_:)` sets `pending` -> page switches tab (`.onSearchTab`) -> `Page` scrolls to the anchor -> highlight flashes.
@MainActor @Observable
final class AppSearchRouter {
    static let shared = AppSearchRouter()

    struct Target: Equatable { let anchor: String?; let tab: String?; let stamp: Int }

    var pending: Target?
    var highlight: String?
    private(set) var tick = 0
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    func request(anchor: String?, tab: String?) {
        tick += 1
        let stamp = tick
        pending = Target(anchor: anchor, tab: tab, stamp: stamp)
        // Drop it if nothing consumed it (page without scroll support).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.pending?.stamp == stamp { self?.pending = nil }
        }
    }

    func flash(_ id: String) {
        flashTask?.cancel()
        highlight = id
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { self?.highlight = nil }
        }
    }
}

// MARK: - Modifiers

extension View {
    /// Marks a card/row as a search target: scroll anchor + brief highlight when selected from search.
    func searchAnchor(_ id: String) -> some View { modifier(SearchAnchorModifier(id: id)) }

    /// Called with the tab raw value when a search result lives on another tab of this page.
    func onSearchTab(_ apply: @escaping (String) -> Void) -> some View { modifier(SearchTabModifier(apply: apply)) }

    /// Tab binding with String-raw enum.
    func searchTab<T: RawRepresentable>(_ binding: Binding<T>) -> some View where T.RawValue == String {
        onSearchTab { raw in if let v = T(rawValue: raw) { binding.wrappedValue = v } }
    }

    /// Tab binding stored as a raw string.
    func searchTab(raw binding: Binding<String>) -> some View {
        onSearchTab { binding.wrappedValue = $0 }
    }
}

private struct SearchAnchorModifier: ViewModifier {
    let id: String
    @State private var router = AppSearchRouter.shared

    func body(content: Content) -> some View {
        let on = router.highlight == id
        content
            .id(id)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2))
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.smooth(duration: 0.3), value: on)
    }
}

private struct SearchTabModifier: ViewModifier {
    let apply: (String) -> Void
    @State private var router = AppSearchRouter.shared

    func body(content: Content) -> some View {
        content
            .onAppear { consume() }
            .onChange(of: router.tick) { _, _ in consume() }
    }

    private func consume() {
        if let tab = router.pending?.tab { apply(tab) }
    }
}

// MARK: - Page jump bar

struct PageJump: Identifiable {
    let id: String
    let title: String
    init(_ id: String, _ title: String) { self.id = id; self.title = title }
}

/// Sticky compact bar of capsule buttons that scroll the page to a section.
struct PageJumpBar: View {
    let items: [PageJump]
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button { onSelect(item.id) } label: {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension AppSection {
    /// Extra words so a feature page is found by what it does, not just by its name.
    fileprivate var searchWords: String {
        switch self {
        case .dashboard: "home overview launcher start"
        case .optimizer: "speed performance ram memory purge tweaks dock animations maintenance"
        case .uninstaller: "remove delete app leftovers reset trash"
        case .updates: "update upgrade sparkle app store homebrew brew cask outdated latest version"
        case .sound: "audio volume output input speaker headphones microphone mic mute airpods device priority"
        case .commandbar: "launcher spotlight raycast alfred command palette calculator run open apps search"
        case .capture: "screenshot ocr text recognition copy text qr code barcode color picker eyedropper pin"
        case .cleaner: "junk cache logs disk space storage auto clean smart scan"
        case .battery: "charge health cycles power capacity low battery alert"
        case .power: "sleep shutdown schedule restart energy pmset wake"
        case .stats: "cpu gpu memory ram disk network temperature processes activity monitor"
        case .health: "watchdog issues alerts security notifications"
        case .mouse: "scroll wheel buttons gestures pointer acceleration logitech"
        case .keyboard: "hyper key shortcuts hot corners snippets text expansion key visualizer"
        case .windows: "alt tab cmd tab switcher dock preview thumbnails"
        case .tiling: "snap windows layouts halves thirds maximize rectangle magnet"
        case .tools: "large files duplicates startup login items keep awake clipboard system info"
        case .shelf: "dropover drag drop files temporary"
        case .menubar: "hide icons bartender collapse arrange notch dropdown spacing"
        case .wifi: "signal speed ip address ssid network"
        case .controlcenter: "apple control center clock redirect menu bar icons"
        case .clock: "time date calendar world clock time zone format"
        case .permissions: "accessibility screen recording privacy access"
        }
    }
}
