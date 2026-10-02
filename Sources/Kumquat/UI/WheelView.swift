import KumquatCore
import SwiftUI

struct WheelItem: Identifiable, Equatable {
    let action: WheelAction
    let title: String
    let symbol: String?
    var id: String { "\(action)" }
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var isPresented = false
    @Published var mode: WheelMode = .formats
    /// Shown in the centre pill while nothing is hovered (file size or file count).
    @Published var idleText = ""
    @Published var diameter: CGFloat = 260
    /// Briefly set to the chosen segment when a file is dropped.
    @Published var chosen: Int?

    var centerText: String {
        if let hovered, items.indices.contains(hovered) { return items[hovered].title }
        return idleText
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let d = model.diameter
        let geometry = WheelGeometry(count: model.items.count, radius: d / 2, center: CGPoint(x: d / 2, y: d / 2))
        ZStack {
            disc(geometry)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                segment(index: index, item: item, geometry: geometry)
            }
            well(geometry)
        }
        .frame(width: d, height: d)
        .scaleEffect(model.isPresented ? 1 : 0.55)
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: model.isPresented)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.items)
    }

    private func disc(_ g: WheelGeometry) -> some View {
        ZStack {
            Circle()
                .fill(Theme.discFill)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
            Circle()
                .strokeBorder(Theme.rim, lineWidth: g.rimWidth)
            Circle()
                .inset(by: g.rimWidth)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
        }
    }

    private func segment(index: Int, item: WheelItem, geometry g: WheelGeometry) -> some View {
        let isHovered = model.hovered == index
        let isChosen = model.chosen == index
        let path = Path(g.segmentPath(index: index))
        let label = g.labelCenter(of: index)
        let manySegments = g.count >= 8
        return ZStack {
            path.fill(isHovered || isChosen ? AnyShapeStyle(Theme.segmentHover) : AnyShapeStyle(Theme.segmentFill))
            path.stroke(Color.white.opacity(isHovered ? 0.55 : 0.6), lineWidth: 0.75)
            Group {
                if let symbol = item.symbol {
                    VStack(spacing: 3) {
                        Image(systemName: symbol)
                            .font(.system(size: manySegments ? 12 : 14, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: manySegments ? 7.5 : 8.5, weight: .heavy))
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: g.radius * 0.5)
                } else {
                    Text(item.title)
                        .font(.system(size: manySegments ? 12 : 13.5, weight: .heavy))
                        .tracking(0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: g.radius * 0.42)
                }
            }
            .foregroundStyle(isHovered || isChosen ? Color.white : Theme.ink)
            .position(label)
        }
        .frame(width: g.radius * 2, height: g.radius * 2)
        .scaleEffect(isHovered ? 1.035 : 1, anchor: .center)
        .shadow(color: isHovered ? Theme.tangerine.opacity(0.45) : .clear, radius: 8)
        .zIndex(isHovered ? 1 : 0)
    }

    private func well(_ g: WheelGeometry) -> some View {
        let r = g.wellRadius
        return ZStack {
            Circle()
                .fill(Theme.well)
                .frame(width: r * 2, height: r * 2)
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.7), Theme.hex(0xFFD9A6, 0.35), Theme.hex(0xB9601F, 0.45)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(2, g.radius * 0.022))
                .frame(width: r * 2, height: r * 2)
            Capsule()
                .fill(Theme.pill)
                .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.75))
                .shadow(color: Theme.hex(0x9C4510, 0.35), radius: 3, y: 1.5)
                .frame(width: g.radius * 0.6, height: g.radius * 0.25)
            Text(model.centerText)
                .font(.system(size: g.radius * 0.088, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: g.radius * 0.54)
                .id(model.centerText)
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }
}
