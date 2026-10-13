import SwiftUI
import AppKit
import Observation

// MARK: - Formatting

enum PowerFmt {
    static func watts(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        return String(format: w >= 10 ? "%.0f W" : "%.1f W", abs(w))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }

    static func dayTime(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }
}

// MARK: - App icons

enum PowerIcons {
    /// Icon for a process: the running app's icon, else its enclosing .app bundle, else a generic one.
    static func icon(pid: Int32?, bundlePath: String?) -> NSImage {
        if let pid, let app = NSRunningApplication(processIdentifier: pid), let i = app.icon { return i }
        if let bundlePath { return NSWorkspace.shared.icon(forFile: bundlePath) }
        if let pid, let path = ProcessReader.path(of: pid) {
            if let b = PowerProcessControl.bundlePath(forExecutable: path) { return NSWorkspace.shared.icon(forFile: b) }
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

struct PowerAppIcon: View {
    let pid: Int32?
    var bundlePath: String? = nil
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: PowerIcons.icon(pid: pid, bundlePath: bundlePath))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Big action tile

struct PowerActionTile: View {
    let kind: PowerActionKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                IconTile(symbol: kind.symbol, colors: kind.colors, size: 46)
                VStack(spacing: 2) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    Text(kind.subtitle).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 8)
            .card(padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mmCard)
        .help(kind.subtitle)
    }
}

// MARK: - Chips

/// Selectable capsule chip (weekday picker, presets).
struct PowerChip: View {
    let title: String
    let selected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? tint : Color.primary.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: selected ? 0 : 0.5))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: selected)
    }
}

/// Small coloured note used for warnings.
struct PowerCallout: View {
    let symbol: String
    let title: String
    let message: String
    var color: Color = Color(hex: 0xFF9F0A)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SymbolKit.resolve(symbol))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(color.opacity(0.28), lineWidth: 0.5))
    }
}

// MARK: - Countdown ring

struct PowerCountdownRing: View {
    let pending: PowerPending
    var size: CGFloat = 190

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let f = pending.fractionRemaining
            let lw = size * 0.07
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: lw)
                Circle()
                    .trim(from: 0, to: max(0.002, f))
                    .stroke(AngularGradient(colors: pending.action.colors + [pending.action.colors.last ?? .accentColor],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(max(40, 360 * f))),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: f)
                VStack(spacing: 4) {
                    Image(systemName: SymbolKit.resolve(pending.action.symbol))
                        .font(.system(size: size * 0.11, weight: .semibold))
                        .foregroundStyle(pending.action.colors.last ?? .accentColor)
                    Text(PowerFmt.clock(pending.remaining))
                        .font(.system(size: size * 0.21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("until \(pending.action.title.lowercased()) · \(PowerFmt.time(pending.fireDate))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(lw * 1.5)
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pending.action.title) in \(PowerFmt.clock(pending.remaining))")
        }
    }
}
