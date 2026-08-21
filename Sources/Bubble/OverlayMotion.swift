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
    static let scroll = Animation.spring(response: 0.28, dampingFraction: 0.96, blendDuration: 0)

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
            OverlaySpring.step(value: &alpha, velocity: &alphaVelocity, target: alphaTarget, dt: slice)
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
        panel.setFrame(frame, display: false)
        panel.alphaValue = min(max(alpha, 0), 1)
        CATransaction.commit()
        onProgress?(frame, panel.alphaValue)
    }
}
