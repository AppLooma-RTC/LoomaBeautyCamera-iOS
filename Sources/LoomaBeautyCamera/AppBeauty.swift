import Foundation
import CoreVideo
import QuartzCore
import UIKit
import AppLoomaRTC

/// Looma Beauty Camera: GPU skin smoothing, whitening, rosy tone, sharpening,
/// make-up, colour filters, face masks and virtual backgrounds on the camera,
/// at camera frame rate. What it draws is what viewers receive and what the
/// host sees in the preview.
///
/// ```swift
/// let beauty = AppBeauty.create()          // Smart Beauty is on from the start
/// engine.setVideoProcessor(beauty)
/// AppBeautyPanel.show(in: self, beauty: beauty)
/// ```
/// Change `options` at any time; the next frame uses them. Remove with
/// `engine.setVideoProcessor(nil)`.
public final class AppBeauty: AppVideoFrameProcessor {
    public static let version = "0.1.0"
    /// On from the start: the Smart Beauty preset.
    public static var defaultOptions: AppBeautyOptions { AppBeautyPreset.smart.options }
    /// No effect at all.
    public static let off = AppBeautyOptions()
    /// Whether virtual backgrounds work on this device (iOS 15 or later).
    public static var isBackgroundSupported: Bool { SegTracker.isSupported }

    private let gpu: MetalBeauty?
    private let tracker = FaceTracker()
    private lazy var seg: SegTracker? = SegTracker.isSupported ? SegTracker() : nil
    private let lock = NSLock()
    private var current: AppBeautyOptions
    private var _preset: AppBeautyPreset?
    private var appliedFilter: AppBeautyFilter?
    private var fade: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private var failed = false

    /// A new beauty processor with Smart Beauty on.
    public static func create() -> AppBeauty { AppBeauty() }

    private init() {
        gpu = MetalBeauty()
        current = AppBeautyOptions()
        options = AppBeauty.defaultOptions
    }

    /// The settings in force; set to change them on the next frame.
    public var options: AppBeautyOptions {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            let v = newValue.clamped()
            lock.lock()
            current = v
            _preset = AppBeautyPreset.all.first { $0.options == v }
            let filterChanged = v.filter != appliedFilter
            if filterChanged { appliedFilter = v.filter }
            lock.unlock()
            if filterChanged { gpu?.setLut(Luts.rgba(v.filter)) }
        }
    }

    /// The preset last chosen with `setPreset` (or the default), nil after a manual change.
    public var preset: AppBeautyPreset? { lock.lock(); defer { lock.unlock() }; return _preset }

    /// Sets a preset; same as `options = preset.options`.
    public func setPreset(_ preset: AppBeautyPreset) {
        options = preset.options
        lock.lock(); _preset = preset; lock.unlock()
    }

    /// The face mask that follows the head (Magic), or nil. See `AppMasks`.
    /// Its pictures are downloaded on first use.
    public var mask: AppMask? {
        get { gpu?.mask }
        set { gpu?.mask = newValue; if let m = newValue, !BeautyAssets.isReady(m) { BeautyAssets.fetch(m) { _ in } } }
    }

    /// Sets the mask by its catalogue id (nil or an unknown id removes it).
    public func setMask(id: String?) { mask = id.flatMap { AppMasks.byId($0) } }

    /// What replaces the background behind the person (Magic). iOS 15 or
    /// later; on iOS 14 the setting is kept but nothing is drawn.
    public var background: AppBeautyBackground {
        get { gpu?.background ?? .none }
        set { gpu?.background = newValue; if !BeautyAssets.isReady(newValue) { BeautyAssets.fetch(newValue) { _ in } } }
    }

    /// The picture for `AppBeautyBackground.custom`, upright. The Magic panel's
    /// Upload card lets the user pick one; an app can also set it.
    public var customBackground: UIImage? {
        get { gpu?.customBackground }
        set { gpu?.customBackground = newValue }
    }

    /// A small upright picture of the camera, without beauty, on the main
    /// queue. Nothing arrives while no frames flow.
    public func snapshot(_ callback: @escaping (UIImage) -> Void) { gpu?.snapshotRequest = callback }

    // MARK: AppVideoFrameProcessor

    public func process(_ pixelBuffer: CVPixelBuffer, rotation: Int, timestamp: Int64) -> CVPixelBuffer {
        guard let gpu, !failed else { return pixelBuffer }
        let o = options
        let bg = gpu.background
        if o.isNeutral && bg == .none && gpu.mask == nil && gpu.snapshotRequest == nil { return pixelBuffer }
        // Strengths ease in over about a second once a face is found (and ease
        // back to half when it is lost), so the look settles in smoothly.
        let now = CACurrentMediaTime()
        let dt: Float = lastFrame == 0 ? 0 : Swift.min(Float(now - lastFrame), 0.2)
        lastFrame = now
        let target: Float = (tracker.face != nil && now - tracker.lastSeen < 0.6) ? 1 : 0.5
        fade += (target - fade) * Swift.min(dt * 2.5, 1)
        let eased = o.scaled(fade)
        let segUsed: SegTracker? = bg != .none ? seg : nil
        let out = autoreleasepool { gpu.draw(pixelBuffer, rotation: rotation, o: eased, tracker: tracker, seg: segUsed) }
        return out ?? pixelBuffer
    }
}
