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

            VStack(spacing: Theme.spacing) {
                ForEach(Permission.allCases) { p in
                    PermissionsRow(permission: p, granted: model.isGranted(p)) { model.request(p) }
                        .card()
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
