import KeyboardShortcuts
import SwiftUI

struct ShortcutRecorderRow: View {
    let title: String
    var description: String?
    let name: KeyboardShortcuts.Name

    var body: some View {
        LabeledContent {
            KeyboardShortcuts.Recorder(for: name)
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
