// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import HaloCore

/// The Halo mark: a ring with a dot set inside it towards the upper right, like the indicator on a dial.
/// Drawn on a 24 pt grid, y down. With a battery level the ring becomes a track
/// and the level an arc over it, running clockwise from twelve o'clock as Apple's battery rings do and brightening
/// towards its end, the way the system's progress rings look. Monochrome as a template image; with a `tint`,
/// for a charging device, the whole mark takes that colour instead, so charging reads apart from running low.
enum StatusIcon {
    static let ringRadius: CGFloat = 7.0
    static let weight: CGFloat = 1.75

    static func make(level: Double? = nil, tint: NSColor? = nil, weight: CGFloat = weight, dot: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Called again for each appearance the image is drawn in, so a tint can suit a light or dark menu bar.
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = tint ?? .black
            func alpha(_ value: CGFloat) -> CGColor { ink.withAlphaComponent(value).cgColor }
            context.setLineWidth(weight)
            context.setLineCap(.round)
            let center = CGPoint(x: 12, y: 12)
            let ring = CGRect(x: 12 - ringRadius, y: 12 - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            func drawDot() -> Bool {
                guard dot else { return true }
                context.setFillColor(alpha(1))
                context.fillEllipse(in: CGRect(x: 12 + dotOffset * cos(dotAngle) - dotRadius, y: 12 + dotOffset * sin(dotAngle) - dotRadius,
                                               width: dotRadius * 2, height: dotRadius * 2))
                return true
            }
            if let level {
                // As the system's progress rings: one hue throughout, the track an opaque deeper (dark bar) or paler
                // (light bar) shade of it, and the level a stroke that brightens towards where it ends.
                let shade: (CGFloat) -> CGColor = { amount in
                    let base = ink.usingColorSpace(.sRGB) ?? ink
                    return (amount < 0 ? base.blended(withFraction: -amount, of: .black) : base.blended(withFraction: amount, of: .white))?.cgColor ?? base.cgColor
                }
                let track, from, to: CGColor
                if tint == nil {
                    (track, from, to) = (alpha(0.3), alpha(0.55), alpha(1))
                } else if dark {
                    (track, from, to) = (shade(-0.55), shade(-0.3), shade(0.1))
                } else {
                    (track, from, to) = (shade(0.72), shade(0.4), shade(0))
                }
                // Full is one solid ring: a gradient all the way round would meet itself at twelve with a seam.
                context.setStrokeColor(level >= 1 ? to : track)
                context.strokeEllipse(in: ring)
                guard level < 1 else { return drawDot() }
                let start = -CGFloat.pi / 2
                let sweep = 2 * .pi * CGFloat(min(1, max(0.04, level)))
                context.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: start + sweep, clockwise: false)
                context.replacePathWithStrokedPath()
                context.saveGState()
                context.clip()
                // The gradient turns with the arc; it begins a little before twelve so the start's round cap takes the
                // dimmest shade rather than wrapping round to the brightest.
                let lead: CGFloat = 0.25
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to, to] as CFArray,
                                          locations: [0, min(1, (sweep + lead) / (2 * .pi)), 1])!
                CGContextDrawConicGradient(context, gradient, center, start - lead)
                context.restoreGState()
            } else {
                context.setStrokeColor(alpha(1))
                context.strokeEllipse(in: ring)
            }
            return drawDot()
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "Halo"
        return image
    }
}

extension StatusIcon {
    static let dotAngle = -50 * CGFloat.pi / 180, dotOffset: CGFloat = 3.5, dotRadius: CGFloat = 1.7

    /// The mark's dot in red, for a device running low. A still layer over a dotless template image, since a template
    /// image takes one colour only; it is redrawn only when the reading changes, and never moves.
    final class Dot: CAShapeLayer {
        /// Puts the dot exactly where the image draws it, for the image laid out in `rect` of a view whose y axis
        /// points down when `flipped`, as a status bar button's does.
        func place(in rect: CGRect, flipped: Bool) {
            frame = rect
            let scale = rect.width / 24
            let x = (12 + dotOffset * cos(dotAngle)) * scale
            let yDown = (12 + dotOffset * sin(dotAngle)) * scale
            let center = CGPoint(x: x, y: flipped ? yDown : rect.height - yDown)
            let radius = dotRadius * scale
            path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        }
    }

    /// The colour a charging device gives the whole mark: red, orange or green by charge.
    static func color(charging percent: Int) -> NSColor {
        percent <= Battery.lowPercent ? .systemRed : percent <= 50 ? .systemOrange : .systemGreen
    }
}

enum Brand {
    static let name = "Halo"
    /// Where the source code and the license live.
    static let source = URL(string: "https://github.com/bayesianhunter/halo")!
    /// Where problems go in public, and where they go by mail for anyone without a GitHub account.
    static let issues = URL(string: "https://github.com/bayesianhunter/halo/issues/new")!
    static let feedbackEmail = "milky.eggy.app@gmail.com"
}
