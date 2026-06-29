import SwiftUI

/// A plain blurred poster backdrop for the inline player on the KSPlayer path, which can't vend live
/// frames. It never changes, so there's nothing to read as a jarring switch — it just fills the
/// status-bar strip and any letterbox gaps with a soft, matched still.
struct StaticBlurBackdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 32)
                    .clipped()
            }
        }
    }
}
