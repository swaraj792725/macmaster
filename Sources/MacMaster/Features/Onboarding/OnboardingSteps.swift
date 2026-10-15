import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Shared bits

private struct OnboardingTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    @State private var appeared = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 8) {
                Text("Welcome to MacMaster")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Clean, monitor and supercharge your Mac. One native app instead of a dozen utilities.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .offset(y: appeared ? 0 : 12)
            .opacity(appeared ? 1 : 0)
            if !version.isEmpty {
                Text("Version \(version)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .onAppear { withAnimation(.smooth(duration: 0.6).delay(0.1)) { appeared = true } }
    }
}

// MARK: - Features

private struct OnboardingFeature: Identifiable {
    let id = UUID()
    let title: String, detail: String, symbol: String, colors: [Color]
}

struct OnboardingFeaturesStep: View {
    private let features: [OnboardingFeature] = [
        .init(title: "Uninstaller", detail: "Remove apps and every leftover", symbol: "trash.fill", colors: Theme.Palette.uninstaller),
        .init(title: "Cleaner", detail: "Reclaim space from caches and junk", symbol: "sparkles", colors: Theme.Palette.cleaner),
        .init(title: "Battery & Power", detail: "Health, charge and energy details", symbol: "bolt.fill", colors: Theme.Palette.battery),
        .init(title: "System Stats", detail: "Live CPU, memory, disk, network", symbol: "chart.xyaxis.line", colors: Theme.Palette.stats),
        .init(title: "Windows", detail: "Switcher with previews, tiling", symbol: "macwindow.on.rectangle", colors: Theme.Palette.windows),
        .init(title: "Mouse & Keyboard", detail: "Buttons, gestures, remaps", symbol: "computermouse.fill", colors: Theme.Palette.gray),
        .init(title: "Menu Bar", detail: "Hide, collapse, arrange icons", symbol: "menubar.rectangle", colors: Theme.Palette.indigo),
        .init(title: "Toolbox", detail: "Large files, duplicates, startup", symbol: "wrench.and.screwdriver.fill", colors: Theme.Palette.tools),
    ]
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            OnboardingTitle(title: "Everything in one place", subtitle: "Pick what you need. Everything else stays out of your way.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.element.id) { i, f in
                    VStack(spacing: 8) {
                        IconTile(symbol: f.symbol, colors: f.colors, size: 40)
                        Text(f.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(2)
                            .frame(height: 30, alignment: .top)
                    }
                    .padding(.vertical, 14).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .card(padding: 0, kind: .glass, radius: Theme.Radius.medium)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.smooth(duration: 0.45).delay(0.05 * Double(i)), value: appeared)
                }
            }
        }
        .padding(.top, 14)
        .onAppear { appeared = true }
    }
}

// MARK: - Permissions

struct OnboardingPermissionsStep: View {
    var model: PermissionsModel

    var body: some View {
        VStack(spacing: 14) {
            OnboardingTitle(title: "Allow a few things",
                            subtitle: "\(model.grantedCount) of \(model.total) granted. You can change any of these later from the Permissions page.")
                .contentTransition(.numericText())
            VStack(spacing: 8) {
                ForEach(Permission.allCases) { p in
                    PermissionsRow(permission: p, granted: model.isGranted(p), compact: true, note: model.note(for: p)) { model.request(p) }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .card(padding: 0, kind: .glass, radius: Theme.Radius.medium)
                }
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - Preferences

struct OnboardingPreferencesStep: View {
    @AppStorage("mm.app.hideDockIcon") private var hideDockIcon = false
    @AppStorage("mm.app.showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 18) {
            OnboardingTitle(title: "Make it yours", subtitle: "Choose how MacMaster lives on your Mac. You can change this anytime in Settings.")
            VStack(spacing: 0) {
                row("Launch at login", "Start MacMaster automatically when you sign in.", "power", Theme.Palette.green,
                    Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                HairlineDivider(leadingInset: 62)
                row("Show Dock icon", "Turn off to run from the menu bar only.", "dock.rectangle", Theme.Palette.gray,
                    Binding(get: { !hideDockIcon }, set: { show in
                        hideDockIcon = !show
                        if !show { showMenuBarIcon = true }   // keep a way back in
                    }))
                HairlineDivider(leadingInset: 62)
                row("Show menu bar icon", "Quick panel with live stats and shortcuts.", "menubar.rectangle", Theme.Palette.blue,
                    Binding(get: { showMenuBarIcon }, set: { show in
                        showMenuBarIcon = show
                        if !show { hideDockIcon = false }
                    }))
            }
            .card(padding: 0, kind: .glass, radius: Theme.Radius.card)
            .frame(maxWidth: 520)
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            } else if hideDockIcon {
                Text("MacMaster will live in the menu bar only.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 14)
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ colors: [Color], _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, colors: colors, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    var model: PermissionsModel
    var onReview: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Color(hex: 0x30D158).opacity(0.16)).frame(width: 112, height: 112)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white, Color(hex: 0x30D158))
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
            }
            OnboardingTitle(title: "You're all set",
                            subtitle: model.grantedCount == model.total
                            ? "Every permission is granted. Enjoy MacMaster."
                            : "\(model.total - model.grantedCount) permission\(model.total - model.grantedCount == 1 ? "" : "s") still missing. Some features stay off until you allow them.")
            if model.grantedCount < model.total {
                Button("Review Permissions", action: onReview)
                    .buttonStyle(.mmSecondary)
            }
            Spacer(minLength: 0)
        }
        .task { await model.refresh() }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.15)) { appeared = true } }
    }
}
