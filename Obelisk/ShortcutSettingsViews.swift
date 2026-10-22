import KeyboardShortcuts
import SwiftUI

struct ShortcutRecorderRow: View {
    let title: LocalizedStringKey
    var description: LocalizedStringKey?
    let name: KeyboardShortcuts.Name

    var body: some View {
        LabeledContent {
            KeyboardShortcuts.Recorder(for: name) { _ in
                // Only the containing app owns global registrations
                KeyboardShortcuts.disable(name)
                Task { await UIRuntime.shared.flush() }
            }
        } label: {
            if let description {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(title)
            }
        }
    }
}
