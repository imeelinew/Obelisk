import AppKit
import SwiftUI

/// Menu bar popover notification shown after a silent bookmark add.
///
/// Four visual styles, all sharing the same layout — distinction is purely
/// through the left-hand icon and its restrained gradient colour:
/// - **Success** (normal bookmark): green gradient checkmark
/// - **Hidden** (hidden bookmark): muted gray eye-slash
/// - **Undo** (reverted add): blue-purple undo arrow
/// - **Intelligence** (automatic title optimization): Intelligence gradient icon
/// - **Error** (duplicate / no URL / etc.): red gradient x-mark
@MainActor
struct BookmarkAddedNotificationView: View {
    let title: String
    let subtitle: String
    let kind: Kind

    enum Kind {
        case success
        case hidden
        case undo
        case intelligence
        case error
    }

    private var iconName: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .hidden:  "eye.slash.circle.fill"
        case .undo:    "arrow.uturn.backward.circle.fill"
        case .intelligence: "apple.intelligence"
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
        case .undo:
            LinearGradient(
                colors: [
                    Color(red: 0.38, green: 0.48, blue: 0.96),
                    Color(red: 0.46, green: 0.30, blue: 0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .intelligence:
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.78, blue: 0.25),
                    Color(red: 1.0, green: 0.20, blue: 0.28),
                    Color(red: 0.54, green: 0.28, blue: 0.96),
                    Color(red: 0.22, green: 0.66, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
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
            iconView

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

    @ViewBuilder
    private var iconView: some View {
        if kind == .intelligence {
            ZStack {
                Circle()
                    .fill(iconGradient)
                    .overlay {
                        intelligenceGlow
                            .clipShape(Circle())
                    }

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(iconGradient)
                .frame(width: 32, height: 32)
        }
    }

    private var intelligenceGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.70, green: 0.90, blue: 0.72).opacity(0.96),
                        Color(red: 0.70, green: 0.90, blue: 0.72).opacity(0.0)
                    ],
                    center: UnitPoint(x: 0.28, y: 0.55),
                    startRadius: 0,
                    endRadius: 22
                )
            )
            .overlay {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.18, blue: 0.36).opacity(0.78),
                                Color(red: 1.0, green: 0.18, blue: 0.36).opacity(0.0)
                            ],
                            center: UnitPoint(x: 0.82, y: 0.18),
                            startRadius: 0,
                            endRadius: 20
                        )
                    )
            }
            .overlay {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.24, green: 0.66, blue: 1.0).opacity(0.78),
                                Color(red: 0.24, green: 0.66, blue: 1.0).opacity(0.0)
                            ],
                            center: UnitPoint(x: 0.14, y: 0.92),
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
            }
    }
}
