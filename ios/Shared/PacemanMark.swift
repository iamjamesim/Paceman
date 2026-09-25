import SwiftUI

enum PacemanExpression {
    case neutral
    case needsInput
    case finished
}

/// One vector mark for iPhone and Mac. Coordinates match the cropped app icon.
struct PacemanMark: View {
    var expression: PacemanExpression = .neutral

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 720
            let crop = CGAffineTransform(translationX: -152, y: -167)
            let resize = CGAffineTransform(scaleX: scale, y: scale)
            Rectangle()
                .fill(.foreground)
                .mask {
                    ZStack {
                        Path { path in
                            path.addRoundedRect(in: CGRect(x: 232, y: 316, width: 560, height: 448),
                                                cornerSize: CGSize(width: 154, height: 154))
                            switch expression {
                            case .neutral:
                                for x in [404.0, 576.0] {
                                    path.addRoundedRect(in: CGRect(x: x, y: 481, width: 44, height: 98),
                                                        cornerSize: CGSize(width: 22, height: 22))
                                }
                            case .needsInput:
                                for center in [426.0, 598.0] {
                                    path.move(to: CGPoint(x: center - 61, y: 550))
                                    path.addLine(to: CGPoint(x: center, y: 481))
                                    path.addLine(to: CGPoint(x: center + 61, y: 550))
                                    path.addLine(to: CGPoint(x: center + 39, y: 572))
                                    path.addLine(to: CGPoint(x: center, y: 527))
                                    path.addLine(to: CGPoint(x: center - 39, y: 572))
                                    path.closeSubpath()
                                }
                            case .finished:
                                for center in [382.0, 642.0] {
                                    var eye = Path()
                                    eye.move(to: CGPoint(x: center - 65, y: 547))
                                    eye.addQuadCurve(to: CGPoint(x: center + 65, y: 547),
                                                     control: CGPoint(x: center, y: 424))
                                    path.addPath(eye.strokedPath(StrokeStyle(lineWidth: 31,
                                                                             lineCap: .round,
                                                                             lineJoin: .round)))
                                }
                            }
                        }
                        .applying(crop).applying(resize)
                        .fill(.white, style: FillStyle(eoFill: true))
                        Path { path in
                            path.addRect(CGRect(x: 498, y: 212, width: 28, height: 118))
                            path.addEllipse(in: CGRect(x: 479, y: 179, width: 66, height: 66))
                            for x in [162.0, 818.0] {
                                path.addRoundedRect(in: CGRect(x: x, y: 481, width: 44, height: 98),
                                                    cornerSize: CGSize(width: 22, height: 22))
                            }
                        }
                        .applying(crop).applying(resize)
                        .fill(.white)
                    }
                }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
