import SwiftUI

enum ToolsTool: String, CaseIterable, Identifiable {
    case largeFiles, duplicates, diskMap, startup, keepAwake, quickActions, clipboard
    case timer, notes, teleprompter, dictation, privacyGuard, ports, systemInfo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicate Finder"
        case .startup: "Startup Manager"
        case .keepAwake: "Keep Awake"
        case .quickActions: "Quick Actions"
        case .clipboard: "Clipboard History"
        case .systemInfo: "System Info"
        case .diskMap: "Disk Map"
        case .ports: "Port Manager"
        case .timer: "Timer & Stopwatch"
        case .notes: "Notes"
        case .teleprompter: "Teleprompter"
        case .privacyGuard: "Privacy Guard"
        case .dictation: "Dictation"
        }
    }

    var blurb: String {
        switch self {
        case .largeFiles: "Find the biggest and oldest files taking up space and clear them out."
        case .duplicates: "Spot identical files by content and keep just one copy."
        case .startup: "See and control login items, launch agents and daemons."
        case .keepAwake: "Prevent your Mac from sleeping, for a while or while an app runs."
        case .quickActions: "One-click fixes: flush DNS, restart Dock or Finder, rebuild indexes and more."
        case .clipboard: "Everything you copied recently, searchable and pinnable."
        case .systemInfo: "About This Mac on steroids: chip, memory, displays, battery and more."
        case .diskMap: "See what fills your disk as a map you can click into."
        case .ports: "Which apps listen on which ports, and stop them in one click."
        case .timer: "Countdowns and a stopwatch in the menu bar, with alerts."
        case .notes: "A quick scratchpad that floats over your work and saves itself."
        case .teleprompter: "Read your script by the camera, hidden from screen sharing."
        case .privacyGuard: "Blurs your screen when you look away or someone looks over your shoulder."
        case .dictation: "Hold a key, speak, and the text lands where you type. Stays on your Mac."
        }
    }

    var symbol: String {
        switch self {
        case .largeFiles: "externaldrive.badge.minus"
        case .duplicates: "square.on.square"
        case .startup: "power.circle"
        case .keepAwake: "cup.and.saucer.fill"
        case .quickActions: "bolt.fill"
        case .clipboard: "doc.on.clipboard"
        case .systemInfo: "info.circle"
        case .diskMap: SymbolKit.firstAvailable(["square.grid.3x3.square", "square.grid.2x2.fill"])
        case .ports: SymbolKit.firstAvailable(["network", "point.3.connected.trianglepath.dotted"])
        case .timer: "timer"
        case .notes: "note.text"
        case .teleprompter: SymbolKit.firstAvailable(["text.alignleft", "text.justify"])
        case .privacyGuard: SymbolKit.firstAvailable(["eye.trianglebadge.exclamationmark", "eye.slash.fill"])
        case .dictation: "mic.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .largeFiles: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)]
        case .duplicates: [Color(hex: 0xC084FC), Color(hex: 0x7C3AED)]
        case .startup: [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
        case .keepAwake: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)]
        case .quickActions: [Color(hex: 0x34D399), Color(hex: 0x059669)]
        case .clipboard: [Color(hex: 0x38BDF8), Color(hex: 0x0369A1)]
        case .systemInfo: [Color(hex: 0x94A3B8), Color(hex: 0x475569)]
        case .diskMap: [Color(hex: 0x2DD4BF), Color(hex: 0x0F766E)]
        case .ports: [Color(hex: 0x818CF8), Color(hex: 0x4338CA)]
        case .timer: [Color(hex: 0xFB923C), Color(hex: 0xEA580C)]
        case .notes: [Color(hex: 0xFDE047), Color(hex: 0xCA8A04)]
        case .teleprompter: [Color(hex: 0xF472B6), Color(hex: 0xBE185D)]
        case .privacyGuard: [Color(hex: 0x4ADE80), Color(hex: 0x15803D)]
        case .dictation: [Color(hex: 0xF87171), Color(hex: 0xB91C1C)]
        }
    }
}

struct ToolsView: View {
    @State private var selected: ToolsTool?
    private let awake = ToolsKeepAwake.shared
    private let clipboard = ToolsClipboard.shared

    var body: some View {
        ZStack {
            if let tool = selected {
                detail(tool).transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                grid.transition(.move(edge: .leading).combined(with: .opacity))
            }
            ToolsToastOverlay()
        }
        .animation(.smooth(duration: 0.28), value: selected)
        .onSearchTab { selected = ToolsTool(rawValue: $0) }
    }

    private var grid: some View {
        Page {
            PageHeader(title: "Tools", subtitle: "Power tools that make your Mac more interesting",
                       symbol: "wrench.and.screwdriver.fill", colors: Theme.Palette.tools)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: Theme.spacing)], spacing: Theme.spacing) {
                ForEach(ToolsTool.allCases) { tool in
                    ToolsCard(tool: tool, badge: badge(for: tool)) { selected = tool }
                }
            }
        }
    }

    private func badge(for tool: ToolsTool) -> String? {
        switch tool {
        case .keepAwake: awake.isActive || awake.isArmed ? "On" : nil
        case .clipboard: clipboard.isEnabled ? "Recording" : nil
        default: nil
        }
    }

    @ViewBuilder
    private func detail(_ tool: ToolsTool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { selected = nil } label: { Label("Tools", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Divider().frame(height: 20)
                IconTile(symbol: tool.symbol, colors: tool.colors, size: 30)
                Text(tool.title).font(.system(size: 20, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
            Divider()
            Group {
                switch tool {
                case .largeFiles: ToolsLargeFilesView()
                case .duplicates: ToolsDuplicatesView()
                case .startup: ToolsStartupView()
                case .keepAwake: ToolsKeepAwakeView()
                case .quickActions: ToolsQuickActionsView()
                case .clipboard: ToolsClipboardView()
                case .systemInfo: ToolsSystemInfoView()
                case .diskMap: ToolsDiskMapView()
                case .ports: ToolsPortsView()
                case .timer: ToolsTimerView()
                case .notes: ToolsNotesView()
                case .teleprompter: ToolsTeleprompterView()
                case .privacyGuard: ToolsPrivacyGuardView()
                case .dictation: ToolsDictationView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ToolsCard: View {
    let tool: ToolsTool
    var badge: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IconTile(symbol: tool.symbol, colors: tool.colors, size: 46)
                    Spacer()
                    if let badge { StatusPill(text: badge, color: .green) }
                }
                Text(tool.title).font(.system(size: 16, weight: .semibold))
                Text(tool.blurb).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .card()
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(14).opacity(hover ? 1 : 0)
            }
            .scaleEffect(hover ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.smooth(duration: 0.18)) { hover = h } }
        // The grid is swapped out when a tool opens, so the hover-exit event never arrives.
        .onDisappear { hover = false }
    }
}
