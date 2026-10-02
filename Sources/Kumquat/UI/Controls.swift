import SwiftUI

/// Set while rendering screenshots off-screen, where AppKit-backed controls can't draw.
@MainActor
enum RenderContext {
    static var isOffscreen = false
}

/// Segmented control: a translucent track with the selected item as an orange chip.
struct OrangeSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.value == selection
                if index > 0 {
                    Rectangle()
                        .fill(Theme.inkSecondary.opacity(selected || options[index - 1].value == selection ? 0 : 0.25))
                        .frame(width: 1, height: 12)
                }
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minWidth: 34, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? AnyShapeStyle(Theme.segmentHover) : AnyShapeStyle(Color.clear))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.trackFill))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// Labelled slider with an orange filled track and a value readout.
struct OrangeSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "px"
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var onEditingEnded: () -> Void = {}

    @State private var dragging = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = range.upperBound > range.lowerBound
                    ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
                let x = CGFloat(min(max(fraction, 0), 1)) * (width - 16) + 8
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.55)).frame(height: 4)
                    Capsule().fill(Theme.segmentHover).frame(width: x, height: 4)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: 16, height: 16)
                        .scaleEffect(dragging ? 1.12 : 1)
                        .offset(x: x - 8)
                }
                .frame(height: 18)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let f = Double(min(max((g.location.x - 8) / max(width - 16, 1), 0), 1))
                            value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in
                            dragging = false
                            onEditingEnded()
                        }
                )
            }
            .frame(height: 18)
            Text(unit.isEmpty ? format(value) : "\(format(value)) \(unit)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.segmentHover))
            .shadow(color: Theme.tangerineDeep.opacity(0.35), radius: 3, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.5 : 0.35)))
    }
}

/// Small square swatch for background presets and colours.
struct Swatch<Fill: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var fill: Fill

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Theme.tangerine : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Numeric text field styled like the reference (white rounded box).
struct PixelField: View {
    let label: String
    @Binding var value: Int
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            Group {
                if RenderContext.isOffscreen {
                    Text(verbatim: String(value)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", value: $value, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .onSubmit(onCommit)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .frame(width: 64, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
        }
    }
}

/// Section label used down the left side of the tool windows.
struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink)
            .frame(width: 76, alignment: .leading)
    }
}
