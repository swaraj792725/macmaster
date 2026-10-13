import SwiftUI
import AppKit
import QuickLookUI
import Observation

// MARK: - Toast

@Observable
@MainActor
final class ToolsToastCenter {
    static let shared = ToolsToastCenter()
    private(set) var message: String?
    private(set) var isError = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private init() {}

    func show(_ text: String, error: Bool = false) {
        task?.cancel()
        withAnimation(.smooth) { message = text; isError = error }
        task = Task {
            try? await Task.sleep(nanoseconds: (error ? 5_000_000_000 : 3_000_000_000))
            if !Task.isCancelled { withAnimation(.smooth) { message = nil } }
        }
    }
}

struct ToolsToastOverlay: View {
    private let center = ToolsToastCenter.shared
    var body: some View {
        VStack {
            Spacer()
            if let m = center.message {
                HStack(spacing: 8) {
                    Image(systemName: center.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(center.isError ? .orange : .green)
                    Text(m).font(.callout).lineLimit(3)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Helpers

enum ToolsPicker {
    @MainActor
    static func chooseFolder(start: URL?, message: String = "Choose a folder") -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = start
        p.message = message
        p.prompt = "Choose"
        return p.runModal() == .OK ? p.url : nil
    }
}

enum ToolsAdmin {
    /// Runs an admin command off the main thread (the system password prompt is shown by macOS).
    static func run(_ exe: String, _ args: [String], prompt: String) async -> Shell.Result {
        await Task.detached(priority: .userInitiated) { Shell.runAsAdmin(exe, args, prompt: prompt) }.value
    }

    /// Several shell commands under one password prompt.
    static func runScript(_ commands: [String], prompt: String) async -> Shell.Result {
        await run("/bin/sh", ["-c", commands.joined(separator: "; ")], prompt: prompt)
    }

    static func isCancelled(_ r: Shell.Result) -> Bool {
        r.stderr.contains("-128") || r.stderr.localizedCaseInsensitiveContains("cancel")
    }
}

/// Shared Quick Look panel driver.
@MainActor
final class ToolsQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ToolsQuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = existing
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

func toolsReveal(_ urls: [URL]) {
    let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
}

/// Reads a preference from another app's domain without spawning `defaults`.
func toolsReadPref(_ key: String, domain: String) -> Any? {
    CFPreferencesCopyAppValue(key as CFString, domain as CFString)
}

func toolsReadBool(_ key: String, domain: String, default d: Bool = false) -> Bool {
    switch toolsReadPref(key, domain: domain) {
    case let n as NSNumber: return n.boolValue
    case let s as String: return ["1", "yes", "true"].contains(s.lowercased())
    default: return d
    }
}

// MARK: - Shared small views

struct ToolsEmptyHint: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(36)
    }
}

enum ToolsFormat {
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
