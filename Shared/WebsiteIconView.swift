import AppKit
import SwiftUI
import WidgetKit

/// Gives website artwork and imported app icons the same continuous silhouette.
/// The source image is left intact; only its displayed outline is masked.
struct WebsiteIconView: View {
    let image: NSImage
    let size: CGFloat

    private var displayedSize: CGFloat { size * 0.88 }

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(width: displayedSize, height: displayedSize)
            .clipShape(RoundedRectangle(cornerRadius: displayedSize * 0.22, style: .continuous))
            .frame(width: size, height: size)
    }
}
