import Foundation

/// Beauty settings. `values` holds the strength of each `AppBeautyItem`
/// (missing = 0). `enabled` is the Beauty tab's on/off switch: off leaves every
/// item out but keeps make-up and the filter.
public struct AppBeautyOptions: Equatable {
    public var values: [AppBeautyItem: Float]
    public var tone: AppBeautyTone
    public var filter: AppBeautyFilter
    public var filterIntensity: Float
    public var makeup: AppBeautyMakeup
    public var makeupIntensity: Float
    public var enabled: Bool

    public init(values: [AppBeautyItem: Float] = [:], tone: AppBeautyTone = .t01,
                filter: AppBeautyFilter = .none, filterIntensity: Float = 0.8,
                makeup: AppBeautyMakeup = .none, makeupIntensity: Float = 0.6, enabled: Bool = true) {
        self.values = values
        self.tone = tone
        self.filter = filter
        self.filterIntensity = filterIntensity
        self.makeup = makeup
        self.makeupIntensity = makeupIntensity
        self.enabled = enabled
    }

    /// The strength of `item` in force (0 when the Beauty switch is off).
    public subscript(item: AppBeautyItem) -> Float { enabled ? (values[item] ?? 0) : 0 }

    /// A copy with `item` set to `value`.
    public func with(_ item: AppBeautyItem, _ value: Float) -> AppBeautyOptions {
        var c = self
        if value == 0 { c.values.removeValue(forKey: item) } else { c.values[item] = value }
        return c
    }

    public var smooth: Float { self[.smooth] }
    public var sharpen: Float { self[.sharpen] }

    /// Every strength clamped to its range.
    public func clamped() -> AppBeautyOptions {
        var c = self
        var v: [AppBeautyItem: Float] = [:]
        for (k, x) in values where x.isFinite {
            let y = Swift.min(Swift.max(x, k.min), 1)
            if y != 0 { v[k] = y }
        }
        c.values = v
        c.filterIntensity = filterIntensity.isFinite ? Swift.min(Swift.max(filterIntensity, 0), 1) : 0
        c.makeupIntensity = makeupIntensity.isFinite ? Swift.min(Swift.max(makeupIntensity, 0), 1) : 0
        return c
    }

    /// All strengths scaled by `f` (used to ease the look in).
    func scaled(_ f: Float) -> AppBeautyOptions {
        var c = self
        c.values = values.mapValues { $0 * f }
        c.filterIntensity = filterIntensity * f
        c.makeupIntensity = makeupIntensity * f
        return c
    }

    /// True when these options change nothing.
    public var isNeutral: Bool {
        (!enabled || values.values.allSatisfy { $0 == 0 }) &&
            (filter == .none || filterIntensity <= 0) &&
            (makeup == .none || makeupIntensity <= 0)
    }

    /// Options from item/value pairs.
    public static func of(_ items: [AppBeautyItem: Float], filter: AppBeautyFilter = .none, filterIntensity: Float = 0.8,
                          makeup: AppBeautyMakeup = .none, makeupIntensity: Float = 0.6) -> AppBeautyOptions {
        AppBeautyOptions(values: items, filter: filter, filterIntensity: filterIntensity, makeup: makeup, makeupIntensity: makeupIntensity)
    }
}
