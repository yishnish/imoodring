import SwiftUI

// Ports ring.js zone constants verbatim
private enum Zone {
    static let glowMax:   CGFloat = 0.26
    static let innerMin:  CGFloat = 0.33
    static let innerMax:  CGFloat = 0.58
    static let outerMin:  CGFloat = 0.63
    static let outerMax:  CGFloat = 0.83
}

private let gapAngle: CGFloat = 0.012 * 2 * .pi
private let lerpSpeed: Double = 0.04

// Mutable animation state driven by CADisplayLink; not an Observable — mutated only on main thread.
final class RingAnimator {
    var currentRGB: (r: Double, g: Double, b: Double) = Mood.neutral.rgb
    var targetRGB:  (r: Double, g: Double, b: Double) = Mood.neutral.rgb
    var currentIntensity: Double = 0.5
    var targetIntensity:  Double = 0.5

    func setMood(_ mood: Mood, intensity: Double) {
        targetRGB       = mood.rgb
        targetIntensity = intensity
    }

    func tick() {
        currentRGB = lerpRGB(currentRGB, targetRGB, t: lerpSpeed)
        currentIntensity += (targetIntensity - currentIntensity) * lerpSpeed
    }
}

struct RingView: UIViewRepresentable {
    let history: MoodHistory
    let animator: RingAnimator
    var mode: RingMode = .proportional

    func makeUIView(context: Context) -> RingCanvasView {
        let v = RingCanvasView()
        v.history  = history
        v.animator = animator
        v.mode     = mode
        return v
    }

    func updateUIView(_ uiView: RingCanvasView, context: Context) {
        uiView.mode = mode
    }
}

enum RingMode { case proportional, chronological }

final class RingCanvasView: UIView {
    var history:  MoodHistory?
    var animator: RingAnimator?
    var mode: RingMode = .proportional

    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(frame))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame() {
        animator?.tick()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let anim = animator else { return }

        let t  = displayLink?.timestamp ?? CACurrentMediaTime()
        let cx = rect.midX
        let cy = rect.midY
        let R  = min(rect.width, rect.height) / 2 * 0.95

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(rect)

        guard let hist = history, !hist.isEmpty else {
            drawIdle(ctx: ctx, cx: cx, cy: cy, R: R, t: t)
            return
        }

        drawOuterRing(ctx: ctx, cx: cx, cy: cy, R: R, history: hist)
        drawInnerRing(ctx: ctx, cx: cx, cy: cy, R: R, recent: hist.recent)
        drawCenterGlow(ctx: ctx, cx: cx, cy: cy, R: R, anim: anim, t: t)
    }

    // MARK: - Draw passes

    private func drawIdle(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, t: Double) {
        let pulse  = 0.6 + 0.4 * sin(t * 0.8)
        let radius = R * Zone.glowMax * pulse
        radialGlow(ctx: ctx, cx: cx, cy: cy, radius: radius, rgb: (80, 80, 80), alpha: 0.15)
    }

    private func drawCenterGlow(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, anim: RingAnimator, t: Double) {
        let i      = anim.currentIntensity
        let pulse  = 1 + 0.12 * i * sin(t * (2 + i * 3))
        let radius = R * Zone.glowMax * pulse
        let rgb    = anim.currentRGB
        radialGlow(ctx: ctx, cx: cx, cy: cy, radius: radius, rgb: rgb, alpha: 0.9)
    }

    private func drawInnerRing(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, recent: [MoodChunk]) {
        guard !recent.isEmpty else { return }
        let rMid   = R * (Zone.innerMin + Zone.innerMax) / 2
        let rWidth = R * (Zone.innerMax - Zone.innerMin)
        let seg    = CGFloat.pi * 2 / CGFloat(max(recent.count, 1))
        let gap    = CGFloat(0.008) * 2 * .pi

        for (i, chunk) in recent.enumerated() {
            let start = -.pi / 2 + CGFloat(i) * seg + gap / 2
            let end   = -.pi / 2 + CGFloat(i + 1) * seg - gap / 2
            let alpha = 0.55 + 0.45 * chunk.intensity
            let blur  = 18.0 * chunk.intensity
            arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                from: start, to: end, rgb: chunk.mood.rgb, alpha: alpha, blur: blur)
        }
    }

    private func drawOuterRing(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, history: MoodHistory) {
        let rMid   = R * (Zone.outerMin + Zone.outerMax) / 2
        let rWidth = R * (Zone.outerMax - Zone.outerMin)

        switch mode {
        case .proportional:
            var angle: CGFloat = -.pi / 2
            for (mood, fraction) in history.proportions {
                let span  = CGFloat(fraction) * 2 * .pi
                let start = angle + gapAngle / 2
                let end   = angle + span - gapAngle / 2
                angle += span
                guard end > start else { continue }
                arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                    from: start, to: end, rgb: mood.rgb, alpha: 0.65, blur: 10)
            }

        case .chronological:
            let all = history.chunks
            guard !all.isEmpty else { return }
            let seg = CGFloat.pi * 2 / CGFloat(all.count)
            let gap = min(gapAngle, seg * 0.15)
            for (i, chunk) in all.enumerated() {
                let start = -.pi / 2 + CGFloat(i) * seg + gap / 2
                let end   = -.pi / 2 + CGFloat(i + 1) * seg - gap / 2
                guard end > start else { continue }
                let alpha = 0.4 + 0.3 * chunk.intensity
                arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                    from: start, to: end, rgb: chunk.mood.rgb, alpha: alpha, blur: 8)
            }
        }
    }

    // MARK: - Primitives

    private func radialGlow(ctx: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat,
                             rgb: (r: Double, g: Double, b: Double), alpha: Double) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [
            uiColor(rgb, alpha: alpha).cgColor,
            uiColor(rgb, alpha: alpha * 0.44).cgColor,
            uiColor(rgb, alpha: 0).cgColor,
        ]
        guard let gradient = CGGradient(colorsSpace: colorSpace,
                                         colors: colors as CFArray,
                                         locations: [0, 0.4, 1.0]) else { return }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        ctx.clip()
        ctx.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter:   CGPoint(x: cx, y: cy), endRadius: radius,
                               options: [])
        ctx.restoreGState()
    }

    private func arc(ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, w: CGFloat,
                     from: CGFloat, to: CGFloat,
                     rgb: (r: Double, g: Double, b: Double), alpha: Double, blur: Double) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: uiColor(rgb, alpha: 0.7).cgColor)
        ctx.setStrokeColor(uiColor(rgb, alpha: alpha).cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.butt)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: from, endAngle: to, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func uiColor(_ rgb: (r: Double, g: Double, b: Double), alpha: Double) -> UIColor {
        UIColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: alpha)
    }
}
