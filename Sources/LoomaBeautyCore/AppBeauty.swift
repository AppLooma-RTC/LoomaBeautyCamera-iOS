import Foundation
import CoreVideo
import QuartzCore
import UIKit

/// Looma Beauty Camera: GPU skin smoothing, whitening, rosy tone, sharpening,
/// make-up, colour filters, face masks and virtual backgrounds on the camera,
/// at camera frame rate. What it draws is what viewers receive and what the
/// host sees in the preview.
///
/// ```swift
/// let beauty = AppBeauty.create()          // Smart Beauty is on from the start
/// engine.setVideoProcessor(beauty)         // with LoomaBeautyCamera (AppLooma RTC)
/// let out = beauty.process(pixelBuffer, rotation: 90, timestamp: t)   // or any camera pipeline
/// AppBeautyPanel.show(in: self, beauty: beauty)
/// ```
/// Change `options` at any time; the next frame uses them. With AppLooma RTC,
/// remove it with `engine.setVideoProcessor(nil)`.
public final class AppBeauty {
    public static let version = "0.2.1"
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
    /// Its pictures are downloaded first; the switch happens once they are
    /// ready (the previous mask stays until then, and is kept if it fails).
    public var mask: AppMask? {
        get { gpu?.mask }
        set {
            lock.lock(); wantedMask = newValue?.id; lock.unlock()
            guard let m = newValue, !BeautyAssets.isReady(m) else { gpu?.mask = newValue; return }
            BeautyAssets.fetch(m) { [weak self] ok in
                guard let self else { return }
                self.lock.lock(); let still = self.wantedMask == m.id; self.lock.unlock()
                if ok && still { self.gpu?.mask = m }
            }
        }
    }
    private var wantedMask: String?
    private var wantedBackground: AppBeautyBackground?

    /// Sets the mask by its catalogue id (nil or an unknown id removes it).
    public func setMask(id: String?) { mask = id.flatMap { AppMasks.byId($0) } }

    /// What replaces the background behind the person (Magic). iOS 15 or
    /// later; on iOS 14 the setting is kept but nothing is drawn.
    public var background: AppBeautyBackground {
        get { gpu?.background ?? .none }
        set {
            lock.lock(); wantedBackground = newValue; lock.unlock()
            guard !BeautyAssets.isReady(newValue) else { gpu?.background = newValue; return }
            BeautyAssets.fetch(newValue) { [weak self] ok in
                guard let self else { return }
                self.lock.lock(); let still = self.wantedBackground == newValue; self.lock.unlock()
                if ok && still { self.gpu?.background = newValue }
            }
        }
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

    // MARK: Frames

    /// Processes one camera frame and returns the picture to send: a new
    /// 32BGRA buffer of the same size, or `pixelBuffer` itself when nothing is
    /// drawn. Call it on the capture thread for every frame.
    /// - Parameters:
    ///   - pixelBuffer: the camera picture as captured, before rotation (32BGRA or 420f/420v).
    ///   - rotation: clockwise degrees (0, 90, 180, 270) that make the picture upright.
    ///   - timestamp: capture time in nanoseconds.

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
