import SwiftUI

struct IntelligenceSymbolIcon: View {
    nonisolated static let symbolName = "siri"

    let size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: Self.symbolName)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        SIMD2<Float>(0.0, 0.0),
                        SIMD2<Float>(0.5, 0.0),
                        SIMD2<Float>(1.0, 0.0),
                        SIMD2<Float>(0.0, 0.72),
                        SIMD2<Float>(0.5, 0.70),
                        SIMD2<Float>(1.0, 0.72),
                        SIMD2<Float>(0.0, 1.0),
                        SIMD2<Float>(0.5, 1.0),
                        SIMD2<Float>(1.0, 1.0)
                    ],
                    colors: [
                        Color(red: 0.02, green: 0.09, blue: 0.12),
                        Color(red: 0.02, green: 0.09, blue: 0.12),
                        Color(red: 0.03, green: 0.10, blue: 0.14),
                        Color(red: 0.10, green: 0.13, blue: 0.14),
                        Color(red: 0.12, green: 0.23, blue: 0.24),
                        Color(red: 0.12, green: 0.24, blue: 0.32),
                        Color(red: 0.96, green: 0.82, blue: 0.48),
                        Color(red: 0.56, green: 0.86, blue: 0.82),
                        Color(red: 0.42, green: 0.62, blue: 0.90)
                    ]
                )
            )
            .accessibilityHidden(true)
    }
}

struct IntelligenceSymbolLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IntelligenceSymbolIcon(size: 14)
        }
    }
}
