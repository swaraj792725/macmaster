import SwiftUI

/// Sidebar page listing every permission MacMaster can use, with live status.
struct PermissionsView: View {
    @State private var model = PermissionsModel()

    private var allGranted: Bool { model.grantedCount == model.total }

    var body: some View {
        Page {
            PageHeader(title: "Permissions",
                       subtitle: "What MacMaster can access and why",
                       symbol: "lock.shield.fill", colors: Theme.Palette.blue) {
                Button {
                    model.recheck()
                } label: {
                    HStack(spacing: 6) {
                        if model.checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Re-check")
                    }
                }
                .buttonStyle(.mmSecondary)
                .disabled(model.checking)
            }

            summary

            menuBarRow.card().searchAnchor("perm.menuBar")

            VStack(spacing: Theme.spacing) {
                ForEach(Permission.allCases) { p in
                    PermissionsRow(permission: p, granted: model.isGranted(p), note: model.note(for: p)) { model.request(p) }
                        .card()
                        .searchAnchor("perm.\(p.rawValue)")
                }
            }

            Text("MacMaster never uploads anything. If a permission stays on Missing after you switch it on, quit and reopen MacMaster. If it still does not stick (for example after an update), remove MacMaster from the list in System Settings and add it again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// Not a privacy permission, but just as needed: macOS can keep every MacMaster icon out of the menu bar.
    private var menuBarRow: some View {
        let allowed = model.menuBarAllowed
        let ok = allowed != false
        return HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: SymbolKit.firstAvailable(["menubar.rectangle", "menubar.arrow.up.rectangle"]),
                     colors: allowed == true ? Theme.Palette.green : Theme.Palette.indigo, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Menu Bar").font(.system(size: 16, weight: .semibold))
                    StatusPill(text: allowed == nil ? "Checking" : ok ? "Allowed" : "Hidden by macOS",
                               color: allowed == nil ? Color.secondary : ok ? Color(hex: 0x30D158) : Color(hex: 0xFF453A))
                }
                Text(ok ? "macOS lets MacMaster's icons into the menu bar (System Settings › Menu Bar › Allow in the Menu Bar)."
                     : "MacMaster is switched off in System Settings › Menu Bar › Allow in the Menu Bar, so none of its menu bar icons show. Turn MacMaster on there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ok {
                Button("Open Settings", action: model.openMenuBarSettings).buttonStyle(.mmSecondary)
            } else {
                Button("Fix", action: model.openMenuBarSettings).buttonStyle(.mmPrimary)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill((allGranted ? Color(hex: 0x30D158) : Color(hex: 0xFF9F0A)).opacity(0.15))
                Image(systemName: allGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(allGranted ? Color(hex: 0x30D158) : Color(hex: 0xFF9F0A))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.grantedCount) of \(model.total) granted")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                CapsuleBar(fraction: Double(model.grantedCount) / Double(max(1, model.total)),
                           color: allGranted ? Color(hex: 0x30D158) : Theme.Palette.blue.last, height: 6)
                    .frame(maxWidth: 320)
                Text(allGranted ? "Everything is set up."
                     : model.isGranted(.accessibility) ? "Core features are ready. Optional permissions unlock the rest."
                     : "Grant Accessibility first. Most features need it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(kind: .glass, radius: Theme.Radius.hero)
    }
}
