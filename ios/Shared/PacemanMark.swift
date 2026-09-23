import SwiftUI

/// One vector mark for iPhone and Mac. Coordinates match the cropped app icon.
struct PacemanMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 720
            let crop = CGAffineTransform(translationX: -152, y: -167)
            let resize = CGAffineTransform(scaleX: scale, y: scale)
            ZStack {
                Path(roundedRect: CGRect(x: 232, y: 316, width: 560, height: 448), cornerRadius: 154)
                    .applying(crop).applying(resize)
                    .stroke(style: StrokeStyle(lineWidth: 28 * scale))
                Path { path in
                    for x in [404.0, 576.0] {
                        path.addRoundedRect(in: CGRect(x: x, y: 481, width: 44, height: 98),
                                            cornerSize: CGSize(width: 22, height: 22))
                    }
                    path.addRoundedRect(in: CGRect(x: 498, y: 233, width: 28, height: 83),
                                        cornerSize: CGSize(width: 14, height: 14))
                    path.addEllipse(in: CGRect(x: 479, y: 179, width: 66, height: 66))
                    for x in [168.0, 824.0] {
                        path.addRoundedRect(in: CGRect(x: x, y: 483, width: 32, height: 115),
                                            cornerSize: CGSize(width: 16, height: 16))
                    }
                }.applying(crop).applying(resize)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
