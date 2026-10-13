import SwiftUI

/// Settings page for the Drop Shelf.
struct DropShelfView: View {
    @Bindable private var settings = DropShelfSettings.shared

    var body: some View {
        Page {
            PageHeader(title: "Drop Shelf",
                       subtitle: "Park files while you drag, then drop them anywhere",
                       symbol: "tray.and.arrow.down.fill", colors: Theme.Palette.mint) {
                Button("Open shelf now") { DropShelf.shared.openNow() }
                    .buttonStyle(.mmPrimary)
            }

            GroupedSection(footer: "Drag a file and shake the mouse side to side, or push it against the chosen screen edge, and the shelf appears. Items are only references; files are never copied or moved unless you use Move to… or Copy to….") {
                SettingsRow(title: "Enable Drop Shelf", subtitle: "Watch for file drags system-wide",
                            symbol: "tray.full.fill", colors: Theme.Palette.mint) {
                    Toggle("", isOn: $settings.enabled).labelsHidden().toggleStyle(.switch)
                }
            }

            GroupedSection("Open the shelf") {
                SettingsRow(title: "Shake to open", subtitle: "Wiggle a dragged file left and right",
                            symbol: "hand.draw.fill", colors: Theme.Palette.blue) {
                    Toggle("", isOn: $settings.shakeToOpen).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Screen edge hot zone", subtitle: "Drag a file to the edge of the screen",
                            symbol: "rectangle.lefthalf.inset.filled.arrow.left", colors: Theme.Palette.indigo) {
                    Picker("", selection: $settings.edge) {
                        ForEach(DropShelfEdge.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
            .disabled(!settings.enabled)

            GroupedSection("Behavior") {
                SettingsRow(title: "Close when empty", subtitle: "Hide the shelf after the last item is dragged out",
                            symbol: "eye.slash.fill", colors: Theme.Palette.orange) {
                    Toggle("", isOn: $settings.autoCloseWhenEmpty).labelsHidden().toggleStyle(.switch)
                }
            }
            .disabled(!settings.enabled)
        }
    }
}
