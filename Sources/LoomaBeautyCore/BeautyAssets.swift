import Foundation
import UIKit

/// Pictures for Magic and the panel cards. Nothing large ships in the
/// package: backgrounds, mask layers and card pictures are fetched from the
/// AppLooma CDN the first time they are needed and kept in Caches/.
enum BeautyAssets {
    private static let lock = NSLock()
    private static var pending: [String: [(Bool) -> Void]] = [:]
    private static let memory = NSCache<NSString, UIImage>()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 40
        return URLSession(configuration: c)
    }()

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("LoomaBeautyCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func isCached(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }

    /// The cached picture `name`, decoded, or nil.
    static func image(_ name: String) -> UIImage? {
        guard isCached(name) else { return nil }
        return UIImage(contentsOfFile: file(name).path)
    }

    // MARK: Backgrounds and masks

    static func isReady(_ bg: AppBeautyBackground) -> Bool { bg.remoteNames.allSatisfy(isCached) }
    static func isReady(_ m: AppMask) -> Bool { m.layers.allSatisfy { isCached($0.image) } }

    /// Downloads `bg`'s pictures if needed; `done` runs on the main queue.
    static func fetch(_ bg: AppBeautyBackground, done: @escaping (Bool) -> Void) {
        fetch(base: BeautyCatalog.shared.cdnBg, names: bg.remoteNames) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Downloads `m`'s layer pictures if needed; `done` runs on the main queue.
    static func fetch(_ m: AppMask, done: @escaping (Bool) -> Void) {
        var names: [String] = []
        for l in m.layers where !names.contains(l.image) { names.append(l.image) }
        fetch(base: BeautyCatalog.shared.cdnMask, names: names) { ok in DispatchQueue.main.async { done(ok) } }
    }

    // MARK: Cards

    /// A card picture (preset, make-up, mask, background thumbnails, model
    /// photos): from memory, the disk cache or the CDN. `done` runs on the main queue.
    static func card(_ name: String, done: @escaping (UIImage?) -> Void) {
        if let m = memory.object(forKey: name as NSString) { done(m); return }
        fetch(base: BeautyCatalog.shared.cdnCards, names: [name]) { ok in
            let img = ok ? image(name) : nil
            if let img { memory.setObject(img, forKey: name as NSString) }
            DispatchQueue.main.async { done(img) }
        }
    }

    static func remember(_ img: UIImage, as key: String) { memory.setObject(img, forKey: key as NSString) }
    static func remembered(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    // MARK: Downloads

    /// Fetches each missing name in turn; `done` runs on a background queue.
    static func fetch(base: String, names: [String], done: @escaping (Bool) -> Void) {
        guard let name = names.first(where: { !isCached($0) }) else { done(true); return }
        lock.lock()
        if pending[name] != nil {
            pending[name]!.append { ok in if ok { fetch(base: base, names: names, done: done) } else { done(false) } }
            lock.unlock()
            return
        }
        pending[name] = [{ ok in if ok { fetch(base: base, names: names, done: done) } else { done(false) } }]
        lock.unlock()
        download(base: base, name: name) { ok in
            lock.lock()
            let waiting = pending.removeValue(forKey: name) ?? []
            lock.unlock()
            waiting.forEach { $0(ok) }
        }
    }

    private static func download(base: String, name: String, done: @escaping (Bool) -> Void) {
        guard let url = URL(string: base + name) else { done(false); return }
        let task = session.downloadTask(with: url) { tmp, response, error in
            guard error == nil, let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { done(false); return }
            let out = file(name)
            try? FileManager.default.removeItem(at: out)
            do {
                try FileManager.default.moveItem(at: tmp, to: out)
                done(true)
            } catch {
                done(false)
            }
        }
        task.resume()
    }
}
