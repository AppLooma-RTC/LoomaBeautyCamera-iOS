import Foundation
import CoreVideo
import ImageIO
import QuartzCore
import simd
import Vision

/// Finds the face on small snapshots of the camera frame, off the capture
/// thread, and keeps its outline in buffer texture coordinates (0...1, the
/// frame before rotation, top-left origin). Landmarks are smoothed over time
/// so the masks do not shimmer.
final class FaceTracker {
    /// A face in buffer coordinates: outline and the regions to keep sharp.
    /// Polygons are flat (x, y) pairs.
    final class Face {
        let oval: [Float]
        /// Eyes first (two), then the brows.
        let holes: [[Float]]
        let lips: [Float]?
        let anchors: Anchors?
        let mouthIn: [Float]?
        let eyes: [[Float]]
        init(oval: [Float], holes: [[Float]], lips: [Float]?, anchors: Anchors?, mouthIn: [Float]?, eyes: [[Float]]) {
            self.oval = oval; self.holes = holes; self.lips = lips; self.anchors = anchors; self.mouthIn = mouthIn; self.eyes = eyes
        }
    }

    /// Anchors on the upright image, normalised to its size: eye centres, the
    /// top of the face outline, the face width, jaw points and named landmarks.
    final class Anchors {
        let lx, ly, rx, ry, topX, topY, faceW: Float
        let uprightW, uprightH: Float
        let rotation: Int
        let bufW, bufH: Float
        let jawLx, jawLy, jawRx, jawRy: Float
        let pts: [String: [Float]]
        init(_ k: [Float], uprightW: Float, uprightH: Float, rotation: Int, bufW: Float, bufH: Float, pts: [String: [Float]]) {
            lx = k[0]; ly = k[1]; rx = k[2]; ry = k[3]; topX = k[4]; topY = k[5]; faceW = k[6]
            jawLx = k[7]; jawLy = k[8]; jawRx = k[9]; jawRy = k[10]
            self.uprightW = uprightW; self.uprightH = uprightH; self.rotation = rotation
            self.bufW = bufW; self.bufH = bufH; self.pts = pts
        }
        /// Landmark `name` in upright pixels, or nil.
        func px(_ name: String) -> SIMD2<Float>? {
            guard let p = pts[name] else { return nil }
            return SIMD2(p[0] * uprightW, p[1] * uprightH)
        }
    }

    private let queue = DispatchQueue(label: "looma.beauty.face", qos: .userInitiated)
    private let lock = NSLock()
    private var _busy = false
    private var _face: Face?
    private var _lastSeen: CFTimeInterval = 0
    private var _motion: Float = 0
    private var misses = 0

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return _busy }
    var face: Face? { lock.lock(); defer { lock.unlock() }; return _face }
    var lastSeen: CFTimeInterval { lock.lock(); defer { lock.unlock() }; return _lastSeen }
    /// How fast the face moved at the last detection (normalised units per second).
    var motion: Float { lock.lock(); defer { lock.unlock() }; return _motion }

    /// Detects on `buffer` (the frame in buffer orientation, BGRA, any size)
    /// that `rotation` clockwise degrees make upright.
    func offer(_ buffer: CVPixelBuffer, rotation: Int) {
        lock.lock()
        if _busy { lock.unlock(); return }
        _busy = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool { self.detect(buffer, rotation: rotation) }
            self.lock.lock(); self._busy = false; self.lock.unlock()
        }
    }

    static func orientation(_ rotation: Int) -> CGImagePropertyOrientation {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    private func detect(_ buffer: CVPixelBuffer, rotation: Int) {
        let w = Float(CVPixelBufferGetWidth(buffer)), h = Float(CVPixelBufferGetHeight(buffer))
        let sideways = rotation == 90 || rotation == 270
        let upW = sideways ? h : w, upH = sideways ? w : h
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: FaceTracker.orientation(rotation), options: [:])
        do { try handler.perform([request]) } catch { return }
        let now = CACurrentMediaTime()
        if euroT != 0 { euroDt = Swift.min(Swift.max(Float(now - euroT), 0.02), 0.5) }
        euroT = now

        let faces = request.results ?? []
        let best = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        guard let f = best, let lm = f.landmarks, let contour = lm.faceContour,
              let leftEye = lm.leftEye, let rightEye = lm.rightEye else {
            misses += 1
            if misses > 3 { lock.lock(); _face = nil; lock.unlock() }
            return
        }
        misses = 0
        let size = CGSize(width: CGFloat(upW), height: CGFloat(upH))
        // Vision's points have a bottom-left origin; turn them top-left.
        func points(_ r: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
            guard let r, r.pointCount > 0 else { return [] }
            return r.pointsInImage(imageSize: size).map { SIMD2(Float($0.x), upH - Float($0.y)) }
        }
        func centre(_ p: [SIMD2<Float>]) -> SIMD2<Float> {
            var s = SIMD2<Float>(0, 0); for q in p { s += q }; return s / Float(Swift.max(p.count, 1))
        }
        var eyeA = points(leftEye), eyeB = points(rightEye)
        if eyeA.isEmpty || eyeB.isEmpty { return }
        // "L" is the eye with the smaller x on the upright image.
        if centre(eyeA).x > centre(eyeB).x { swap(&eyeA, &eyeB) }
        var browA = points(lm.leftEyebrow), browB = points(lm.rightEyebrow)
        if !browA.isEmpty, !browB.isEmpty, centre(browA).x > centre(browB).x { swap(&browA, &browB) }
        let le = centre(eyeA), re = centre(eyeB)
        let ed = simd_len(re - le)
        if ed < 2 { return }
        let u = (re - le) / ed                      // across the face
        let v = SIMD2<Float>(-u.y, u.x)             // down the face
        let eyeMid = (le + re) / 2

        // Vision's contour is the jaw line only; close it over the forehead
        // with a half ellipse up to about an eye-distance above the eyes.
        var jaw = points(contour)
        if jaw.count < 3 { return }
        if simd_dot(jaw.first! - eyeMid, u) > simd_dot(jaw.last! - eyeMid, u) { jaw.reverse() }   // left to right
        let j0 = jaw.first!, jn = jaw.last!
        let c = (j0 + jn) / 2
        let d = jn - c
        let topPt = eyeMid - v * (0.85 * ed)
        let b = Swift.max(simd_dot(c - topPt, v), ed * 0.5)
        var ovalUp = jaw
        let arcN = 12
        for k in 1..<arcN {
            let t = Float.pi * Float(k) / Float(arcN)
            ovalUp.append(c + d * cos(t) - v * (b * sin(t)))
        }
        let apex = c - v * b

        func toBuf(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let q = FaceTracker.toBuffer(p.x, p.y, rotation, w, h)
            return SIMD2(q.x / w, q.y / h)
        }
        func poly(_ key: String, _ p: [SIMD2<Float>]) -> [Float]? {
            if p.count < 3 { return nil }
            var raw = [Float](); raw.reserveCapacity(p.count * 2)
            for q in p { let bq = toBuf(q); raw.append(bq.x); raw.append(bq.y) }
            return smoothKey("c" + key, raw)
        }
        // A line (an eyebrow) as a band of some thickness.
        func band(_ line: [SIMD2<Float>], _ t: Float) -> [SIMD2<Float>] {
            if line.count < 2 { return [] }
            return line.map { $0 - v * t } + line.reversed().map { $0 + v * t }
        }

        guard let oval = poly("oval", ovalUp) else { return }
        let eyes = [poly("eyeL", eyeA), poly("eyeR", eyeB)].compactMap { $0 }
        let brows = [poly("browL", band(browA, ed * 0.06)), poly("browR", band(browB, ed * 0.06))].compactMap { $0 }
        let outer = points(lm.outerLips), inner = points(lm.innerLips)
        let lips = poly("lips", outer)
        let mouthIn = poly("mouthIn", inner)

        // Named anchors on the upright image, normalised.
        var pts: [String: [Float]] = [:]
        func put(_ name: String, _ p: SIMD2<Float>) { pts[name] = smoothKey("a" + name, [p.x / upW, p.y / upH]) }
        let chin = jaw.max { simd_dot($0 - eyeMid, v) < simd_dot($1 - eyeMid, v) }!
        put("chin", chin)
        put("top", apex)
        func down(_ p: SIMD2<Float>) -> Float { simd_dot(p - eyeMid, v) }
        func across(_ p: SIMD2<Float>) -> Float { simd_dot(p - eyeMid, u) }
        let cheekBand = jaw.filter { down($0) > ed * 0.1 && down($0) < ed * 0.55 }
        let cb = cheekBand.isEmpty ? jaw : cheekBand
        if let l = cb.min(by: { across($0) < across($1) }) { put("cheekL", l) }
        if let r = cb.max(by: { across($0) < across($1) }) { put("cheekR", r) }
        let lowBand = jaw.filter { down($0) > ed * 1.35 && down($0) < down(chin) - ed * 0.1 }
        if let l = lowBand.min(by: { across($0) < across($1) }) { put("lowL", l) }
        if let r = lowBand.max(by: { across($0) < across($1) }) { put("lowR", r) }
        let jawBandRaw = jaw.filter { down($0) > ed * 0.6 && down($0) < ed * 1.4 }
        let jawBand = jawBandRaw.isEmpty ? jaw : jawBandRaw
        let jl = jawBand.min { across($0) < across($1) }!
        let jr = jawBand.max { across($0) < across($1) }!
        for (name, e) in [("eyeL", eyeA), ("eyeR", eyeB)] {
            let isL = name == "eyeL"
            let outerPt = isL ? e.min { across($0) < across($1) }! : e.max { across($0) < across($1) }!
            let innerPt = isL ? e.max { across($0) < across($1) }! : e.min { across($0) < across($1) }!
            put(name + "Outer", outerPt); put(name + "Inner", innerPt)
            put(name + "Top", e.min { down($0) < down($1) }!)
        }
        let crest = points(lm.noseCrest)
        if let first = crest.min(by: { down($0) < down($1) }) { put("noseTop", first) }
        if let last = crest.max(by: { down($0) < down($1) }) { put("noseTip", last) }
        let nose = points(lm.nose)
        if nose.count >= 3 {
            put("wingL", nose.min { across($0) < across($1) }!)
            put("wingR", nose.max { across($0) < across($1) }!)
            put("noseBottom", nose.max { down($0) < down($1) }!)
        }
        if outer.count >= 2 {
            put("mouthL", outer.min { across($0) < across($1) }!)
            put("mouthR", outer.max { across($0) < across($1) }!)
            put("lipTop", outer.min { down($0) < down($1) }!)
            put("lipBottom", outer.max { down($0) < down($1) }!)
        }
        if !inner.isEmpty { put("mouthC", centre(inner)) } else if !outer.isEmpty { put("mouthC", centre(outer)) }
        for (name, list) in [("browL", browA), ("browR", browB)] where !list.isEmpty {
            put(name, centre(list))
            put(name + "Outer", name == "browL" ? list.min { across($0) < across($1) }! : list.max { across($0) < across($1) }!)
        }
        let tBand = ovalUp.filter { down($0) > -ed * 0.9 && down($0) < -ed * 0.15 }
        if let l = tBand.min(by: { across($0) < across($1) }) { put("templeL", l) }
        if let r = tBand.max(by: { across($0) < across($1) }) { put("templeR", r) }
        if !browA.isEmpty, !browB.isEmpty {
            let a = browA.max { across($0) < across($1) }!, bb = browB.min { across($0) < across($1) }!
            put("brows", (a + bb) / 2)
        }
        let xs = ovalUp.map { $0.x }
        let fw = ((xs.max() ?? 0) - (xs.min() ?? 0)) / upW
        let prev = euroX["base"]
        let k = smoothKey("base", [le.x / upW, le.y / upH, re.x / upW, re.y / upH, apex.x / upW, apex.y / upH, fw,
                                   jl.x / upW, jl.y / upH, jr.x / upW, jr.y / upH])
        var motion = self.motion
        if let p = prev, p.count >= 4 {
            let mv = hypotf(k[0] + k[2] - p[0] - p[2], k[1] + k[3] - p[1] - p[3]) / 2 / euroDt
            motion = motion * 0.5 + mv * 0.5
        }
        let anchors = Anchors(k, uprightW: upW, uprightH: upH, rotation: rotation, bufW: w, bufH: h, pts: pts)
        let result = Face(oval: oval, holes: eyes + brows, lips: lips, anchors: anchors, mouthIn: mouthIn, eyes: eyes)
        lock.lock()
        _face = result
        _lastSeen = CACurrentMediaTime()
        _motion = motion
        lock.unlock()
    }

    // MARK: One-euro smoothing

    private var euroX: [String: [Float]] = [:]
    private var euroDx: [String: [Float]] = [:]
    private var euroT: CFTimeInterval = 0
    private var euroDt: Float = 0.1

    /// Strong when the face is still (no shimmer), light when it moves (no
    /// lag). A big jump resets it.
    private func smoothKey(_ key: String, _ raw: [Float]) -> [Float] {
        guard let prev = euroX[key], prev.count == raw.count, var dx = euroDx[key] else {
            euroX[key] = raw; euroDx[key] = [Float](repeating: 0, count: raw.count); return raw
        }
        var jump: Float = 0
        for i in raw.indices { jump = Swift.max(jump, abs(raw[i] - prev[i])) }
        if jump > 0.15 { euroX[key] = raw; euroDx[key] = [Float](repeating: 0, count: raw.count); return raw }
        let dt = euroDt
        func alpha(_ cutoff: Float) -> Float { let tau = 1 / (2 * Float.pi * cutoff); return 1 / (1 + tau / dt) }
        let aD = alpha(1)
        var out = [Float](repeating: 0, count: raw.count)
        for i in raw.indices {
            let d = (raw[i] - prev[i]) / dt
            dx[i] += aD * (d - dx[i])
            let a = alpha(1 + 40 * abs(dx[i]))
            out[i] = prev[i] + a * (raw[i] - prev[i])
        }
        euroX[key] = out
        euroDx[key] = dx
        // Lead by part of the detector's delay so the masks keep up with the head.
        let lead = Swift.min(dt * 0.6, 0.08)
        return out.indices.map { out[$0] + Swift.min(Swift.max(dx[$0] * lead, -0.03), 0.03) }
    }

    /// A point on the upright image back on the buffer image (`w` x `h`, before rotation).
    static func toBuffer(_ x: Float, _ y: Float, _ rotation: Int, _ w: Float, _ h: Float) -> SIMD2<Float> {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return SIMD2(y, h - x)
        case 180: return SIMD2(w - x, h - y)
        case 270: return SIMD2(w - y, x)
        default: return SIMD2(x, y)
        }
    }
}
