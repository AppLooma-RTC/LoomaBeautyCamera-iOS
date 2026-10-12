// Looma Beauty Camera for AppLooma RTC: the effects of LoomaBeautyCore plugged
// into the RTC engine's camera. © AppLooma LLC
//
// `import LoomaBeautyCamera` also brings in everything from LoomaBeautyCore
// (AppBeauty, AppBeautyOptions, AppBeautyPanel, ...), so code written for
// 0.1.0 keeps compiling unchanged.

@_exported import LoomaBeautyCore
import AppLoomaRTC

/// `AppBeauty` already has `process(_:rotation:timestamp:)` with the
/// processor's exact shape, so it plugs straight into
/// `engine.setVideoProcessor(beauty)`.
extension AppBeauty: AppVideoFrameProcessor {}

public extension AppEngine {
    /// Puts `beauty` on the local camera (nil removes it). The same as
    /// `setVideoProcessor(beauty)`.
    func setBeauty(_ beauty: AppBeauty?) { setVideoProcessor(beauty) }

    /// The beauty processor on the local camera, or nil.
    var beauty: AppBeauty? { videoProcessor as? AppBeauty }
}
