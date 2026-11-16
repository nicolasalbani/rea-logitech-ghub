import SwiftUI

enum Theme {
    static let accent = Color(red: 0.0, green: 0.71, blue: 1.0)
    static let background = Color(red: 0.07, green: 0.075, blue: 0.085)
    static let card = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let cardHover = Color(red: 0.15, green: 0.155, blue: 0.17)
    static let stroke = Color.white.opacity(0.07)
    static let secondaryText = Color.white.opacity(0.55)
}

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: UInt8(clamping: Int((ns.redComponent * 255).rounded())),
                  g: UInt8(clamping: Int((ns.greenComponent * 255).rounded())),
                  b: UInt8(clamping: Int((ns.blueComponent * 255).rounded())))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(1.2)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText) }
        }
    }
}

/// A labeled horizontal slider for an integer value with a live readout.
struct ValueSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var format: (Int) -> String = { "\($0)" }
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(format(value)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int(($0 / Double(step)).rounded()) * step }),
                in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)))
            .tint(Theme.accent)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// A vertical slider used for equalizer bands.
struct VerticalSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var height: CGFloat = 180

    var body: some View {
        GeometryReader { geo in
            let span = Double(range.upperBound - range.lowerBound)
            let fraction = (Double(value - range.lowerBound) / span)
            let zeroFraction = Double(0 - range.lowerBound) / span
            let y = geo.size.height * (1 - fraction)
            let zeroY = geo.size.height * (1 - zeroFraction)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 6)
                Rectangle().fill(Theme.accent)
                    .frame(width: 6, height: abs(zeroY - y))
                    .offset(y: min(zeroY, y))
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 16, height: 1).offset(y: zeroY)
                Circle().fill(.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(y: y - 8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - min(1, max(0, g.location.y / geo.size.height))
                value = range.lowerBound + Int((f * span).rounded())
            })
        }
        .frame(width: 34, height: height)
    }
}

/// Stylized G560 artwork whose glow follows the live lighting zones.
struct SpeakerArt: View {
    var zoneColors: [Color]
    var size: CGFloat = 120

    private func zone(_ i: Int) -> Color {
        guard !zoneColors.isEmpty else { return .clear }
        return zoneColors[min(i, zoneColors.count - 1)]
    }

    var body: some View {
        HStack(spacing: size * 0.12) {
            speaker(front: zone(0), back: zone(2), mirrored: false)
            speaker(front: zone(1), back: zone(3), mirrored: true)
        }
        .frame(height: size)
    }

    private func speaker(front: Color, back: Color, mirrored: Bool) -> some View {
        ZStack {
            Ellipse().fill(back.opacity(0.55)).blur(radius: size * 0.16)
                .frame(width: size * 0.7, height: size * 0.6).offset(y: -size * 0.08)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.62, height: size * 0.72)
                .rotationEffect(.degrees(mirrored ? 12 : -12))
                .overlay(
                    Circle().fill(Color(white: 0.03))
                        .overlay(Circle().stroke(Color(white: 0.18), lineWidth: 1))
                        .frame(width: size * 0.34)
                        .rotationEffect(.degrees(mirrored ? 12 : -12)))
            Capsule().fill(front).frame(width: size * 0.42, height: size * 0.03)
                .shadow(color: front, radius: size * 0.06)
                .offset(y: size * 0.36)
        }
        .frame(width: size * 0.78, height: size)
    }
}

struct CameraArt: View {
    var size: CGFloat = 120
    var body: some View {
        ZStack {
            Capsule().fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 1.5, height: size * 0.52)
            Circle().fill(Color(white: 0.02)).frame(width: size * 0.38)
                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 2))
                .overlay(Circle().fill(Theme.accent.opacity(0.35)).frame(width: size * 0.12).blur(radius: 2))
            HStack {
                Circle().fill(Color(white: 0.45)).frame(width: size * 0.05)
                Spacer()
                Circle().fill(Color(white: 0.45)).frame(width: size * 0.05)
            }.frame(width: size * 0.8)
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.1)).frame(width: size * 0.4, height: size * 0.12)
                .offset(y: size * 0.36)
        }
        .frame(height: size)
    }
}

struct StatusDot: View {
    var ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
