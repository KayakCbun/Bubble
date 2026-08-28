import AppKit
import QuartzCore
import SwiftUI

enum OverlayMotion {
    static let snappy = Animation.spring(
        response: OverlaySpring.snappyResponse,
        dampingFraction: OverlaySpring.snappyDamping,
        blendDuration: 0
    )
    static let panel = Animation.spring(
        response: OverlaySpring.panelResponse,
        dampingFraction: OverlaySpring.panelDamping,
        blendDuration: 0
    )
    static let quick = Animation.spring(
        response: OverlaySpring.quickResponse,
        dampingFraction: OverlaySpring.quickDamping,
        blendDuration: 0
    )
    /// Height-only composer chrome. Ease-out avoids spring overshoot that would
    /// bounce the transcript viewport on every quote/attachment attach.
    static let composer = Animation.easeOut(duration: 0.16)
    static let scroll = Animation.spring(response: 0.28, dampingFraction: 0.96, blendDuration: 0)
    static let sideStageReveal = Animation.easeOut(duration: SideStageChromePolicy.revealDuration)
    static let sideStageHide = Animation.easeIn(duration: SideStageChromePolicy.hideDuration)
    static let sideStageContent = Animation.easeOut(duration: 0.12)

    static var frameRate: CAFrameRateRange {
        CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }
}

final class OverlayPulse: NSObject {
    static let shared = OverlayPulse()

    private var link: CADisplayLink?
    private var jobs: [() -> Void] = []

    func onNextFrame(_ job: @escaping () -> Void) {
        jobs.append(job)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard link == nil else { return }
        let window = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible })
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first
        guard let window else {
            let pending = jobs
            jobs.removeAll()
            pending.forEach { $0() }
            return
        }
        let link = window.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let pending = jobs
        jobs.removeAll()
        pending.forEach { $0() }
        if jobs.isEmpty {
            link.invalidate()
            self.link = nil
        }
    }
}

final class OverlayFrameAnimator: NSObject {
    private weak var panel: NSPanel?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var w: CGFloat = 0
    private var h: CGFloat = 0
    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var vw: CGFloat = 0
    private var vh: CGFloat = 0
    private var tx: CGFloat = 0
    private var ty: CGFloat = 0
    private var tw: CGFloat = 0
    private var th: CGFloat = 0
    private var alpha: CGFloat = 1
    private var alphaVelocity: CGFloat = 0
    private var alphaTarget: CGFloat = 1

    var isAnimating: Bool { link != nil }
    var onProgress: ((_ frame: NSRect, _ alpha: CGFloat) -> Void)?
    var onSettled: (() -> Void)?

    func attach(_ panel: NSPanel) {
        self.panel = panel
        syncFromPanel()
    }

    func syncFromPanel() {
        guard let panel else { return }
        let frame = panel.frame
        x = frame.origin.x
        y = frame.origin.y
        w = frame.size.width
        h = frame.size.height
        tx = x
        ty = y
        tw = w
        th = h
        vx = 0
        vy = 0
        vw = 0
        vh = 0
        alpha = panel.alphaValue
        alphaTarget = alpha
        alphaVelocity = 0
    }

    func retarget(frame: NSRect, alpha: CGFloat? = nil, restartIfNeeded: Bool = true) {
        guard let panel else { return }
        if !isAnimating {
            syncFromPanel()
        }
        tx = frame.origin.x
        ty = frame.origin.y
        tw = frame.size.width
        th = frame.size.height
        if let alpha {
            alphaTarget = alpha
        }
        if restartIfNeeded {
            startLink(on: panel)
        }
    }

    func cancel() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        vx = 0
        vy = 0
        vw = 0
        vh = 0
        alphaVelocity = 0
    }

    func jump(to frame: NSRect, alpha: CGFloat) {
        cancel()
        x = frame.origin.x
        y = frame.origin.y
        w = frame.size.width
        h = frame.size.height
        tx = x
        ty = y
        tw = w
        th = h
        self.alpha = alpha
        alphaTarget = alpha
        apply(settled: true)
    }

    private func startLink(on panel: NSPanel) {
        guard link == nil else { return }
        lastTimestamp = 0
        let link = panel.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = CGFloat(lastTimestamp == 0 ? (link.duration > 0 ? link.duration : 1.0 / 120.0) : now - lastTimestamp)
        lastTimestamp = now
        if dt <= 0 { dt = 1.0 / 120.0 }
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)

        var remaining = dt
        let step: CGFloat = 1.0 / 240.0
        while remaining > 0.0001 {
            let slice = min(step, remaining)
            OverlaySpring.step(value: &x, velocity: &vx, target: tx, dt: slice)
            OverlaySpring.step(value: &y, velocity: &vy, target: ty, dt: slice)
            OverlaySpring.step(value: &w, velocity: &vw, target: tw, dt: slice)
            OverlaySpring.step(value: &h, velocity: &vh, target: th, dt: slice)
            OverlaySpring.step(
                value: &alpha,
                velocity: &alphaVelocity,
                target: alphaTarget,
                dt: slice,
                response: OverlaySpring.fadeResponse,
                damping: OverlaySpring.fadeDamping
            )
            remaining -= slice
        }

        let frameSettled =
            OverlaySpring.settled(value: x, velocity: vx, target: tx)
            && OverlaySpring.settled(value: y, velocity: vy, target: ty)
            && OverlaySpring.settled(value: w, velocity: vw, target: tw)
            && OverlaySpring.settled(value: h, velocity: vh, target: th)
            && OverlaySpring.settled(value: alpha, velocity: alphaVelocity, target: alphaTarget, distance: 0.01, speed: 0.08)

        if frameSettled {
            x = tx
            y = ty
            w = tw
            h = th
            alpha = alphaTarget
            apply(settled: true)
            cancel()
            onSettled?()
            return
        }
        apply(settled: false)
    }

    private func apply(settled: Bool) {
        guard let panel else { return }
        var frame = NSRect(x: x, y: y, width: max(1, w), height: max(1, h))
        if settled {
            frame = OverlayPixel.align(frame, scale: panel.screen?.backingScaleFactor ?? 2)
            x = frame.origin.x
            y = frame.origin.y
            w = frame.size.width
            h = frame.size.height
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sizeChanged =
            abs(frame.width - panel.frame.width) > 0.5
            || abs(frame.height - panel.frame.height) > 0.5
        if settled || sizeChanged {
            panel.setFrame(frame, display: false)
        } else {
            panel.setFrameOrigin(frame.origin)
        }
        panel.alphaValue = min(max(alpha, 0), 1)
        CATransaction.commit()
        onProgress?(frame, panel.alphaValue)
    }
}

final class OverlayPresentationAnimator: NSObject, CAAnimationDelegate {
    private weak var surface: CALayer?
    private var generation = 0
    private var completion: ((Bool) -> Void)?
    private let animationKey = "bubble.window.presentation"
    private let hiddenOpacity: Float = 0.005

    var isAnimating: Bool {
        surface?.animation(forKey: animationKey) != nil
    }

    func attach(_ surface: CALayer) {
        self.surface = surface
        resetVisible()
    }

    func prepareHidden(scale: CGFloat) {
        guard let surface else { return }
        generation &+= 1
        completion = nil
        surface.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A fully transparent subtree can be culled by WindowServer. Keeping one
        // near-invisible preflight frame forces the expensive SwiftUI hierarchy
        // into a reusable compositor surface before the visible transition.
        surface.opacity = hiddenOpacity
        surface.transform = hiddenTransform
        surface.shouldRasterize = true
        surface.rasterizationScale = max(scale, 1)
        CATransaction.commit()
    }

    func animate(
        visible: Bool,
        scale: CGFloat,
        reduceMotion: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let surface else {
            completion(false)
            return
        }

        let current = surface.presentation() ?? surface
        let fromOpacity = current.opacity
        let fromTransform = current.transform
        let targetOpacity: Float = visible ? 1 : hiddenOpacity
        let targetTransform = visible ? CATransform3DIdentity : hiddenTransform
        let distance = max(
            abs(CGFloat(fromOpacity - targetOpacity)),
            min(1, abs(fromTransform.m42 - targetTransform.m42) / max(OverlayPresentationPolicy.verticalOffset, 1))
        )

        generation &+= 1
        let animationGeneration = generation
        self.completion = completion
        surface.removeAnimation(forKey: animationKey)
        surface.shouldRasterize = true
        surface.rasterizationScale = max(scale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.opacity = targetOpacity
        surface.transform = targetTransform
        CATransaction.commit()

        if reduceMotion || distance < 0.001 {
            finish(generation: animationGeneration, visible: visible, finished: true)
            return
        }

        let baseDuration = visible
            ? OverlayPresentationPolicy.showDuration
            : OverlayPresentationPolicy.hideDuration
        let duration = max(0.045, baseDuration * TimeInterval(distance))

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = targetOpacity

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: targetTransform)

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(
            controlPoints: visible ? 0.16 : 0.40,
            visible ? 1.00 : 0.00,
            visible ? 0.30 : 0.72,
            1.00
        )
        group.delegate = self
        group.setValue(animationGeneration, forKey: "bubbleGeneration")
        group.setValue(visible, forKey: "bubbleVisible")
        group.isRemovedOnCompletion = true
        surface.add(group, forKey: animationKey)
    }

    func resetVisible() {
        guard let surface else { return }
        generation &+= 1
        completion = nil
        surface.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.opacity = 1
        surface.transform = CATransform3DIdentity
        surface.shouldRasterize = false
        CATransaction.commit()
    }

    func cancel(resetVisible: Bool) {
        guard let surface else { return }
        generation &+= 1
        completion = nil
        surface.removeAnimation(forKey: animationKey)
        if resetVisible {
            self.resetVisible()
        }
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard let animationGeneration = anim.value(forKey: "bubbleGeneration") as? Int,
              let visible = anim.value(forKey: "bubbleVisible") as? Bool else { return }
        finish(generation: animationGeneration, visible: visible, finished: flag)
    }

    private var hiddenTransform: CATransform3D {
        CATransform3DMakeTranslation(0, -OverlayPresentationPolicy.verticalOffset, 0)
    }

    private func finish(generation animationGeneration: Int, visible: Bool, finished: Bool) {
        guard animationGeneration == generation else { return }
        let callback = completion
        completion = nil
        if visible {
            surface?.shouldRasterize = false
        }
        callback?(finished)
    }
}

final class WindowPresentationDiagnostics: NSObject {
    private weak var panel: NSPanel?
    private weak var surface: CALayer?
    private var link: CADisplayLink?
    private var active = false
    private var lastTimestamp: CFTimeInterval = 0
    private var stableFrame: NSRect = .zero
    private var intervals: [TimeInterval] = []
    private var phase = "idle"
    private var phaseCounts: [String: Int] = [:]
    private var slowIntervals: [String] = []
    private(set) var frameMutations = 0
    private(set) var presentationSamples = 0

    func attach(panel: NSPanel, surface: CALayer) {
        self.panel = panel
        self.surface = surface
    }

    func begin(stableFrame: NSRect, phase: String) {
        guard let panel else { return }
        self.stableFrame = stableFrame
        phaseCounts[phase, default: 0] += 1
        self.phase = "\(phase)\(phaseCounts[phase] ?? 0)"
        active = true
        lastTimestamp = 0
        if link == nil {
            let link = panel.displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = OverlayMotion.frameRate
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func end() {
        active = false
        lastTimestamp = 0
    }

    func summary(cycles: Int) -> String {
        link?.invalidate()
        link = nil
        let milliseconds = intervals.sorted().map { $0 * 1_000 }
        let p95 = percentile(milliseconds, 0.95)
        let p99 = percentile(milliseconds, 0.99)
        let maximum = milliseconds.last ?? 0
        let slowSummary = slowIntervals.isEmpty ? "none" : slowIntervals.joined(separator: ",")
        return String(
            format: "window presentation benchmark cycles=%d samples=%d p95=%.2fms p99=%.2fms max=%.2fms frameMutations=%d presentationSamples=%d",
            cycles,
            milliseconds.count,
            p95,
            p99,
            maximum,
            frameMutations,
            presentationSamples
        ) + " slow=\(slowSummary)"
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard active, let panel else { return }
        if lastTimestamp > 0 {
            let interval = max(0, link.timestamp - lastTimestamp)
            intervals.append(interval)
            if interval > 0.020, slowIntervals.count < 12 {
                slowIntervals.append(String(format: "%@-%.2f", phase, interval * 1_000))
            }
        }
        lastTimestamp = link.timestamp

        let frame = panel.frame
        if abs(frame.origin.x - stableFrame.origin.x) > 0.25
            || abs(frame.origin.y - stableFrame.origin.y) > 0.25
            || abs(frame.width - stableFrame.width) > 0.25
            || abs(frame.height - stableFrame.height) > 0.25 {
            frameMutations += 1
        }

        if let presentation = surface?.presentation() {
            let opacityIsTransitioning = presentation.opacity > 0.001 && presentation.opacity < 0.999
            let translationIsTransitioning = abs(presentation.transform.m42) > 0.1
            if opacityIsTransitioning || translationIsTransitioning {
                presentationSamples += 1
            }
        }
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let index = min(
            values.count - 1,
            max(0, Int((Double(values.count - 1) * percentile).rounded(.up)))
        )
        return values[index]
    }
}

final class PalettePresentationDiagnostics: NSObject {
    private weak var panel: NSPanel?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [TimeInterval] = []
    private var showIntervals: [TimeInterval] = []
    private var hideIntervals: [TimeInterval] = []
    private var latencies: [TimeInterval] = []
    private var mutationDurations: [TimeInterval] = []
    private var cycleStartedAt: TimeInterval?
    private var phase = "idle"

    func attach(panel: NSPanel) {
        self.panel = panel
    }

    func start() {
        guard link == nil, let panel else { return }
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func beginCycle() {
        phase = "show"
        cycleStartedAt = CACurrentMediaTime()
    }

    func beginHide() {
        phase = "hide"
    }

    func markPresented() {
        guard let cycleStartedAt else { return }
        latencies.append(CACurrentMediaTime() - cycleStartedAt)
        self.cycleStartedAt = nil
    }

    func recordMutationDuration(_ duration: TimeInterval) {
        mutationDurations.append(duration)
    }

    func summary(cycles: Int) -> String {
        link?.invalidate()
        link = nil
        let frameMilliseconds = intervals.sorted().map { $0 * 1_000 }
        let showMilliseconds = showIntervals.sorted().map { $0 * 1_000 }
        let hideMilliseconds = hideIntervals.sorted().map { $0 * 1_000 }
        let latencyMilliseconds = latencies.sorted().map { $0 * 1_000 }
        let mutationMilliseconds = mutationDurations.sorted().map { $0 * 1_000 }
        return String(
            format: "palette presentation benchmark cycles=%d presented=%d p95=%.2fms p99=%.2fms max=%.2fms showP99=%.2fms hideP99=%.2fms latencyP95=%.2fms latencyMax=%.2fms mutationP95=%.2fms mutationMax=%.2fms",
            cycles,
            latencies.count,
            percentile(frameMilliseconds, 0.95),
            percentile(frameMilliseconds, 0.99),
            frameMilliseconds.last ?? 0,
            percentile(showMilliseconds, 0.99),
            percentile(hideMilliseconds, 0.99),
            percentile(latencyMilliseconds, 0.95),
            latencyMilliseconds.last ?? 0,
            percentile(mutationMilliseconds, 0.95),
            mutationMilliseconds.last ?? 0
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            let interval = max(0, link.timestamp - lastTimestamp)
            intervals.append(interval)
            if phase == "show" {
                showIntervals.append(interval)
            } else if phase == "hide" {
                hideIntervals.append(interval)
            }
        }
        lastTimestamp = link.timestamp
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let index = min(
            values.count - 1,
            max(0, Int((Double(values.count - 1) * percentile).rounded(.up)))
        )
        return values[index]
    }
}
