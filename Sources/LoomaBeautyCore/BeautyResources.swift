import Foundation

/// Where the bundled resources (the catalogue) live: the Swift package's
/// resource bundle, or the CocoaPods resource bundle when the sources are
/// built as a pod.
enum BeautyResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let host = Bundle(for: Token.self)
        for name in ["LoomaBeautyCore", "LoomaBeautyCamera"] {
            if let url = host.url(forResource: name, withExtension: "bundle"), let b = Bundle(url: url) { return b }
            if let url = Bundle.main.url(forResource: name, withExtension: "bundle"), let b = Bundle(url: url) { return b }
        }
        return host
        #endif
    }()

    private final class Token {}
}
