import SwiftUI

/// The colours of the mock-up (data/pond-design/board/app.html), from the captain's site.
extension Color {
    static let pondBackground = Color(red: 0xf4 / 255, green: 0xf1 / 255, blue: 0xea / 255)
    static let ink = Color(red: 0x1c / 255, green: 0x1b / 255, blue: 0x18 / 255)
    static let muted = Color(red: 0x5c / 255, green: 0x59 / 255, blue: 0x50 / 255)
    static let line = Color(red: 0xd8 / 255, green: 0xd2 / 255, blue: 0xc4 / 255)
    static let accent = Color(red: 0xc4 / 255, green: 0x61 / 255, blue: 0x3f / 255)
    static let card = Color(red: 0xfb / 255, green: 0xf9 / 255, blue: 0xf4 / 255)
}

/// One z-layer for each object kind. The CSS tokens of the mock-ups have the same values (docs/concepts.md, Z-layers).
enum Layer: Double {
    case content = 0, controls, sheet, toast
}

extension Font {
    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
}

/// The minimum tap target.
let tap: CGFloat = 44

/// A capsule button: `.primary` is ink, `.quiet` has a line border, `.pressed` is the accent of a fun mark.
struct PillStyle: ButtonStyle {
    enum Kind { case primary, quiet, chip, chipOn, fun, funOn }
    var kind: Kind
    var size: CGFloat = 17

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary, .chipOn: .ink
        case .funOn: .accent
        case .quiet: .clear
        case .chip, .fun: .card
        }
        let text: Color = switch kind {
        case .primary, .chipOn: .pondBackground
        case .funOn: .white
        default: .ink
        }
        let border: Color = switch kind {
        case .primary, .chipOn: .ink
        case .funOn: .accent
        default: .line
        }
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(text)
            .padding(.horizontal, kind == .fun || kind == .funOn ? 8 : 16)
            .frame(minWidth: tap, minHeight: tap)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Puts its views in rows, left to right, and starts a new row when a view does not fit: the "Every day" row.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(frames(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var point = CGPoint.zero
        var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if point.x > 0, point.x + size.width > width {
                point = CGPoint(x: 0, y: point.y + row + spacing)
                row = 0
            }
            frames.append(CGRect(origin: point, size: CGSize(width: min(size.width, width), height: size.height)))
            point.x += size.width + spacing
            row = max(row, size.height)
        }
        return frames
    }
}
