import Foundation
import CoreVideo
import Vision

/// Separates the person from the background on small snapshots, off the
/// capture thread (iOS 15 and later). One byte of confidence per pixel.
final class SegTracker {
    struct Mask {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        /// Clockwise degrees that turn buffer coordinates into the mask's
        /// (0 when the mask is in buffer orientation).
        let rotation: Int
    }

    static var isSupported: Bool {
        if #available(iOS 15.0, *) { return true }
        return false
    }

    private let queue = DispatchQueue(label: "looma.beauty.seg", qos: .userInitiated)
    private let lock = NSLock()
    private var _busy = false
    private var _mask: Mask?
    private var _version = 0
    private var previous: [UInt8]?

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return _busy }
    var mask: Mask? { lock.lock(); defer { lock.unlock() }; return _mask }
    var version: Int { lock.lock(); defer { lock.unlock() }; return _version }

    func offer(_ buffer: CVPixelBuffer, rotation: Int) {
        guard SegTracker.isSupported else { return }
        lock.lock()
        if _busy { lock.unlock(); return }
        _busy = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if #available(iOS 15.0, *) { autoreleasepool { self.segment(buffer, rotation: rotation) } }
            self.lock.lock(); self._busy = false; self.lock.unlock()
        }
    }

    @available(iOS 15.0, *)
    private func segment(_ buffer: CVPixelBuffer, rotation: Int) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: FaceTracker.orientation(rotation), options: [:])
        do { try handler.perform([request]) } catch { return }
        guard let out = request.results?.first?.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return }
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
        let stride = CVPixelBufferGetBytesPerRow(out)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: w * h)
        let prev = (previous?.count == w * h) ? previous : nil
        for y in 0..<h {
            for x in 0..<w {
                var v = Int(src[y * stride + x])
                // Light smoothing over time against flicker at the edges.
                if let prev { v = (v * 6 + Int(prev[y * w + x]) * 4) / 10 }
                bytes[y * w + x] = UInt8(v)
            }
        }
        previous = bytes
        // Upright when its shape is the rotated frame's; otherwise in buffer orientation.
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let sameShape = (w >= h) == (bw >= bh)
        let rot = (rotation == 90 || rotation == 270) && !sameShape ? rotation : ((rotation == 180) ? 180 : 0)
        let m = Mask(bytes: bytes, width: w, height: h, rotation: rot)
        lock.lock(); _mask = m; _version += 1; lock.unlock()
    }
}
