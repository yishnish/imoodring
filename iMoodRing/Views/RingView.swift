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

private struct ArcHit {
    let mood: Mood
    let startAngle: CGFloat
    let endAngle: CGFloat
    let rMin: CGFloat
    let rMax: CGFloat
}

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
    private var tapAdded = false
    private var arcHits: [ArcHit] = []
    private weak var moodLabel: UILabel?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startLink()
            if !tapAdded {
                addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
                tapAdded = true
            }
        } else {
            stopLink()
        }
    }

    private func startLink() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(renderTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func renderTick() {
        animator?.tick()
        setNeedsDisplay()
    }

    // MARK: - Tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        let cx = bounds.midX
        let cy = bounds.midY
        let dx = pt.x - cx
        let dy = pt.y - cy
        let r  = sqrt(dx * dx + dy * dy)

        // atan2 returns angle from x-axis in [-π, π].
        // Shift to [-π/2, 3π/2] so it aligns with our arc convention (start = -π/2, clockwise).
        var angle = atan2(dy, dx)
        if angle < -.pi / 2 { angle += 2 * .pi }

        for hit in arcHits where r >= hit.rMin && r <= hit.rMax {
            if angle >= hit.startAngle && angle <= hit.endAngle {
                showMoodLabel(hit.mood)
                return
            }
        }
    }

    private func showMoodLabel(_ mood: Mood) {
        moodLabel?.removeFromSuperview()

        let (r, g, b) = mood.rgb
        let label = UILabel()
        label.text = mood.rawValue.uppercased()
        label.font = .systemFont(ofSize: 16, weight: .light)
        label.letterSpacing(2.5)
        label.textColor = UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = .zero
        label.layer.shadowRadius = 6
        label.layer.shadowOpacity = 0.8
        label.layer.masksToBounds = false
        label.sizeToFit()
        label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        label.alpha = 0
        addSubview(label)
        moodLabel = label

        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.5, delay: 1.2, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let anim = animator else { return }

        arcHits.removeAll(keepingCapacity: true)

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
        let rMin   = rMid - rWidth / 2
        let rMax   = rMid + rWidth / 2
        let seg    = CGFloat.pi * 2 / CGFloat(max(recent.count, 1))
        let gap    = CGFloat(0.008) * 2 * .pi

        for (i, chunk) in recent.enumerated() {
            let hitStart  = -.pi / 2 + CGFloat(i) * seg
            let hitEnd    = -.pi / 2 + CGFloat(i + 1) * seg
            let drawStart = hitStart + gap / 2
            let drawEnd   = hitEnd   - gap / 2
            let alpha = 0.55 + 0.45 * chunk.intensity
            let blur  = 18.0 * chunk.intensity
            arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                from: drawStart, to: drawEnd, rgb: chunk.mood.rgb, alpha: alpha, blur: blur)
            arcHits.append(ArcHit(mood: chunk.mood, startAngle: hitStart, endAngle: hitEnd, rMin: rMin, rMax: rMax))
        }
    }

    private func drawOuterRing(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, history: MoodHistory) {
        let rMid   = R * (Zone.outerMin + Zone.outerMax) / 2
        let rWidth = R * (Zone.outerMax - Zone.outerMin)
        let rMin   = rMid - rWidth / 2
        let rMax   = rMid + rWidth / 2

        switch mode {
        case .proportional:
            var angle: CGFloat = -.pi / 2
            for (mood, fraction) in history.proportions {
                let span      = CGFloat(fraction) * 2 * .pi
                let hitStart  = angle
                let hitEnd    = angle + span
                let drawStart = hitStart + gapAngle / 2
                let drawEnd   = hitEnd   - gapAngle / 2
                angle += span
                guard drawEnd > drawStart else { continue }
                arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                    from: drawStart, to: drawEnd, rgb: mood.rgb, alpha: 0.65, blur: 10)
                arcHits.append(ArcHit(mood: mood, startAngle: hitStart, endAngle: hitEnd, rMin: rMin, rMax: rMax))
            }

        case .chronological:
            let all = history.chunks
            guard !all.isEmpty else { return }
            let seg = CGFloat.pi * 2 / CGFloat(all.count)
            let gap = min(gapAngle, seg * 0.15)
            for (i, chunk) in all.enumerated() {
                let hitStart  = -.pi / 2 + CGFloat(i) * seg
                let hitEnd    = -.pi / 2 + CGFloat(i + 1) * seg
                let drawStart = hitStart + gap / 2
                let drawEnd   = hitEnd   - gap / 2
                guard drawEnd > drawStart else { continue }
                let alpha = 0.4 + 0.3 * chunk.intensity
                arc(ctx: ctx, cx: cx, cy: cy, r: rMid, w: rWidth,
                    from: drawStart, to: drawEnd, rgb: chunk.mood.rgb, alpha: alpha, blur: 8)
                arcHits.append(ArcHit(mood: chunk.mood, startAngle: hitStart, endAngle: hitEnd, rMin: rMin, rMax: rMax))
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

private extension UILabel {
    func letterSpacing(_ spacing: CGFloat) {
        guard let text else { return }
        attributedText = NSAttributedString(string: text, attributes: [.kern: spacing])
    }
}
