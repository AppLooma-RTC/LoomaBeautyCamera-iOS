import Foundation

/// Colour filters as 512x512 lookup tables (an 8x8 grid of 64x64 tiles: blue
/// picks the tile, red runs along x, green along y). Generated from colour
/// maths at first use, so no image assets ship with the package.
enum Luts {
    private static let lock = NSLock()
    private static var cache: [String: [UInt8]] = [:]

    /// RGBA bytes of the table for `filter`, row 0 first; nil for no filter.
    static func rgba(_ filter: AppBeautyFilter) -> [UInt8]? {
        if filter == .none { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[filter.id] { return c }
        let px = pixels(transformOf(filter))
        cache[filter.id] = px
        return px
    }

    static func pixels(_ f: (SIMD3<Float>) -> SIMD3<Float>) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: 512 * 512 * 4)
        for b in 0..<64 {
            let tx = (b % 8) * 64, ty = (b / 8) * 64
            for g in 0..<64 {
                for r in 0..<64 {
                    let o = f(SIMD3(Float(r) / 63, Float(g) / 63, Float(b) / 63))
                    let i = ((ty + g) * 512 + tx + r) * 4
                    px[i] = UInt8(clamp(o.x) * 255 + 0.5)
                    px[i + 1] = UInt8(clamp(o.y) * 255 + 0.5)
                    px[i + 2] = UInt8(clamp(o.z) * 255 + 0.5)
                }
            }
        }
        return px
    }

    private static func clamp(_ v: Float) -> Float { Swift.min(1, Swift.max(0, v)) }
    private static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    private static func saturate(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let l = luma(c)
        return SIMD3(l + (c.x - l) * s, l + (c.y - l) * s, l + (c.z - l) * s)
    }

    private static func contrast(_ c: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        SIMD3((c.x - 0.5) * k + 0.5, (c.y - 0.5) * k + 0.5, (c.z - 0.5) * k + 0.5)
    }

    private static func lift(_ c: SIMD3<Float>, _ black: Float) -> SIMD3<Float> {
        SIMD3(black + c.x * (1 - black), black + c.y * (1 - black), black + c.z * (1 - black))
    }

    /// The filter's colour transform (the same maths on every platform).
    static func transformOf(_ f: AppBeautyFilter) -> (SIMD3<Float>) -> SIMD3<Float> {
        return { c in
            var o = SIMD3(c.x + f.exp, c.y + f.exp, c.z + f.exp)
            o.x += f.warm * 0.06
            o.z -= f.warm * 0.06
            o.y += f.tint * 0.04
            if f.mono { let l = luma(o); o = SIMD3(l, l, l) }
            o = saturate(o, f.sat)
            o = contrast(o, f.con)
            if f.lift > 0 { o = lift(o, f.lift) }
            return o
        }
    }
}
