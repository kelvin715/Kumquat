import CoreGraphics
import Foundation

/// Layout of the radial wheel. All coordinates are y-down (SwiftUI / flipped NSView),
/// with angles measured clockwise from three o'clock and segment 0 centred at twelve o'clock.
public struct WheelGeometry: Sendable, Equatable {
    public enum Hit: Equatable, Sendable {
        case center
        case segment(Int)
        case outside
    }

    public let count: Int
    public let radius: CGFloat
    public let center: CGPoint

    public init(count: Int, radius: CGFloat, center: CGPoint) {
        self.count = max(0, count)
        self.radius = radius
        self.center = center
    }

    // Proportions measured from the reference design.
    public var rimWidth: CGFloat { max(2.5, radius * 0.035) }
    public var segmentOuterRadius: CGFloat { radius * 0.925 }
    public var segmentInnerRadius: CGFloat { radius * 0.43 }
    public var wellRadius: CGFloat { radius * 0.375 }
    public var gap: CGFloat { max(4, radius * 0.045) }
    public var labelRadius: CGFloat { (segmentInnerRadius + segmentOuterRadius) / 2 }

    public var cornerRadius: CGFloat {
        guard count > 1 else { return radius * 0.08 }
        // Keep the rounding smaller than half of the narrowest side of a segment.
        let innerArc = segmentInnerRadius * (2 * .pi / CGFloat(count)) - gap
        let depth = segmentOuterRadius - segmentInnerRadius
        return max(2, min(radius * 0.085, innerArc * 0.3, depth * 0.3))
    }

    public var step: CGFloat { count > 0 ? 2 * .pi / CGFloat(count) : 0 }

    public func centerAngle(of index: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) * step
    }

    public func point(radius r: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    public func labelCenter(of index: Int) -> CGPoint {
        point(radius: labelRadius, angle: centerAngle(of: index))
    }

    /// Which part of the wheel a point (in the same y-down space as `center`) is over.
    /// The gaps between segments and the outer rim count as the nearest segment,
    /// so a drop never falls "between" two formats.
    public func hitTest(_ p: CGPoint, outerTolerance: CGFloat = 10) -> Hit {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > radius + outerTolerance { return .outside }
        if distance < (wellRadius + segmentInnerRadius) / 2 || count == 0 { return .center }
        var angle = atan2(dy, dx) + .pi / 2
        while angle < 0 { angle += 2 * .pi }
        while angle >= 2 * .pi { angle -= 2 * .pi }
        let index = Int((angle / step).rounded()) % count
        return .segment(index)
    }

    /// Outline of one segment: an annular sector with an even gap to its neighbours
    /// and rounded corners.
    public func segmentPath(index: Int) -> CGPath {
        guard count > 0 else { return CGMutablePath() }
        let c = cornerRadius
        if count == 1 {
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: center.x - segmentOuterRadius, y: center.y - segmentOuterRadius,
                                       width: segmentOuterRadius * 2, height: segmentOuterRadius * 2))
            path.addEllipse(in: CGRect(x: center.x - segmentInnerRadius, y: center.y - segmentInnerRadius,
                                       width: segmentInnerRadius * 2, height: segmentInnerRadius * 2))
            return path
        }
        let mid = centerAngle(of: index)
        let start = mid - step / 2
        let end = mid + step / 2
        // Shrink by the corner radius, then grow back with round joins: this rounds the convex
        // corners while keeping the arcs exactly on the inner and outer radii.
        let core = sectorPath(innerRadius: segmentInnerRadius + c,
                              outerRadius: segmentOuterRadius - c,
                              startAngle: start, endAngle: end,
                              edgeInset: gap / 2 + c)
        guard !core.isEmpty else { return core }
        let ring = core.copy(strokingWithWidth: 2 * c, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return core.union(ring)
    }

    /// Sector bounded by two circles and two lines parallel to the radial edges,
    /// each pushed `edgeInset` towards the inside of the sector.
    func sectorPath(innerRadius ri: CGFloat, outerRadius ro: CGFloat,
                    startAngle a0: CGFloat, endAngle a1: CGFloat, edgeInset d: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard ri > d, ro > ri else { return path }
        let outerOffset = asin(min(1, d / ro))
        let innerOffset = asin(min(1, d / ri))
        let outerStart = a0 + outerOffset, outerEnd = a1 - outerOffset
        let innerStart = a0 + innerOffset, innerEnd = a1 - innerOffset
        guard outerEnd > outerStart, innerEnd > innerStart else { return path }

        let outerSteps = max(6, Int(((outerEnd - outerStart) / (.pi / 120)).rounded(.up)))
        path.move(to: point(radius: ro, angle: outerStart))
        for k in 1...outerSteps {
            let t = CGFloat(k) / CGFloat(outerSteps)
            path.addLine(to: point(radius: ro, angle: outerStart + (outerEnd - outerStart) * t))
        }
        let innerSteps = max(4, Int(((innerEnd - innerStart) / (.pi / 120)).rounded(.up)))
        path.addLine(to: point(radius: ri, angle: innerEnd))
        for k in 1...innerSteps {
            let t = CGFloat(k) / CGFloat(innerSteps)
            path.addLine(to: point(radius: ri, angle: innerEnd - (innerEnd - innerStart) * t))
        }
        path.closeSubpath()
        return path
    }
}
