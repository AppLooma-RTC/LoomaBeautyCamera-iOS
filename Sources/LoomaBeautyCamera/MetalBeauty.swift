import Foundation
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import UIKit
import simd

/// The GPU pipeline. Runs on the capture thread; textures come in and go out
/// of `CVPixelBuffer`s through a `CVMetalTextureCache` with no copies.
///
/// Passes per frame: copy (camera picture to RGBA), face masks (only when the
/// detector reports a new face), downsample (colour and squared luma),
/// two blur passes, background passes, final (smoothing, whitening, rosy,
/// sharpen, make-up, lookup table, background) into the output buffer, then
/// the mask stickers on top.
final class MetalBeauty {
    private struct FinalU {
        var skin01 = SIMD4<Float>(repeating: 0)
        var skin2 = SIMD4<Float>(repeating: 0)
        var a = SIMD4<Float>(repeating: 0)
        var b = SIMD4<Float>(repeating: 0)
        var lip = SIMD4<Float>(repeating: 0)
        var blush = SIMD4<Float>(repeating: 0)
        var shadowCol = SIMD4<Float>(repeating: 0)
        var tone = SIMD4<Float>(repeating: 0)
        var c = SIMD4<Float>(repeating: 0)
        var d = SIMD4<Float>(repeating: 0)
        var e = SIMD4<Float>(repeating: 0)
        var f = SIMD4<Float>(repeating: 0)
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var cache: CVMetalTextureCache
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    // Settings written from other threads.
    private let lock = NSLock()
    private var _background: AppBeautyBackground = .none
    private var _customBackground: UIImage?
    private var customVersion = 0
    private var _mask: AppMask?
    private var lutBytes: [UInt8]?
    private var lutDirty = false
    private var _snapshotRequest: ((UIImage) -> Void)?

    var background: AppBeautyBackground {
        get { lock.lock(); defer { lock.unlock() }; return _background }
        set { lock.lock(); _background = newValue; lock.unlock() }
    }
    var customBackground: UIImage? {
        get { lock.lock(); defer { lock.unlock() }; return _customBackground }
        set { lock.lock(); _customBackground = newValue; customVersion += 1; lock.unlock() }
    }
    var mask: AppMask? {
        get { lock.lock(); defer { lock.unlock() }; return _mask }
        set { lock.lock(); _mask = newValue; lock.unlock() }
    }
    var snapshotRequest: ((UIImage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _snapshotRequest }
        set { lock.lock(); _snapshotRequest = newValue; lock.unlock() }
    }
    func setLut(_ bytes: [UInt8]?) { lock.lock(); lutBytes = bytes; lutDirty = true; lock.unlock() }

    // Render-thread state.
    private var src: MTLTexture?
    private var half1: MTLTexture?
    private var half2: MTLTexture?
    private var mask1: MTLTexture?
    private var mask2: MTLTexture?
    private var mask3: MTLTexture?
    private var mask4: MTLTexture?
    private var bgSmall: MTLTexture?
    private var bgSmall2: MTLTexture?
    private var lutTex: MTLTexture?
    private var black: MTLTexture?
    private var segTex: MTLTexture?
    private var segVersion = -1
    private var sceneTex: MTLTexture?
    private var sceneFor: AppBeautyBackground?
    private var customUploaded = -1
    private var glassTex: MTLTexture?
    private var glassFor: AppBeautyBackground?
    private var maskTex: [String: (MTLTexture, Float)] = [:]
    private var maskFace: FaceTracker.Face?
    private var maskMakeup = false
    private var maskW = 0
    private var regionsValid = false
    private var eyeArtValid = false
    private var frameNo: Int64 = 0
    private var outPool: CVPixelBufferPool?
    private var outKey = (0, 0)
    private var smallPool: CVPixelBufferPool?
    private var smallKey = (0, 0)
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var fetching = Set<String>()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: Shaders.source, options: nil) else { return nil }
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        self.cache = c
    }

    // MARK: Frame

    /// Draws one frame; returns the processed picture (32BGRA), or nil to send the input unchanged.
    func draw(_ input: CVPixelBuffer, rotation: Int, o: AppBeautyOptions, tracker: FaceTracker?, seg: SegTracker?) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard width > 8, height > 8 else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(input)
        guard let out = outputBuffer(width, height), let outTex = cvTexture(out, plane: 0, .bgra8Unorm),
              let cb = queue.makeCommandBuffer() else { return nil }
        var keep: [CVMetalTexture] = [outTex.1]

        let s0 = target(src, width, height, .rgba8Unorm); src = s0
        // 1. Camera picture to RGBA in buffer orientation.
        if fmt == kCVPixelFormatType_32BGRA {
            guard let t = cvTexture(input, plane: 0, .bgra8Unorm) else { return nil }
            keep.append(t.1)
            quad(cb, s0, "fCopy", [t.0])
        } else if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            guard let y = cvTexture(input, plane: 0, .r8Unorm), let c = cvTexture(input, plane: 1, .rg8Unorm) else { return nil }
            keep.append(y.1); keep.append(c.1)
            let video: Float = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
            var is709: Float = 0
            if let m = CVBufferGetAttachment(input, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? String,
               m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { is709 = 1 }
            quad(cb, s0, "fCopyYuv", [y.0, c.0], SIMD4(video, is709, 0, 0))
        } else {
            return nil
        }

        // Snapshots for the detectors (every second frame while they are idle) and the panel.
        frameNo += 1
        let bgMode = background
        var faceBuf: CVPixelBuffer?
        var segBuf: CVPixelBuffer?
        if let tracker, !tracker.isBusy, frameNo % 2 == 0 { faceBuf = small(cb, s0, &keep) }
        if bgMode != .none, let seg, !seg.isBusy, frameNo % 2 == 1 { segBuf = small(cb, s0, &keep) }
        let snap = snapshotRequest
        var snapBuf: CVPixelBuffer?
        if snap != nil { snapshotRequest = nil; snapBuf = faceBuf ?? segBuf ?? small(cb, s0, &keep) }

        var face: FaceTracker.Face?
        if let tracker, CACurrentMediaTime() - tracker.lastSeen < 1.2 { face = tracker.face }
        // Masks only change when the detector reports a new face; in between, the last ones are reused.
        let mk = o.makeup
        let wantMakeup = mk != .none && o.makeupIntensity > 0 && (mk.lip != 0 || mk.blush != 0)
        let fresh = face !== maskFace || wantMakeup != maskMakeup || width != maskW
        var faceMask: MTLTexture?
        if let face { faceMask = (fresh || mask1 == nil) ? drawFaceMask(cb, face, width, height, wantMakeup) : mask1 }
        var regions: MTLTexture?
        if let an = face?.anchors, needsRegions(o) {
            if fresh || !regionsValid { regions = drawRegions(cb, an, width, height); regionsValid = true } else { regions = mask3 }
        }
        var eyeArt: MTLTexture?
        if let face, face.anchors != nil, needsEyeArt(o) {
            if fresh || !eyeArtValid { eyeArt = drawEyeArt(cb, face, width, height); eyeArtValid = true } else { eyeArt = mask4 }
        }
        if fresh {
            maskFace = face; maskMakeup = wantMakeup; maskW = width
            if regions == nil { regionsValid = false }
            if eyeArt == nil { eyeArtValid = false }
        }
        // Face-shape items are not drawn on iOS yet: no warp pass.
        let s = s0

        let needMean = o.smooth > 0 || o.sharpen > 0 || o[.lowLight] > 0 || o[.blemish] > 0 || o[.smileLines] > 0 || o[.darkCircles] > 0
        let div = Swift.min(width, height) >= 900 ? 4 : 2
        let hw = Swift.max(width / div, 1), hh = Swift.max(height / div, 1)
        var mean: MTLTexture = s
        if needMean {
            let h1 = target(half1, hw, hh, .rgba16Float); half1 = h1
            let h2 = target(half2, hw, hh, .rgba16Float); half2 = h2
            // 2. Colour and squared luma at reduced size.
            quad(cb, h1, "fDown", [s], SIMD4(Float(div) * 0.5 / Float(width), Float(div) * 0.5 / Float(height), 0, 0))
            // 3. Blur, horizontal then vertical. Radius grows with smoothing.
            let r = (1.5 + 2.5 * Swift.max(o.smooth, 0.4)) * 2 / Float(div)
            quad(cb, h2, "fBlur", [h1], SIMD4(r / Float(hw), 0, 0, 0))
            quad(cb, h1, "fBlur", [h2], SIMD4(0, r / Float(hh), 0, 0))
            mean = h1
        }

        let blackT = blackTexture()
        uploadLutIfNeeded()

        // Background: person mask, scene or blur, glass.
        var segT: MTLTexture = blackT, bgT: MTLTexture = blackT, glassT: MTLTexture = blackT
        var bgModeValue: Float = 0
        var segRot: Float = 0
        let segMask = seg?.mask
        if bgMode != .none, let seg, let segMask {
            var bgTex: MTLTexture?
            if bgMode.blur > 0 { bgTex = blurredBackground(cb, s, bgMode.blur) } else { bgTex = sceneTexture(bgMode) }
            var glass: MTLTexture?
            if bgMode.glass != nil { glass = glassTexture(bgMode) }
            if let bgTex, bgMode.glass == nil || glass != nil, let st = uploadSeg(seg, segMask) {
                segT = st; bgT = bgTex; glassT = glass ?? bgTex
                bgModeValue = glass != nil ? 3 : (bgMode.blur > 0 ? 1 : 2)
                segRot = Float(segMask.rotation)
            }
        }

        // 4. Final.
        var u = FinalU()
        u.skin2 = SIMD4(0, 0, faceMask != nil ? 1 : 0, bgModeValue)
        if let an = face?.anchors {
            let ed = hypotf((an.rx - an.lx) * an.uprightW, (an.ry - an.ly) * an.uprightH)
            func upAt(_ dy: Float, _ base: SIMD2<Float>) -> SIMD2<Float> {
                let b = FaceTracker.toBuffer(base.x, base.y + dy * ed, an.rotation, an.bufW, an.bufH)
                return SIMD2(b.x / an.bufW, b.y / an.bufH)
            }
            let eL = SIMD2(an.lx * an.uprightW, an.ly * an.uprightH), eR = SIMD2(an.rx * an.uprightW, an.ry * an.uprightH)
            let mid = (eL + eR) / 2
            let c0 = upAt(0.45, eL), c1 = upAt(0.45, eR), c2 = upAt(-0.55, mid)
            u.skin01 = SIMD4(c0.x, c0.y, c1.x, c1.y)
            u.skin2.x = c2.x; u.skin2.y = c2.y
        }
        u.a = SIMD4(needMean ? o.smooth : 0, o[.brighten], o[.rosy], needMean ? o.sharpen : 0)
        let mkOn = faceMask != nil && mk != .none
        u.b = SIMD4(lutTex != nil && o.filter != .none ? o.filterIntensity : 0, mkOn ? o.makeupIntensity : 0,
                    mkOn && mk.lip != 0 ? o.makeupIntensity : 0, mkOn && mk.blush != 0 ? o.makeupIntensity : 0)
        let lipC = MetalBeauty.rgb(mk.lip), blushC = MetalBeauty.rgb(mk.blush)
        let shadowC = MetalBeauty.rgb(mk.shadow != 0 ? mk.shadow : 0xD89AA6)
        u.lip = SIMD4(lipC.x, lipC.y, lipC.z, o[.complexion])
        u.blush = SIMD4(blushC.x, blushC.y, blushC.z, o[.contour])
        u.shadowCol = SIMD4(shadowC.x, shadowC.y, shadowC.z, o[.light3d])
        let tone = o.tone.rgb
        u.tone = SIMD4(tone.x, tone.y, tone.z, needMean ? o[.darkCircles] : 0)
        u.c = SIMD4(needMean ? o[.smileLines] : 0, o[.brightEyes], o[.whiteTeeth], needMean ? o[.blemish] : 0)
        u.d = SIMD4(o[.lipstick], eyeAmt(o, .eyebrow), eyeAmt(o, .eyeshadow), eyeAmt(o, .eyelash))
        u.e = SIMD4(o[.lenses], o[.contrast], needMean ? o[.lowLight] : 0, 0)
        u.f = SIMD4(1 / Float(width), 1 / Float(height), Float(rotation), segRot)

        guard let fp = pipeline("vQuad", "fFinal", .bgra8Unorm), let enc = encoder(cb, outTex.0) else { return nil }
        enc.setRenderPipelineState(fp)
        let texs: [MTLTexture] = [s, mean, lutTex ?? blackT, faceMask ?? blackT, segT, bgT, regions ?? blackT, eyeArt ?? blackT, glassT]
        for (i, t) in texs.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.setFragmentBytes(&u, length: MemoryLayout<FinalU>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        if let m = mask, let an = face?.anchors { drawSticker(cb, m, an, outTex.0) }

        cb.commit()
        cb.waitUntilCompleted()
        keep.removeAll()
        CVMetalTextureCacheFlush(cache, 0)
        if cb.status == .error { return nil }

        if let faceBuf, let tracker { tracker.offer(faceBuf, rotation: rotation) }
        if let segBuf, let seg { seg.offer(segBuf, rotation: rotation) }
        if let snap, let snapBuf {
            let img = CIImage(cvPixelBuffer: snapBuf).oriented(FaceTracker.orientation(rotation))
            if let cg = ciContext.createCGImage(img, from: img.extent) {
                let ui = UIImage(cgImage: cg)
                DispatchQueue.main.async { snap(ui) }
            }
        }
        return out
    }

    // MARK: Face masks

    /// The face as a soft quarter-size mask: red = face skin (eyes, brows and
    /// lips cut out), green = lips 1 / open mouth 0.5, blue = cheeks for blush, alpha = eyes.
    private func drawFaceMask(_ cb: MTLCommandBuffer, _ face: FaceTracker.Face, _ width: Int, _ height: Int, _ makeup: Bool) -> MTLTexture {
        let w = Swift.max(width / 4, 2), h = Swift.max(height / 4, 2)
        let m1 = target(mask1, w, h, .rgba8Unorm); mask1 = m1
        let m2 = target(mask2, w, h, .rgba8Unorm); mask2 = m2
        if let enc = encoder(cb, m1, load: .clear) {
            setPoly(enc, .red)
            fan(enc, foreheadUp(face), 1)
            // Below the mouth: a lighter touch (beard or chin shadow).
            if let an = face.anchors, let lb = an.px("lipBottom"), let ch = an.px("chin") {
                let ed = hypotf((an.rx - an.lx) * an.uprightW, (an.ry - an.ly) * an.uprightH)
                let cx = (lb.x + ch.x) / 2, cy = (lb.y + ch.y) / 2
                var pts: [Float] = []
                for k in 0..<24 {
                    let t = Float(k) / 24 * 2 * Float.pi
                    let b = FaceTracker.toBuffer(cx + ed * 0.75 * cos(t), cy + ed * 0.55 * sin(t), an.rotation, an.bufW, an.bufH)
                    pts.append(b.x / an.bufW); pts.append(b.y / an.bufH)
                }
                fan(enc, pts, 0.4)
            }
            face.holes.forEach { fan(enc, $0, 0) }
            if let l = face.lips { fan(enc, l, 0) }
            setPoly(enc, .green)
            if let l = face.lips { fan(enc, l, 1) }
            if let mi = face.mouthIn { fan(enc, mi, 0.5) }
            setPoly(enc, .alpha)
            face.eyes.forEach { fan(enc, $0, 1) }
            if makeup, let a = face.anchors {
                setPoly(enc, .blue)
                let ed = hypotf((a.rx - a.lx) * a.uprightW, (a.ry - a.ly) * a.uprightH)
                for side: Float in [-1, 1] {
                    let ex = side < 0 ? a.lx * a.uprightW : a.rx * a.uprightW
                    let ey = side < 0 ? a.ly * a.uprightH : a.ry * a.uprightH
                    let cx = ex + side * ed * 0.12 * (a.rx > a.lx ? 1 : -1), cy = ey + ed * 0.62
                    let r = ed * 0.32
                    var pts: [Float] = []
                    for k in 0..<24 {
                        let t = Float(k) / 24 * 2 * Float.pi
                        let b = FaceTracker.toBuffer(cx + r * cos(t), cy + r * 0.8 * sin(t), a.rotation, a.bufW, a.bufH)
                        pts.append(b.x / a.bufW); pts.append(b.y / a.bufH)
                    }
                    fan(enc, pts, 1)
                }
            }
            enc.endEncoding()
        }
        // Feather the edges so the effect fades out at the jaw and hairline.
        quad(cb, m2, "fBlur", [m1], SIMD4(4 / Float(w), 0, 0, 0))
        quad(cb, m1, "fBlur", [m2], SIMD4(0, 4 / Float(h), 0, 0))
        // Cut eyes, brows and lips out again after feathering, slightly enlarged.
        if let enc = encoder(cb, m1, load: .load) {
            setPoly(enc, .red)
            for (i, hole) in face.holes.enumerated() { fan(enc, grow(hole, i < face.eyes.count ? 1.35 : 1.0), 0) }
            if let l = face.lips { fan(enc, grow(l, 1.12), 0) }
            enc.endEncoding()
        }
        return m1
    }

    /// The face outline with the forehead raised towards the hairline.
    private func foreheadUp(_ face: FaceTracker.Face) -> [Float] {
        guard let a = face.anchors, let ch = a.pts["chin"] else { return face.oval }
        func buf(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let b = FaceTracker.toBuffer(x * a.uprightW, y * a.uprightH, a.rotation, a.bufW, a.bufH)
            return SIMD2(b.x / a.bufW, b.y / a.bufH)
        }
        let e = buf((a.lx + a.rx) / 2, (a.ly + a.ry) / 2)
        let c = buf(ch[0], ch[1])
        let ux = e.x - c.x, uy = e.y - c.y
        let len2 = ux * ux + uy * uy
        if len2 < 1e-6 { return face.oval }
        var out = face.oval
        for i in 0..<(out.count / 2) {
            let t = ((out[i * 2] - e.x) * ux + (out[i * 2 + 1] - e.y) * uy) / len2
            if t > 0 { out[i * 2] += ux * t * 0.4; out[i * 2 + 1] += uy * t * 0.4 }
        }
        return out
    }

    private func needsRegions(_ o: AppBeautyOptions) -> Bool {
        o[.darkCircles] > 0 || o[.smileLines] > 0 || o[.light3d] > 0 || o[.contour] > 0
    }

    /// Region mask, quarter size: red = under the eyes, green = smile lines,
    /// blue = highlight zones, alpha = contour zones.
    private func drawRegions(_ cb: MTLCommandBuffer, _ a: FaceTracker.Anchors, _ width: Int, _ height: Int) -> MTLTexture {
        let w = Swift.max(width / 4, 2), h = Swift.max(height / 4, 2)
        let m3 = target(mask3, w, h, .rgba8Unorm); mask3 = m3
        let tmp = target(mask2, w, h, .rgba8Unorm); mask2 = tmp
        let lx = a.lx * a.uprightW, ly = a.ly * a.uprightH, rx = a.rx * a.uprightW, ry = a.ry * a.uprightH
        let ed = Swift.max(hypotf(rx - lx, ry - ly), 1)
        let ang = atan2f(ry - ly, rx - lx)
        let ux = cos(ang), uy = sin(ang), vx = -uy, vy = ux
        if let enc = encoder(cb, m3, load: .clear) {
            func ellipse(_ cx: Float, _ cy: Float, _ rAcross: Float, _ rDown: Float, _ extra: Float = 0) {
                let ca = cos(extra), sa = sin(extra)
                let ax = ux * ca + vx * sa, ay = uy * ca + vy * sa
                let bx = -ux * sa + vx * ca, by = -uy * sa + vy * ca
                var pts: [Float] = []
                for k in 0..<24 {
                    let t = Float(k) / 24 * 2 * Float.pi
                    let px = cx + (ax * cos(t) * rAcross + bx * sin(t) * rDown) * ed
                    let py = cy + (ay * cos(t) * rAcross + by * sin(t) * rDown) * ed
                    let b = FaceTracker.toBuffer(px, py, a.rotation, a.bufW, a.bufH)
                    pts.append(b.x / a.bufW); pts.append(b.y / a.bufH)
                }
                fan(enc, pts, 1)
            }
            func at(_ x: Float, _ y: Float, _ across: Float, _ down: Float) -> SIMD2<Float> {
                SIMD2(x + (ux * across + vx * down) * ed, y + (uy * across + vy * down) * ed)
            }
            // Under the eyes.
            setPoly(enc, .red)
            for (ex, ey) in [(lx, ly), (rx, ry)] { let c = at(ex, ey, 0, 0.3); ellipse(c.x, c.y, 0.3, 0.12) }
            // Smile lines: from each nose wing down to the mouth corner.
            setPoly(enc, .green)
            for (wing, corner) in [(a.px("wingL"), a.px("mouthL")), (a.px("wingR"), a.px("mouthR"))] {
                guard let wing, let corner else { continue }
                let mx = (wing.x + corner.x) / 2, my = (wing.y + corner.y) / 2
                let len = hypotf(corner.x - wing.x, corner.y - wing.y) / ed
                let segAng = atan2f(corner.y - wing.y, corner.x - wing.x) - ang
                let outward: Float = wing.x < (lx + rx) / 2 ? -0.08 : 0.08
                let c = at(mx, my, outward, 0)
                ellipse(c.x, c.y, len * 0.6, 0.07, segAng)
            }
            // Highlights.
            setPoly(enc, .blue)
            let ex = (lx + rx) / 2, ey = (ly + ry) / 2
            let fh = at(ex, ey, 0, -0.75); ellipse(fh.x, fh.y, 0.42, 0.2)
            if let tip = a.px("noseTip") { ellipse((ex + tip.x) / 2, (ey + tip.y) / 2, 0.07, 0.4) }
            if let ch = a.px("chin") { let c = at(ch.x, ch.y, 0, -0.22); ellipse(c.x, c.y, 0.22, 0.1) }
            for side: Float in [-1, 1] {
                let e = side < 0 ? SIMD2(lx, ly) : SIMD2(rx, ry)
                let c = at(e.x, e.y, 0.15 * side, 0.5); ellipse(c.x, c.y, 0.22, 0.08)
            }
            // Contour.
            setPoly(enc, .alpha)
            for (jaw, side) in [(SIMD2(a.jawLx * a.uprightW, a.jawLy * a.uprightH), Float(1)), (SIMD2(a.jawRx * a.uprightW, a.jawRy * a.uprightH), Float(-1))] {
                let c = at(jaw.x, jaw.y, 0.12 * side, -0.3); ellipse(c.x, c.y, 0.16, 0.45)
                let t = at(jaw.x, jaw.y, 0.08 * side, -1.35); ellipse(t.x, t.y, 0.12, 0.3)
            }
            enc.endEncoding()
        }
        // Feather.
        quad(cb, tmp, "fBlur", [m3], SIMD4(3 / Float(w), 0, 0, 0))
        quad(cb, m3, "fBlur", [tmp], SIMD4(0, 3 / Float(h), 0, 0))
        return m3
    }

    /// A Touch Up item, or the make-up look's share of it, whichever is stronger.
    private func eyeAmt(_ o: AppBeautyOptions, _ item: AppBeautyItem) -> Float {
        let mk = o.makeup
        let k: Float = mk == .none ? 0 : o.makeupIntensity
        let look: Float
        switch item {
        case .eyebrow: look = mk.brow
        case .eyeshadow: look = mk.shadowAmt
        case .eyelash: look = Swift.max(mk.lash, mk.liner)
        default: look = 0
        }
        return Swift.max(o[item], look * k)
    }

    private func needsEyeArt(_ o: AppBeautyOptions) -> Bool {
        eyeAmt(o, .eyebrow) > 0 || eyeAmt(o, .eyeshadow) > 0 || eyeAmt(o, .eyelash) > 0 || o[.lenses] > 0
    }

    /// Eye make-up mask, quarter size: red = brows, green = upper lids, blue = lash line, alpha = irises.
    private func drawEyeArt(_ cb: MTLCommandBuffer, _ face: FaceTracker.Face, _ width: Int, _ height: Int) -> MTLTexture? {
        guard let a = face.anchors else { return nil }
        let w = Swift.max(width / 4, 2), h = Swift.max(height / 4, 2)
        let m4 = target(mask4, w, h, .rgba8Unorm); mask4 = m4
        let tmp = target(mask2, w, h, .rgba8Unorm); mask2 = tmp
        let lx = a.lx * a.uprightW, ly = a.ly * a.uprightH, rx = a.rx * a.uprightW, ry = a.ry * a.uprightH
        let ed = Swift.max(hypotf(rx - lx, ry - ly), 1)
        let ux = (rx - lx) / ed, uy = (ry - ly) / ed, vx = -uy, vy = ux
        if let enc = encoder(cb, m4, load: .clear) {
            func ellipse(_ cx: Float, _ cy: Float, _ rA: Float, _ rD: Float) {
                var pts: [Float] = []
                for k in 0..<24 {
                    let t = Float(k) / 24 * 2 * Float.pi
                    let px = cx + (ux * cos(t) * rA + vx * sin(t) * rD) * ed
                    let py = cy + (uy * cos(t) * rA + vy * sin(t) * rD) * ed
                    let b = FaceTracker.toBuffer(px, py, a.rotation, a.bufW, a.bufH)
                    pts.append(b.x / a.bufW); pts.append(b.y / a.bufH)
                }
                fan(enc, pts, 1)
            }
            setPoly(enc, .red)
            face.holes.dropFirst(face.eyes.count).forEach { fan(enc, $0, 1) }
            for (ex, ey) in [(lx, ly), (rx, ry)] {
                setPoly(enc, .green)
                ellipse(ex - vx * ed * 0.14, ey - vy * ed * 0.14, 0.3, 0.13)
                setPoly(enc, .blue)
                ellipse(ex - vx * ed * 0.06, ey - vy * ed * 0.06, 0.29, 0.05)
                setPoly(enc, .alpha)
                ellipse(ex, ey, 0.09, 0.09)
            }
            enc.endEncoding()
        }
        quad(cb, tmp, "fBlur", [m4], SIMD4(1.2 / Float(w), 0, 0, 0))
        quad(cb, m4, "fBlur", [tmp], SIMD4(0, 1.2 / Float(h), 0, 0))
        return m4
    }

    // MARK: Background

    /// A strongly blurred eighth-size copy of the frame for the blurred background.
    private func blurredBackground(_ cb: MTLCommandBuffer, _ s: MTLTexture, _ strength: Float) -> MTLTexture {
        let w = Swift.max(s.width / 8, 2), h = Swift.max(s.height / 8, 2)
        let a = target(bgSmall, w, h, .rgba8Unorm); bgSmall = a
        let b = target(bgSmall2, w, h, .rgba8Unorm); bgSmall2 = b
        quad(cb, a, "fCopy", [s])
        for _ in 0..<2 {
            quad(cb, b, "fBlur", [a], SIMD4(strength / Float(w), 0, 0, 0))
            quad(cb, a, "fBlur", [b], SIMD4(0, strength / Float(h), 0, 0))
        }
        return a
    }

    /// The upright scene for `bg`, or nil while its picture is not on the device (it is fetched).
    private func sceneTexture(_ bg: AppBeautyBackground) -> MTLTexture? {
        if bg == .custom {
            lock.lock(); let img = _customBackground; let ver = customVersion; lock.unlock()
            guard let img else { return nil }
            if sceneFor != bg || customUploaded != ver || sceneTex == nil {
                sceneTex = imageTexture(img, maxSide: 1280)
                customUploaded = ver; sceneFor = bg
            }
            return sceneTex
        }
        guard let name = bg.asset else { return nil }
        if sceneFor != bg || sceneTex == nil {
            guard let img = ready(name, base: BeautyCatalog.shared.cdnBg) else { return nil }
            sceneTex = imageTexture(img, maxSide: 1280)
            sceneFor = bg
        }
        return sceneTex
    }

    private func glassTexture(_ bg: AppBeautyBackground) -> MTLTexture? {
        guard let name = bg.glass else { return nil }
        if glassFor != bg || glassTex == nil {
            guard let img = ready(name, base: BeautyCatalog.shared.cdnBg) else { return nil }
            glassTex = imageTexture(img, maxSide: 1024)
            glassFor = bg
        }
        return glassTex
    }

    /// The cached picture `name`, or nil after starting its download.
    private func ready(_ name: String, base: String) -> UIImage? {
        if let img = BeautyAssets.image(name) { return img }
        lock.lock()
        let start = !fetching.contains(name)
        if start { fetching.insert(name) }
        lock.unlock()
        if start {
            BeautyAssets.fetch(base: base, names: [name]) { [weak self] _ in
                DispatchQueue.main.async { self?.fetchDone(name) }
            }
        }
        return nil
    }

    private func fetchDone(_ name: String) { lock.lock(); _ = fetching.remove(name); lock.unlock() }

    private func uploadSeg(_ seg: SegTracker, _ m: SegTracker.Mask) -> MTLTexture? {
        if segTex == nil || segTex!.width != m.width || segTex!.height != m.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: m.width, height: m.height, mipmapped: false)
            d.usage = .shaderRead
            segTex = device.makeTexture(descriptor: d)
            segVersion = -1
        }
        guard let t = segTex else { return nil }
        let v = seg.version
        if v != segVersion {
            segVersion = v
            m.bytes.withUnsafeBytes { p in
                if let base = p.baseAddress {
                    t.replace(region: MTLRegionMake2D(0, 0, m.width, m.height), mipmapLevel: 0, withBytes: base, bytesPerRow: m.width)
                }
            }
        }
        return t
    }

    // MARK: Mask stickers

    private func maskTexture(_ name: String) -> (MTLTexture, Float)? {
        if let t = maskTex[name] { return t }
        guard let img = ready(name, base: BeautyCatalog.shared.cdnMask), let t = imageTexture(img, maxSide: 512) else { return nil }
        let aspect = Float(img.size.height / Swift.max(img.size.width, 1))
        if maskTex.count > 12 { maskTex.removeAll() }
        maskTex[name] = (t, aspect)
        return (t, aspect)
    }

    /// Draws `m`'s layers over the output, each placed from the face anchors on
    /// the upright image: the face's own frame, sizes in eye-distances.
    private func drawSticker(_ cb: MTLCommandBuffer, _ m: AppMask, _ a: FaceTracker.Anchors, _ out: MTLTexture) {
        let W = a.uprightW, H = a.uprightH
        let lx = a.lx * W, ly = a.ly * H, rx = a.rx * W, ry = a.ry * H
        let ed = hypotf(rx - lx, ry - ly)
        if ed < 2 { return }
        let ux = (rx - lx) / ed, uy = (ry - ly) / ed
        let vx = -uy, vy = ux
        let ex = (lx + rx) / 2, ey = (ly + ry) / 2
        func along(_ p: SIMD2<Float>) -> Float { (p.x - ex) * vx + (p.y - ey) * vy }
        guard let p = pipeline("vSticker", "fSticker", .bgra8Unorm, blend: true), let enc = encoder(cb, out, load: .load) else { return }
        enc.setRenderPipelineState(p)
        for layer in m.layers {
            guard let mt = maskTexture(layer.image) else { continue }
            let tex = mt.0, aspect = mt.1
            let w = ed * layer.width, h = w * aspect
            let sides: [Float]
            switch layer.anchor {
            case .cheeks: sides = [-1, 1]
            case .cheekLeft: sides = [-1]
            case .cheekRight: sides = [1]
            default: sides = [0]
            }
            for side in sides {
                var bx: Float = 0, by: Float = 0
                switch layer.anchor {
                case .head:
                    let top = a.px("top") ?? SIMD2(a.topX * W, a.topY * H)
                    by = along(top) / ed - aspect * layer.width / 2
                case .forehead: by = -0.8
                case .eyes: by = 0
                case .nose: by = a.px("noseTip").map { along($0) / ed } ?? 0.75
                case .mouth: by = a.px("mouthC").map { along($0) / ed } ?? 1.25
                case .chin: by = a.px("chin").map { along($0) / ed } ?? 1.9
                case .face: by = 0.55
                case .cheeks, .cheekLeft, .cheekRight: bx = side * 0.95; by = 0.5
                }
                let cxF = bx + layer.dx * (side != 0 ? side : 1)
                let cyF = by + layer.dy
                let cx = ex + (ux * cxF + vx * cyF) * ed
                let cy = ey + (uy * cxF + vy * cyF) * ed
                let hw = w / 2, hh = h / 2
                let corners: [SIMD2<Float>] = [
                    SIMD2(cx - ux * hw - vx * hh, cy - uy * hw - vy * hh),
                    SIMD2(cx + ux * hw - vx * hh, cy + uy * hw - vy * hh),
                    SIMD2(cx - ux * hw + vx * hh, cy - uy * hw + vy * hh),
                    SIMD2(cx + ux * hw + vx * hh, cy + uy * hw + vy * hh),
                ]
                // The right cheek's copy is mirrored.
                let uv: [SIMD2<Float>] = side > 0 && layer.anchor == .cheeks
                    ? [SIMD2(1, 0), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)]
                    : [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
                var verts: [SIMD4<Float>] = []
                for i in 0..<4 {
                    let b = FaceTracker.toBuffer(corners[i].x, corners[i].y, a.rotation, a.bufW, a.bufH)
                    verts.append(SIMD4(b.x / a.bufW, b.y / a.bufH, uv[i].x, uv[i].y))
                }
                enc.setVertexBytes(verts, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()
    }

    // MARK: Helpers

    static func rgb(_ c: UInt32) -> SIMD3<Float> {
        SIMD3(Float((c >> 16) & 0xFF) / 255, Float((c >> 8) & 0xFF) / 255, Float(c & 0xFF) / 255)
    }

    private func pipeline(_ v: String, _ f: String, _ fmt: MTLPixelFormat, mask: MTLColorWriteMask = .all, blend: Bool = false) -> MTLRenderPipelineState? {
        let key = "\(v)|\(f)|\(fmt.rawValue)|\(mask.rawValue)|\(blend)"
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: v)
        d.fragmentFunction = library.makeFunction(name: f)
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = fmt
        ca.writeMask = mask
        if blend {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipelines[key] = p
        return p
    }

    private func encoder(_ cb: MTLCommandBuffer, _ t: MTLTexture, load: MTLLoadAction = .dontCare) -> MTLRenderCommandEncoder? {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = t
        d.colorAttachments[0].loadAction = load
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        d.colorAttachments[0].storeAction = .store
        return cb.makeRenderCommandEncoder(descriptor: d)
    }

    /// A full-frame pass of fragment function `f` into `target`.
    private func quad(_ cb: MTLCommandBuffer, _ target: MTLTexture, _ f: String, _ textures: [MTLTexture], _ params: SIMD4<Float>? = nil) {
        guard let p = pipeline("vQuad", f, target.pixelFormat), let enc = encoder(cb, target) else { return }
        enc.setRenderPipelineState(p)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        if var params { enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func setPoly(_ enc: MTLRenderCommandEncoder, _ mask: MTLColorWriteMask) {
        if let p = pipeline("vPoly", "fPoly", .rgba8Unorm, mask: mask) { enc.setRenderPipelineState(p) }
    }

    /// A filled outline (flat x, y pairs in buffer uv) as a fan from its centroid.
    private func fan(_ enc: MTLRenderCommandEncoder, _ pts: [Float], _ value: Float) {
        let n = pts.count / 2
        if n < 3 || n > 250 { return }
        var cx: Float = 0, cy: Float = 0
        for i in 0..<n { cx += pts[i * 2]; cy += pts[i * 2 + 1] }
        cx /= Float(n); cy /= Float(n)
        var tri: [SIMD2<Float>] = []
        tri.reserveCapacity(n * 3)
        for i in 0..<n {
            let j = (i + 1) % n
            tri.append(SIMD2(cx, cy))
            tri.append(SIMD2(pts[i * 2], pts[i * 2 + 1]))
            tri.append(SIMD2(pts[j * 2], pts[j * 2 + 1]))
        }
        let length = MemoryLayout<SIMD2<Float>>.stride * tri.count
        guard let buf = device.makeBuffer(bytes: tri, length: length, options: .storageModeShared) else { return }
        var v = SIMD4<Float>(value, value, value, value)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setFragmentBytes(&v, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: tri.count)
    }

    /// `pts` scaled by `k` about their centroid.
    private func grow(_ pts: [Float], _ k: Float) -> [Float] {
        let n = pts.count / 2
        if n == 0 { return pts }
        var cx: Float = 0, cy: Float = 0
        for i in 0..<n { cx += pts[i * 2]; cy += pts[i * 2 + 1] }
        cx /= Float(n); cy /= Float(n)
        return pts.indices.map { i in i % 2 == 0 ? cx + (pts[i] - cx) * k : cy + (pts[i] - cy) * k }
    }

    private func target(_ old: MTLTexture?, _ w: Int, _ h: Int, _ fmt: MTLPixelFormat) -> MTLTexture {
        if let old, old.width == w, old.height == h, old.pixelFormat == fmt { return old }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func blackTexture() -> MTLTexture {
        if let black { return black }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        let px: [UInt8] = [0, 0, 0, 0]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: 4)
        black = t
        return t
    }

    private func uploadLutIfNeeded() {
        lock.lock()
        let dirty = lutDirty, bytes = lutBytes
        lutDirty = false
        lock.unlock()
        guard dirty else { return }
        guard let bytes else { lutTex = nil; return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 512, height: 512, mipmapped: false)
        d.usage = .shaderRead
        guard let t = lutTex ?? device.makeTexture(descriptor: d) else { return }
        t.replace(region: MTLRegionMake2D(0, 0, 512, 512), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 512 * 4)
        lutTex = t
    }

    /// An upright picture as a premultiplied RGBA texture, row 0 at the top.
    private func imageTexture(_ image: UIImage, maxSide: Int) -> MTLTexture? {
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = Swift.min(1, CGFloat(maxSide) / Swift.max(size.width, size.height))
        let w = Swift.max(Int(size.width * scale), 1), h = Swift.max(Int(size.height * scale), 1)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            UIGraphicsPopContext()
            return true
        }
        guard ok else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    private func cvTexture(_ pb: CVPixelBuffer, plane: Int, _ fmt: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, fmt, w, h, plane, &cv)
        guard r == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return (t, cv)
    }

    private static func makePool(_ w: Int, _ h: Int, min: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: min] as CFDictionary,
                                attrs as CFDictionary, &p)
        return p
    }

    private func outputBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if outPool == nil || outKey != (w, h) { outPool = MetalBeauty.makePool(w, h, min: 4); outKey = (w, h) }
        guard let pool = outPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    /// A quarter-size BGRA copy of `s` (buffer orientation) for the detectors and the panel.
    private func small(_ cb: MTLCommandBuffer, _ s: MTLTexture, _ keep: inout [CVMetalTexture]) -> CVPixelBuffer? {
        let w = Swift.max(s.width / 4, 2), h = Swift.max(s.height / 4, 2)
        if smallPool == nil || smallKey != (w, h) { smallPool = MetalBeauty.makePool(w, h, min: 3); smallKey = (w, h) }
        guard let pool = smallPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let pb, let t = cvTexture(pb, plane: 0, .bgra8Unorm) else { return nil }
        keep.append(t.1)
        quad(cb, t.0, "fCopy", [s])
        return pb
    }
}
