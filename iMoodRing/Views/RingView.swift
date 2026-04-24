import SwiftUI

private enum Zone {
    static let glowMax:    CGFloat = 0.26
    static let ringInner:  CGFloat = 0.28
    static let ringOuter:  CGFloat = 0.84
    static let composite:  CGFloat = 0.87
}

private let lerpSpeed:    Double  = 0.04
private let travelTime:   Double  = 20.0   // seconds inner → outer
private let particleCount: Int    = 10

// MARK: - Particle

private struct Particle {
    var angle:              CGFloat  // position on ring (radians)
    var angularVelocity:    CGFloat  // rad/sec, signed
    var radialAmplitude:    CGFloat  // max px wobble from ring radius
    var radialPhase:        Double   // unique phase for sinusoidal offset
    var alphaPhase:         Double   // unique phase for alpha oscillation
    var size:               CGFloat  // pt diameter

    static func random() -> Particle {
        Particle(
            angle:           CGFloat.random(in: 0 ..< 2 * .pi),
            angularVelocity: CGFloat.random(in: -0.45 ... 0.45),
            radialAmplitude: CGFloat.random(in: 3 ... 9),
            radialPhase:     Double.random(in: 0 ..< 2 * .pi),
            alphaPhase:      Double.random(in: 0 ..< 2 * .pi),
            size:            CGFloat.random(in: 1.5 ... 3.5)
        )
    }

    mutating func tick(dt: Double) {
        angle += angularVelocity * CGFloat(dt)
    }

    func radialOffset(time: Double) -> CGFloat {
        radialAmplitude * CGFloat(sin(radialPhase + time * 1.6))
    }

    func alpha(time: Double) -> Double {
        0.2 + 0.55 * (0.5 + 0.5 * sin(alphaPhase + time * 2.4))
    }
}

// MARK: - Ring

private struct Ring {
    let mood:      Mood
    let baseRGB:   (r: Double, g: Double, b: Double)
    let intensity: Double
    var progress:  Double = 0          // 0 (inner) → 1 (absorbed)
    var particles: [Particle]

    init(mood: Mood, intensity: Double) {
        self.mood      = mood
        self.baseRGB   = mood.rgb
        self.intensity = intensity
        self.particles = (0 ..< particleCount).map { _ in Particle.random() }
    }

    mutating func tick(dt: Double) {
        progress += dt / travelTime
        for i in particles.indices { particles[i].tick(dt: dt) }
    }

    // alpha envelope: fade in from center, fade out toward absorption
    func alpha(at progress: Double) -> Double {
        let env = sin(progress * .pi)       // 0→1→0 over the journey
        return (0.35 + 0.55 * intensity) * max(0.1, env)
    }
}

// MARK: - RingSystem

final class RingSystem {
    private(set) var rings: [Ring] = []

    var compositeRGB:   (r: Double, g: Double, b: Double) = Mood.neutral.rgb
    var compositeCount: Int    = 0
    var compositeAlpha: Double = 0

    // Center glow (replaces RingAnimator)
    var currentGlowRGB:   (r: Double, g: Double, b: Double) = Mood.neutral.rgb
    var targetGlowRGB:    (r: Double, g: Double, b: Double) = Mood.neutral.rgb
    var currentIntensity: Double = 0.5
    var targetIntensity:  Double = 0.5

    private var time: Double = 0

    func addRing(mood: Mood, intensity: Double) {
        rings.append(Ring(mood: mood, intensity: intensity))
        targetGlowRGB   = mood.rgb
        targetIntensity = intensity
    }

    func tick(dt: Double) {
        time += dt

        currentGlowRGB = lerpRGB(currentGlowRGB, targetGlowRGB, t: lerpSpeed)
        currentIntensity += (targetIntensity - currentIntensity) * lerpSpeed

        for i in rings.indices { rings[i].tick(dt: dt) }

        // Absorb completed rings
        rings = rings.filter { ring in
            if ring.progress >= 1.0 {
                absorb(ring)
                return false
            }
            return true
        }
    }

    private func absorb(_ ring: Ring) {
        let n = Double(compositeCount)
        compositeRGB = (
            r: (compositeRGB.r * n + ring.baseRGB.r) / (n + 1),
            g: (compositeRGB.g * n + ring.baseRGB.g) / (n + 1),
            b: (compositeRGB.b * n + ring.baseRGB.b) / (n + 1)
        )
        compositeCount += 1
        compositeAlpha  = min(0.75, compositeAlpha + 0.09)
    }

    // Returns current wall-clock time for particle phase calcs
    var wallTime: Double { time }
}

// MARK: - RingView

struct RingView: UIViewRepresentable {
    let ringSystem: RingSystem

    func makeUIView(context: Context) -> RingCanvasView {
        let v = RingCanvasView()
        v.ringSystem = ringSystem
        return v
    }

    func updateUIView(_ uiView: RingCanvasView, context: Context) {}
}

// MARK: - RingCanvasView

final class RingCanvasView: UIView {
    var ringSystem: RingSystem?

    private var displayLink:    CADisplayLink?
    private var lastTimestamp:  CFTimeInterval = 0
    private var tapAdded:       Bool = false

    // Snapshot of ring radii for tap detection (rebuilt each frame)
    private var ringHits: [(mood: Mood, radius: CGFloat)] = []

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
        lastTimestamp = 0
    }

    @objc private func renderTick() {
        guard let dl = displayLink else { return }
        let now = dl.timestamp
        let dt  = lastTimestamp > 0 ? min(now - lastTimestamp, 0.05) : 0
        lastTimestamp = now
        ringSystem?.tick(dt: dt)
        setNeedsDisplay()
    }

    // MARK: - Tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let pt  = gesture.location(in: self)
        let cx  = bounds.midX
        let cy  = bounds.midY
        let R   = min(bounds.width, bounds.height) / 2 * 0.95
        let r   = sqrt((pt.x - cx) * (pt.x - cx) + (pt.y - cy) * (pt.y - cy))

        // Check composite ring first
        if let sys = ringSystem, sys.compositeAlpha > 0.05 {
            let cr = R * Zone.composite
            if abs(r - cr) < 16 {
                // Show averaged mood label — use composite color directly
                showColorLabel(rgb: sys.compositeRGB, text: "average")
                return
            }
        }

        let tolerance: CGFloat = 14
        if let hit = ringHits.min(by: { abs($0.radius - r) < abs($1.radius - r) }),
           abs(hit.radius - r) < tolerance {
            showMoodLabel(hit.mood)
        }
    }

    private weak var moodLabel: UILabel?

    private func showMoodLabel(_ mood: Mood) {
        showColorLabel(rgb: mood.rgb, text: mood.rawValue.uppercased())
    }

    private func showColorLabel(rgb: (r: Double, g: Double, b: Double), text: String) {
        moodLabel?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16, weight: .light)
        label.textColor = UIColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: 1)
        label.layer.shadowColor   = UIColor.black.cgColor
        label.layer.shadowOffset  = .zero
        label.layer.shadowRadius  = 6
        label.layer.shadowOpacity = 0.9
        label.layer.masksToBounds = false
        label.sizeToFit()
        label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        label.alpha  = 0
        addSubview(label)
        moodLabel = label
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.5, delay: 1.2, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ringHits.removeAll(keepingCapacity: true)

        let cx = rect.midX
        let cy = rect.midY
        let R  = min(rect.width, rect.height) / 2 * 0.95
        let t  = ringSystem?.wallTime ?? (displayLink?.timestamp ?? CACurrentMediaTime())

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(rect)

        guard let sys = ringSystem else { return }

        drawCompositeRing(ctx: ctx, cx: cx, cy: cy, R: R, sys: sys)
        drawActiveRings(ctx: ctx, cx: cx, cy: cy, R: R, sys: sys, t: t)
        drawCenterGlow(ctx: ctx, cx: cx, cy: cy, R: R, sys: sys, t: t)
    }

    // MARK: - Draw passes

    private func drawCompositeRing(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, sys: RingSystem) {
        guard sys.compositeAlpha > 0.01 else { return }
        let r     = R * Zone.composite
        let alpha = sys.compositeAlpha
        let rgb   = sys.compositeRGB
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22, color: uiColor(rgb, alpha: alpha * 0.6).cgColor)
        ctx.setStrokeColor(uiColor(rgb, alpha: alpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawActiveRings(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, sys: RingSystem, t: Double) {
        let innerR = R * Zone.ringInner
        let outerR = R * Zone.ringOuter
        let span   = outerR - innerR

        for ring in sys.rings {
            let r     = innerR + CGFloat(ring.progress) * span
            let alpha = ring.alpha(at: ring.progress)
            let rgb   = ring.baseRGB

            // Main ring
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: uiColor(rgb, alpha: alpha * 0.7).cgColor)
            ctx.setStrokeColor(uiColor(rgb, alpha: alpha).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.strokePath()
            ctx.restoreGState()

            ringHits.append((mood: ring.mood, radius: r))

            // Particles
            for particle in ring.particles {
                let pr      = r + particle.radialOffset(time: t)
                let px      = cx + pr * cos(particle.angle)
                let py      = cy + pr * sin(particle.angle)
                let palpha  = particle.alpha(time: t) * alpha
                let halfS   = particle.size / 2
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 7, color: uiColor(rgb, alpha: palpha * 0.8).cgColor)
                ctx.setFillColor(uiColor(rgb, alpha: palpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: px - halfS, y: py - halfS, width: particle.size, height: particle.size))
                ctx.restoreGState()
            }
        }
    }

    private func drawCenterGlow(ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat, sys: RingSystem, t: Double) {
        let i      = sys.currentIntensity
        let pulse  = 1 + 0.12 * i * sin(t * (2 + i * 3))
        let radius = R * Zone.glowMax * CGFloat(pulse)
        let rgb    = sys.currentGlowRGB

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [
            uiColor(rgb, alpha: 0.9).cgColor,
            uiColor(rgb, alpha: 0.9 * 0.44).cgColor,
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

    // MARK: - Helpers

    private func uiColor(_ rgb: (r: Double, g: Double, b: Double), alpha: Double) -> UIColor {
        UIColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: alpha)
    }
}
