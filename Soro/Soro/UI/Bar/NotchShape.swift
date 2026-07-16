import SwiftUI

/// The Dynamic-Island pill outline: SQUARE top corners (so the top edge stays
/// flush with the screen's physical top and the black body merges with the real
/// notch) and ROUNDED bottom corners (so the island looks like the notch grew
/// downward / sideways). Used both as the fill shape and the shadow caster.
struct NotchShape: Shape {
    /// Radius applied to the two bottom corners only.
    var bottomRadius: CGFloat = RecordingBarModel.bottomCornerRadius

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        // Start top-left (square), go clockwise.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))            // top edge
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))        // right edge
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), // bottom-right
                 radius: r, startAngle: .degrees(0), endAngle: .degrees(90),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))        // bottom edge
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), // bottom-left
                 radius: r, startAngle: .degrees(90), endAngle: .degrees(180),
                 clockwise: false)
        p.closeSubpath()                                              // left edge
        return p
    }
}

#if DEBUG
#Preview {
    NotchShape()
        .fill(.black)
        .frame(width: 360, height: 44)
        .padding()
        .background(.gray)
}
#endif
