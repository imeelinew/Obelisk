import SwiftUI

/// Uses Yorune's AlbumDetailBackground blur and fade with Obelisk's icon blues
struct BookmarkPageBackground: View {
    let windowTransparencyEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            if !windowTransparencyEnabled {
                Color(nsColor: .textBackgroundColor)
            }

            GeometryReader { geometry in
                // Matches the gradient in Obelisk.icon/Assets/pyramid.fill 2.svg
                LinearGradient(
                    colors: [
                        Color(red: 63 / 255, green: 165 / 255, blue: 1),
                        Color(red: 0, green: 136 / 255, blue: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: geometry.size.width, height: min(440, geometry.size.height))
                .scaleEffect(1.15)
                .blur(radius: 70)
                .opacity(colorScheme == .dark ? 0.38 : 0.18)
                .mask {
                    LinearGradient(
                        colors: [.black, .black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
