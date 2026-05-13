import AppKit
import SwiftUI

/// Menu bar popover notification shown after a silent bookmark add.
///
/// Three visual styles, all sharing the same layout — distinction is purely
/// through the left-hand icon and its restrained gradient colour:
/// - **Success** (normal bookmark): green gradient checkmark
/// - **Hidden** (hidden bookmark): muted gray eye-slash
/// - **Error** (duplicate / no URL / etc.): red gradient x-mark
@MainActor
struct BookmarkAddedNotificationView: View {
    let title: String
    let subtitle: String
    let kind: Kind

    enum Kind {
        case success
        case hidden
        case error
    }

    private var iconName: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .hidden:  "eye.slash.circle.fill"
        case .error:   "xmark.circle.fill"
        }
    }

    /// Subtle top-to-bottom gradients so the icons feel premium without
    /// screaming for attention.
    private var iconGradient: LinearGradient {
        switch kind {
        case .success:
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.78, blue: 0.35),
                    Color(red: 0.12, green: 0.64, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .hidden:
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.42),
                    Color.primary.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .error:
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.27, blue: 0.22),
                    Color(red: 0.82, green: 0.18, blue: 0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(iconGradient)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
    }
}
