//
// The beauty catalogue: items, filters, make-up looks, presets, backgrounds
// and masks. Read from the bundled beauty-catalog.json, the same file every
// platform ships, so the panels look the same everywhere.
//

import Foundation

/// The groups of the Beauty tab.
public enum AppBeautyGroup: String, CaseIterable {
    case skin = "SKIN", touchUp = "TOUCH_UP", face = "FACE", eyes = "EYES", nose = "NOSE", mouth = "MOUTH"

    public var title: String {
        switch self {
        case .skin: return "Skin"
        case .touchUp: return "Touch Up"
        case .face: return "Face"
        case .eyes: return "Eyes"
        case .nose: return "Nose"
        case .mouth: return "Mouth"
        }
    }
}

/// One adjustment of the Beauty tab. Strengths run 0...1; a `bipolar` item
/// runs -1...1 with 0 meaning unchanged.
public enum AppBeautyItem: String, CaseIterable {
    // Skin
    case smooth = "SMOOTH"
    case complexion = "COMPLEXION"
    case contour = "CONTOUR"
    case light3d = "LIGHT_3D"
    case brighten = "BRIGHTEN"
    case rosy = "ROSY"
    case contrast = "CONTRAST"
    case sharpen = "SHARPEN"
    case lowLight = "LOW_LIGHT"
    // Touch up
    case lipstick = "LIPSTICK"
    case eyebrow = "EYEBROW"
    case eyeshadow = "EYESHADOW"
    case eyelash = "EYELASH"
    case lenses = "LENSES"
    case blemish = "BLEMISH"
    // Face
    case slimFace = "SLIM_FACE"
    case vFace = "V_FACE"
    case cheekbone = "CHEEKBONE"
    case chin = "CHIN"
    case temple = "TEMPLE"
    case forehead = "FOREHEAD"
    case faceShrink = "FACE_SHRINK"
    case chinShape = "CHIN_SHAPE"
    case shortFace = "SHORT_FACE"
    case jaw = "JAW"
    // Eyes
    case bigEyes = "BIG_EYES"
    case pupils = "PUPILS"
    case brightEyes = "BRIGHT_EYES"
    case darkCircles = "DARK_CIRCLES"
    case eyelid = "EYELID"
    case browHeight = "BROW_HEIGHT"
    case eyeHeight = "EYE_HEIGHT"
    case eyeAngle = "EYE_ANGLE"
    case browShape = "BROW_SHAPE"
    case browTrim = "BROW_TRIM"
    case eyeDistance = "EYE_DISTANCE"
    // Nose
    case smileLines = "SMILE_LINES"
    case noseTip = "NOSE_TIP"
    case philtrum = "PHILTRUM"
    case slimNose = "SLIM_NOSE"
    case noseNarrow = "NOSE_NARROW"
    case bridge = "BRIDGE"
    case nasalBridge = "NASAL_BRIDGE"
    case noseWing = "NOSE_WING"
    // Mouth
    case mouthWidth = "MOUTH_WIDTH"
    case whiteTeeth = "WHITE_TEETH"
    case fullLip = "FULL_LIP"
    case mouthSize = "MOUTH_SIZE"
    case mouthHeight = "MOUTH_HEIGHT"
    case smile = "SMILE"

    public var group: AppBeautyGroup { BeautyCatalog.shared.items[rawValue]?.group ?? .skin }
    public var title: String { BeautyCatalog.shared.items[rawValue]?.title ?? rawValue }
    /// Runs -1...1 (0 = unchanged). Fixed in code: it is read while the catalogue loads.
    public var bipolar: Bool {
        switch self {
        case .contrast, .chin, .temple, .forehead, .browHeight, .eyeHeight, .eyeAngle, .browShape, .eyeDistance,
             .noseTip, .philtrum, .mouthWidth, .fullLip, .mouthSize, .mouthHeight:
            return true
        default:
            return false
        }
    }
    var min: Float { bipolar ? -1 : 0 }

    /// Face-shape items. Version 0.1.0 of the iOS camera does not reshape the
    /// face: these are kept in the options and shown in the panel, but draw nothing.
    public var isReshape: Bool {
        switch self {
        case .slimFace, .vFace, .cheekbone, .chin, .temple, .forehead, .faceShrink, .chinShape, .shortFace, .jaw,
             .bigEyes, .pupils, .eyelid, .browHeight, .eyeHeight, .eyeAngle, .browShape, .browTrim, .eyeDistance,
             .noseTip, .philtrum, .slimNose, .noseNarrow, .bridge, .nasalBridge, .noseWing,
             .mouthWidth, .fullLip, .mouthSize, .mouthHeight, .smile:
            return true
        default:
            return false
        }
    }
}

/// Foundation shades for `AppBeautyItem.complexion`, light to deep.
public enum AppBeautyTone: String, CaseIterable {
    case t01 = "T01", t02 = "T02", t03 = "T03", t04 = "T04"
    var rgb: SIMD3<Float> {
        switch self {
        case .t01: return SIMD3(0.97, 0.82, 0.74)
        case .t02: return SIMD3(0.91, 0.73, 0.59)
        case .t03: return SIMD3(0.79, 0.59, 0.43)
        case .t04: return SIMD3(0.62, 0.43, 0.30)
        }
    }
}

/// A category of filters, make-up looks or backgrounds (a tab in a panel).
public struct AppBeautyCategory: Hashable {
    public let id: String
    public let title: String
}

/// A colour filter: a small set of colour moves turned into a lookup table.
public struct AppBeautyFilter: Hashable {
    public let id: String
    public let category: String?
    public let title: String
    let warm: Float, tint: Float, sat: Float, con: Float, lift: Float, exp: Float, mono: Bool

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    /// No filter.
    public static let none = AppBeautyFilter(id: "NONE", category: nil, title: "Off", warm: 0, tint: 0, sat: 1, con: 1, lift: 0, exp: 0, mono: false)
    /// Every filter, "Off" first.
    public static var all: [AppBeautyFilter] { BeautyCatalog.shared.filters }
    public static var categories: [AppBeautyCategory] { BeautyCatalog.shared.filterCategories }
    /// The filter with this id (for example "NATURAL"), or nil.
    public static func named(_ id: String) -> AppBeautyFilter? { all.first { $0.id == id } }
}

/// A full make-up look: lip, blush and eyeshadow colours and how much
/// eyeshadow, liner, brow and lash it carries, plus its colour filter.
public struct AppBeautyMakeup: Hashable {
    public let id: String
    public let category: String?
    public let title: String
    /// 0xRRGGBB, 0 = none.
    let lip: UInt32, blush: UInt32, shadow: UInt32
    let shadowAmt: Float, liner: Float, brow: Float, lash: Float
    let filterId: String
    let card: String?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    /// The colour filter that comes with the look.
    public var lookFilter: AppBeautyFilter { AppBeautyFilter.named(filterId) ?? .none }

    public static let none = AppBeautyMakeup(id: "NONE", category: nil, title: "Off", lip: 0, blush: 0, shadow: 0,
                                             shadowAmt: 0, liner: 0, brow: 0, lash: 0, filterId: "NONE", card: nil)
    public static var all: [AppBeautyMakeup] { BeautyCatalog.shared.makeup }
    public static var categories: [AppBeautyCategory] { BeautyCatalog.shared.makeupCategories }
    public static func named(_ id: String) -> AppBeautyMakeup? { all.first { $0.id == id } }
}

/// What replaces the background behind the person: a scene picture, the
/// camera's own background blurred, the blurred background behind frosted
/// glass, or `.custom` (see `AppBeauty.customBackground`). iOS 15 or later.
public struct AppBeautyBackground: Hashable {
    public let id: String
    public let category: String?
    public let title: String
    let blur: Float
    let asset: String?
    let glass: String?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public static let none = AppBeautyBackground(id: "NONE", category: nil, title: "Off", blur: 0, asset: nil, glass: nil)
    public static let custom = AppBeautyBackground(id: "CUSTOM", category: "CUSTOM", title: "Custom", blur: 0, asset: nil, glass: nil)
    public static var all: [AppBeautyBackground] { BeautyCatalog.shared.backgrounds }
    public static var categories: [AppBeautyCategory] { BeautyCatalog.shared.backgroundCategories }
    public static func named(_ id: String) -> AppBeautyBackground? { all.first { $0.id == id } }

    /// Pictures that must be downloaded before this background shows.
    var remoteNames: [String] { [asset, glass].compactMap { $0 } }
}

/// Where on the face a mask layer sits.
public enum AppMaskAnchor: String {
    /// On the head: the layer's bottom edge sits on the hairline (moved down by `dy`).
    case head = "HEAD"
    case forehead = "FOREHEAD", eyes = "EYES", nose = "NOSE", mouth = "MOUTH", chin = "CHIN"
    /// One copy on each cheek, the right one mirrored.
    case cheeks = "CHEEKS", cheekLeft = "CHEEK_LEFT", cheekRight = "CHEEK_RIGHT"
    /// The middle of the face, for full-face pieces.
    case face = "FACE"
}

/// One picture of a mask. Sizes and offsets are in eye-distances.
public struct AppMaskLayer {
    public let image: String
    public let anchor: AppMaskAnchor
    public let width: Float
    public let dx: Float
    public let dy: Float
}

/// A face mask: one or more layers that follow the head.
public struct AppMask: Hashable {
    public let id: String
    public let title: String
    public let categories: [String]
    public let layers: [AppMaskLayer]
    let thumb: String

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// The built-in mask catalogue (Magic, Mask).
public enum AppMasks {
    /// Category names in panel order.
    public static var categories: [String] { BeautyCatalog.shared.maskCategories }
    /// Every mask.
    public static var all: [AppMask] { BeautyCatalog.shared.masks }
    public static func byId(_ id: String) -> AppMask? { all.first { $0.id == id } }
    public static func inCategory(_ c: String) -> [AppMask] { all.filter { $0.categories.contains(c) } }
}

/// A one-tap look, shown with a title card when chosen.
public struct AppBeautyPreset: Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let tag: String
    public let options: AppBeautyOptions
    let card: String?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public static var all: [AppBeautyPreset] { BeautyCatalog.shared.presets }
    public static func named(_ id: String) -> AppBeautyPreset? { all.first { $0.id == id } }
    /// Smart Beauty, the default look.
    public static var smart: AppBeautyPreset { named(BeautyCatalog.shared.defaultPreset) ?? all.first! }
}

/// Parsed beauty-catalog.json.
final class BeautyCatalog {
    struct ItemInfo { let group: AppBeautyGroup; let title: String; let bipolar: Bool }

    static let shared = BeautyCatalog()

    private(set) var cdnBg = "https://assets.applooma.dev/beauty/v1/bg/"
    private(set) var cdnMask = "https://assets.applooma.dev/beauty/v2/mask/"
    private(set) var cdnCards = "https://assets.applooma.dev/beauty/v1/cards/"
    private(set) var items: [String: ItemInfo] = [:]
    private(set) var filters: [AppBeautyFilter] = [.none]
    private(set) var filterCategories: [AppBeautyCategory] = []
    private(set) var makeup: [AppBeautyMakeup] = [.none]
    private(set) var makeupCategories: [AppBeautyCategory] = []
    private(set) var backgrounds: [AppBeautyBackground] = [.none]
    private(set) var backgroundCategories: [AppBeautyCategory] = []
    private(set) var masks: [AppMask] = []
    private(set) var maskCategories: [String] = []
    private(set) var presets: [AppBeautyPreset] = []
    private(set) var defaultPreset = "SMART"

    private init() {
        guard let url = Bundle.module.url(forResource: "beauty-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            presets = [AppBeautyPreset(id: "SMART", title: "Smart Beauty", subtitle: "", tag: "", options: AppBeautyOptions(), card: nil)]
            return
        }
        parse(root)
    }

    private static func f(_ v: Any?, _ d: Float = 0) -> Float {
        if let n = v as? NSNumber { return n.floatValue }
        return d
    }

    private static func s(_ v: Any?) -> String? { v as? String }

    private static func hex(_ v: Any?) -> UInt32 {
        guard var t = v as? String else { return 0 }
        if t.hasPrefix("#") { t.removeFirst() }
        return UInt32(t, radix: 16) ?? 0
    }

    private static func cats(_ v: Any?) -> [AppBeautyCategory] {
        ((v as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return AppBeautyCategory(id: id, title: (o["title"] as? String) ?? id)
        }
    }

    private func parse(_ root: [String: Any]) {
        typealias C = BeautyCatalog
        if let cdn = root["cdn"] as? [String: Any] {
            cdnBg = C.s(cdn["bg"]) ?? cdnBg
            cdnMask = C.s(cdn["mask"]) ?? cdnMask
            cdnCards = C.s(cdn["cards"]) ?? cdnCards
        }
        for o in (root["items"] as? [[String: Any]]) ?? [] {
            guard let id = o["id"] as? String else { continue }
            items[id] = ItemInfo(group: AppBeautyGroup(rawValue: C.s(o["group"]) ?? "") ?? .skin,
                                 title: C.s(o["title"]) ?? id, bipolar: (o["bipolar"] as? Bool) ?? false)
        }
        filterCategories = C.cats(root["filterCategories"])
        filters = ((root["filters"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            if id == "NONE" { return AppBeautyFilter.none }
            return AppBeautyFilter(id: id, category: C.s(o["category"]), title: C.s(o["title"]) ?? id,
                                   warm: C.f(o["warm"]), tint: C.f(o["tint"]), sat: C.f(o["sat"], 1), con: C.f(o["con"], 1),
                                   lift: C.f(o["lift"]), exp: C.f(o["exp"]), mono: (o["mono"] as? Bool) ?? false)
        }
        if filters.first?.id != "NONE" { filters.insert(.none, at: 0) }
        makeupCategories = C.cats(root["makeupCategories"])
        makeup = ((root["makeup"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            if id == "NONE" { return AppBeautyMakeup.none }
            return AppBeautyMakeup(id: id, category: C.s(o["category"]), title: C.s(o["title"]) ?? id,
                                   lip: C.hex(o["lip"]), blush: C.hex(o["blush"]), shadow: C.hex(o["shadow"]),
                                   shadowAmt: C.f(o["shadowAmt"]), liner: C.f(o["liner"]), brow: C.f(o["brow"]), lash: C.f(o["lash"]),
                                   filterId: C.s(o["filter"]) ?? "NONE", card: C.s(o["card"]))
        }
        if makeup.first?.id != "NONE" { makeup.insert(.none, at: 0) }
        backgroundCategories = C.cats(root["backgroundCategories"])
        backgrounds = ((root["backgrounds"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            if id == "NONE" { return AppBeautyBackground.none }
            if id == "CUSTOM" { return AppBeautyBackground.custom }
            return AppBeautyBackground(id: id, category: C.s(o["category"]), title: C.s(o["title"]) ?? id,
                                       blur: C.f(o["blur"]), asset: C.s(o["asset"]), glass: C.s(o["glass"]))
        }
        if backgrounds.first?.id != "NONE" { backgrounds.insert(.none, at: 0) }
        maskCategories = (root["maskCategories"] as? [String]) ?? []
        masks = ((root["masks"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            let layers: [AppMaskLayer] = ((o["layers"] as? [[String: Any]]) ?? []).compactMap { l in
                guard let img = l["img"] as? String, let at = AppMaskAnchor(rawValue: C.s(l["at"]) ?? "") else { return nil }
                return AppMaskLayer(image: img, anchor: at, width: C.f(l["w"], 1), dx: C.f(l["dx"]), dy: C.f(l["dy"]))
            }
            return AppMask(id: id, title: C.s(o["title"]) ?? id, categories: (o["categories"] as? [String]) ?? [],
                           layers: layers, thumb: C.s(o["thumb"]) ?? "thumb_mask_\(id).jpg")
        }
        defaultPreset = C.s(root["default"]) ?? "SMART"
        presets = ((root["presets"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            var values: [AppBeautyItem: Float] = [:]
            for (k, v) in (o["values"] as? [String: Any]) ?? [:] {
                if let item = AppBeautyItem(rawValue: k) { values[item] = C.f(v) }
            }
            let opts = AppBeautyOptions(values: values, tone: .t01,
                                        filter: filters.first { $0.id == (C.s(o["filter"]) ?? "NONE") } ?? .none,
                                        filterIntensity: C.f(o["filterIntensity"], 0.8),
                                        makeup: makeup.first { $0.id == (C.s(o["makeup"]) ?? "NONE") } ?? .none,
                                        makeupIntensity: C.f(o["makeupIntensity"], 0.6))
            return AppBeautyPreset(id: id, title: C.s(o["title"]) ?? id, subtitle: C.s(o["subtitle"]) ?? "",
                                   tag: C.s(o["tag"]) ?? "", options: opts.clamped(), card: C.s(o["card"]))
        }
        if presets.isEmpty {
            presets = [AppBeautyPreset(id: "SMART", title: "Smart Beauty", subtitle: "", tag: "", options: AppBeautyOptions(), card: nil)]
        }
    }
}
