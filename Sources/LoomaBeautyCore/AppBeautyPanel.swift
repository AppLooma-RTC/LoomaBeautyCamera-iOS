import Foundation
import CoreImage
import PhotosUI
import UIKit

/// The beauty panel: a bottom sheet over the camera with tabs (Presets,
/// Beauty, Make up, Filter), a category header that follows the cards as they
/// scroll, an Off card, a strength slider and favourites (long press a card).
/// `showMagic` opens the Magic panel (Mask, Background) the same way.
///
/// ```swift
/// AppBeautyPanel.show(in: self, beauty: beauty)
/// AppBeautyPanel.showMagic(in: self, beauty: beauty)
/// ```
public final class AppBeautyPanel: UIViewController, UIScrollViewDelegate, PHPickerViewControllerDelegate {
    private enum Tab: String {
        case presets = "Presets", beauty = "Beauty", makeup = "Make up", filter = "Filter", mask = "Mask", background = "Background"
    }

    /// Opens the beauty panel (Presets, Beauty, Make up, Filter) over `host`.
    public static func show(in host: UIViewController, beauty: AppBeauty) { open(host, beauty, magic: false) }

    /// Opens the Magic panel (Mask, Background) over `host`.
    public static func showMagic(in host: UIViewController, beauty: AppBeauty) { open(host, beauty, magic: true) }

    private static func open(_ host: UIViewController, _ beauty: AppBeauty, magic: Bool) {
        let p = AppBeautyPanel(beauty: beauty, magic: magic)
        p.modalPresentationStyle = .overFullScreen
        p.modalTransitionStyle = .coverVertical
        host.present(p, animated: true)
    }

    private let beauty: AppBeauty
    private let tabsShown: [Tab]
    private var currentTab: Tab
    private var item: AppBeautyItem = .smooth
    private var group: AppBeautyGroup = .skin
    private var complexionPage = false
    private var makeupCat = 1, filterCat = 1, maskCat = 1, bgCat = 1
    private var loadingMask: AppMask?
    private var loadingBg: AppBeautyBackground?
    private var favs: Set<String>
    private static let favKey = "looma.beauty.favorites"

    private let accent = UIColor(red: 1.0, green: 0.36, blue: 0.55, alpha: 1)
    private let dim = UIColor(white: 1, alpha: 0.55)

    private let panel = UIView()
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private let sliderRow = UIStackView()
    private let slider2 = UISlider()
    private let slider2Row = UIStackView()
    private let tabsRow = UIStackView()
    private let headerScroll = UIScrollView()
    private let header = UIStackView()
    private let rowScroll = UIScrollView()
    private let row = UIStackView()
    private var tabButtons: [Tab: UIButton] = [:]
    private var catButtons: [UIButton] = []
    private var catStart: [Int: UIView] = [:]
    private var groupButtons: [AppBeautyGroup: UIButton] = [:]
    private var sectionStart: [AppBeautyGroup: UIView] = [:]
    private var followLock: CFTimeInterval = 0
    private var lastTab: Tab?

    private init(beauty: AppBeauty, magic: Bool) {
        self.beauty = beauty
        tabsShown = magic ? [.mask, .background] : [.presets, .beauty, .makeup, .filter]
        currentTab = tabsShown[0]
        favs = Set(UserDefaults.standard.stringArray(forKey: AppBeautyPanel.favKey) ?? [])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let dismissArea = UIView()
        dismissArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissArea)
        dismissArea.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))

        panel.backgroundColor = UIColor(white: 0.04, alpha: 0.88)
        panel.layer.cornerRadius = 18
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        // Make-up tab: the look's filter strength on a second slider.
        let f2 = UILabel(); f2.text = "Filter"; f2.font = .systemFont(ofSize: 12); f2.textColor = .white
        slider2.minimumValue = 0; slider2.maximumValue = 1
        slider2.minimumTrackTintColor = accent
        slider2.addTarget(self, action: #selector(slider2Changed), for: .valueChanged)
        slider2Row.axis = .horizontal; slider2Row.spacing = 10
        slider2Row.addArrangedSubview(f2); slider2Row.addArrangedSubview(slider2)

        slider.minimumTrackTintColor = accent
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        sliderRow.axis = .horizontal; sliderRow.spacing = 10
        sliderRow.addArrangedSubview(slider); sliderRow.addArrangedSubview(valueLabel)

        tabsRow.axis = .horizontal; tabsRow.spacing = 20; tabsRow.alignment = .center
        for t in tabsShown {
            let b = UIButton(type: .system)
            b.setTitle(t == .presets ? "\u{2726} \(t.rawValue)" : t.rawValue, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            b.addAction(UIAction { [weak self] _ in self?.currentTab = t; self?.complexionPage = false; self?.render() }, for: .touchUpInside)
            tabButtons[t] = b
            tabsRow.addArrangedSubview(b)
        }
        let tabsWrap = UIStackView(arrangedSubviews: [tabsRow, UIView()])
        tabsWrap.axis = .horizontal

        header.axis = .horizontal; header.spacing = 2; header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        headerScroll.showsHorizontalScrollIndicator = false
        headerScroll.addSubview(header)
        row.axis = .horizontal; row.spacing = 10; row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        rowScroll.showsHorizontalScrollIndicator = false
        rowScroll.delegate = self
        rowScroll.addSubview(row)

        for v in [slider2Row, sliderRow, tabsWrap, headerScroll, rowScroll] as [UIView] { stack.addArrangedSubview(v) }
        NSLayoutConstraint.activate([
            dismissArea.topAnchor.constraint(equalTo: view.topAnchor),
            dismissArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dismissArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dismissArea.bottomAnchor.constraint(equalTo: panel.topAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            headerScroll.heightAnchor.constraint(equalToConstant: 30),
            header.topAnchor.constraint(equalTo: headerScroll.contentLayoutGuide.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerScroll.contentLayoutGuide.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerScroll.contentLayoutGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerScroll.contentLayoutGuide.trailingAnchor),
            header.heightAnchor.constraint(equalTo: headerScroll.frameLayoutGuide.heightAnchor),
            rowScroll.heightAnchor.constraint(equalToConstant: 96),
            row.topAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: rowScroll.frameLayoutGuide.heightAnchor),
        ])
        render()
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: Render

    private func render() {
        for (t, b) in tabButtons {
            b.setTitleColor(t == currentTab ? (t == .presets ? accent : .white) : dim, for: .normal)
        }
        let keepX = currentTab == lastTab ? rowScroll.contentOffset.x : 0
        lastTab = currentTab
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        catButtons.removeAll(); catStart.removeAll()
        headerScroll.isHidden = currentTab == .presets
        let o = beauty.options
        switch currentTab {
        case .presets:
            row.addArrangedSubview(offItem { [weak self] in self?.beauty.options = AppBeautyOptions(); self?.render() })
            for p in AppBeautyPreset.all {
                row.addArrangedSubview(card(name: p.card, label: p.title, selected: beauty.preset == p) { [weak self] in
                    self?.beauty.setPreset(p); self?.showTitle(p); self?.render()
                })
            }
        case .beauty:
            if complexionPage { renderComplexion(o) } else { renderBeauty(o) }
        case .makeup:
            categoryHeader(["Favorites"] + AppBeautyMakeup.categories.map { $0.title }, makeupCat)
            row.addArrangedSubview(offItem { [weak self] in
                guard let self else { return }
                var c = self.beauty.options; c.makeup = .none; self.beauty.options = c; self.render()
            })
            let favLooks = AppBeautyMakeup.all.filter { $0 != .none && favs.contains("m:" + $0.id) }
            if makeupCat == 0 && favLooks.isEmpty { row.addArrangedSubview(emptyFavorites()) }
            let sections: [(Int, [AppBeautyMakeup])] = makeupCat == 0 ? [(0, favLooks)]
                : AppBeautyMakeup.categories.enumerated().map { (i, c) in (i + 1, AppBeautyMakeup.all.filter { $0.category == c.id }) }
            for (ci, looks) in sections {
                section(ci)
                for m in looks {
                    row.addArrangedSubview(card(name: m.card ?? "makeup_\(m.id.lowercased()).jpg", label: m.title, selected: o.makeup == m,
                                                onLong: { [weak self] in self?.toggleFavorite("m:" + m.id) }) { [weak self] in
                        guard let self else { return }
                        var c = self.beauty.options
                        c.makeup = m
                        if c.makeupIntensity <= 0 { c.makeupIntensity = 0.6 }
                        if m.lookFilter != .none { c.filter = m.lookFilter; c.filterIntensity = 0.5 }
                        self.beauty.options = c
                        self.render()
                    })
                }
            }
            restoreScroll(keepX)
        case .filter:
            categoryHeader(["Favorites"] + AppBeautyFilter.categories.map { $0.title }, filterCat)
            row.addArrangedSubview(offItem { [weak self] in
                guard let self else { return }
                var c = self.beauty.options; c.filter = .none; self.beauty.options = c; self.render()
            })
            let favList = AppBeautyFilter.all.filter { $0 != .none && favs.contains("f:" + $0.id) }
            if filterCat == 0 && favList.isEmpty { row.addArrangedSubview(emptyFavorites()) }
            let sections: [(Int, [AppBeautyFilter])] = filterCat == 0 ? [(0, favList)]
                : AppBeautyFilter.categories.enumerated().map { (i, c) in (i + 1, AppBeautyFilter.all.filter { $0.category == c.id }) }
            for (ci, list) in sections {
                section(ci)
                for f in list {
                    let v = card(name: nil, label: f.title, selected: o.filter == f,
                                 onLong: { [weak self] in self?.toggleFavorite("f:" + f.id) }) { [weak self] in
                        guard let self else { return }
                        var c = self.beauty.options
                        c.filter = f
                        if c.filterIntensity <= 0 { c.filterIntensity = 0.8 }
                        self.beauty.options = c
                        self.render()
                    }
                    filterCard(f) { [weak v] img in (v as? Card)?.image = img }
                    row.addArrangedSubview(v)
                }
            }
            restoreScroll(keepX)
        case .mask:
            categoryHeader(["Favorites"] + AppMasks.categories, maskCat)
            row.addArrangedSubview(offItem { [weak self] in self?.beauty.mask = nil; self?.render() })
            let favMasks = AppMasks.all.filter { favs.contains("k:" + $0.id) }
            if maskCat == 0 && favMasks.isEmpty { row.addArrangedSubview(emptyFavorites()) }
            let sections: [(Int, [AppMask])] = maskCat == 0 ? [(0, favMasks)]
                : AppMasks.categories.enumerated().map { (i, c) in (i + 1, AppMasks.inCategory(c)) }
            for (ci, list) in sections {
                section(ci)
                for m in list {
                    row.addArrangedSubview(card(name: m.thumb, label: m == loadingMask ? "Loading\u{2026}" : m.title, selected: beauty.mask == m,
                                                onLong: { [weak self] in self?.toggleFavorite("k:" + m.id) }) { [weak self] in self?.pickMask(m) })
                }
            }
            restoreScroll(keepX)
        case .background:
            categoryHeader([""] + AppBeautyBackground.categories.map { $0.title }, bgCat)
            catButtons.first?.isHidden = true
            row.addArrangedSubview(offItem { [weak self] in self?.beauty.background = .none; self?.render() })
            if !AppBeauty.isBackgroundSupported {
                row.addArrangedSubview(note("Backgrounds need iOS 15 or later"))
            } else {
                for (i, c) in AppBeautyBackground.categories.enumerated() {
                    section(i + 1)
                    if c.id == "CUSTOM" {
                        let up = card(name: nil, label: "Upload", selected: false) { [weak self] in self?.pickPhoto() }
                        (up as? Card)?.image = UIImage(systemName: "plus")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                        (up as? Card)?.imageView.contentMode = .center
                        row.addArrangedSubview(up)
                        if let img = beauty.customBackground {
                            let mine = card(name: nil, label: "My photo", selected: beauty.background == .custom) { [weak self] in
                                self?.beauty.background = .custom; self?.render()
                            }
                            (mine as? Card)?.image = img
                            row.addArrangedSubview(mine)
                        }
                    } else {
                        for bg in AppBeautyBackground.all where bg.category == c.id {
                            let thumb = (bg.asset ?? bg.glass).map { "thumb_" + $0 }
                            let v = card(name: thumb, label: bg == loadingBg ? "Loading\u{2026}" : bg.title, selected: beauty.background == bg) { [weak self] in
                                self?.pickBackground(bg)
                            }
                            if thumb == nil { blurCard(bg) { [weak v] img in (v as? Card)?.image = img } }
                            row.addArrangedSubview(v)
                        }
                    }
                }
            }
            restoreScroll(keepX)
        }
        renderSlider(beauty.options)
    }

    private func renderBeauty(_ o: AppBeautyOptions) {
        let reset = headerButton("\u{21BA} Reset all", selected: false) { [weak self] in self?.confirmReset() }
        reset.setTitleColor(o.enabled ? .white : dim, for: .normal)
        header.addArrangedSubview(reset)
        groupButtons.removeAll(); sectionStart.removeAll()
        for g in AppBeautyGroup.allCases {
            let b = headerButton(g.title, selected: g == group) { [weak self] in
                guard let self else { return }
                self.group = g; self.markGroup()
                self.followLock = CACurrentMediaTime()
                if let v = self.sectionStart[g] { self.scrollRow(to: v.frame.minX - 60) }
            }
            groupButtons[g] = b
            header.addArrangedSubview(b)
        }
        row.addArrangedSubview(glyphItem(key: "toggle", symbol: o.enabled ? "power.circle.fill" : "power.circle", title: o.enabled ? "On" : "Off",
                                         selected: false, on: o.enabled, enabled: true) { [weak self] in
            guard let self else { return }
            var c = self.beauty.options; c.enabled.toggle(); self.beauty.options = c
            if !c.enabled { self.toast("Beauty mode off") }
            self.render()
        })
        for g in AppBeautyGroup.allCases {
            if g != .skin { row.addArrangedSubview(divider()) }
            var first: UIView?
            for it in AppBeautyItem.allCases where it.group == g {
                let v = glyphItem(key: it.rawValue, symbol: AppBeautyPanel.symbol(for: it), title: it.title, selected: it == item,
                                  on: o.enabled && (o.values[it] ?? 0) != 0, enabled: o.enabled) { [weak self] in
                    guard let self else { return }
                    self.item = it
                    if it == .complexion { self.complexionPage = true }
                    self.render()
                }
                if first == nil { first = v }
                row.addArrangedSubview(v)
            }
            sectionStart[g] = first
        }
        markGroup()
        let keep = item
        DispatchQueue.main.async { [weak self] in
            guard let self, let v = self.row.arrangedSubviews.first(where: { ($0 as? Card)?.key == keep.rawValue }) else { return }
            let x = self.rowScroll.contentOffset.x
            if v.frame.maxX > x + self.rowScroll.bounds.width || v.frame.minX < x { self.scrollRow(to: v.frame.minX - 80, animated: false) }
        }
    }

    private func renderComplexion(_ o: AppBeautyOptions) {
        header.addArrangedSubview(headerButton("\u{2039} Complexion", selected: true) { [weak self] in
            self?.complexionPage = false; self?.render()
        })
        for t in AppBeautyTone.allCases {
            let c = Card(key: t.rawValue)
            c.label.text = t.rawValue
            c.imageView.backgroundColor = UIColor(red: CGFloat(t.rgb.x), green: CGFloat(t.rgb.y), blue: CGFloat(t.rgb.z), alpha: 1)
            c.setSelected(o.tone == t, accent: accent)
            c.onTap = { [weak self] in
                guard let self else { return }
                var n = self.beauty.options
                n.tone = t
                if (n.values[.complexion] ?? 0) == 0 { n = n.with(.complexion, 0.5) }
                self.beauty.options = n
                self.render()
            }
            row.addArrangedSubview(c)
        }
    }

    private func renderSlider(_ o: AppBeautyOptions) {
        var v: Float = -2
        var bipolar = false
        switch currentTab {
        case .beauty:
            let it: AppBeautyItem = complexionPage ? .complexion : item
            if o.enabled { bipolar = it.bipolar; v = o.values[it] ?? 0 }
        case .makeup: if o.makeup != .none { v = o.makeupIntensity }
        case .filter: if o.filter != .none { v = o.filterIntensity }
        default: break
        }
        sliderRow.isHidden = v < -1.5
        slider.minimumValue = bipolar ? -1 : 0
        slider.maximumValue = 1
        if v > -1.5 { slider.value = v }
        valueLabel.text = "\(Int((slider.value * 100).rounded()))"
        let showFilter2 = currentTab == .makeup && v > -1.5 && o.filter != .none
        slider2Row.isHidden = !showFilter2
        if showFilter2 { slider2.value = o.filterIntensity }
    }

    @objc private func sliderChanged() {
        let v = slider.value
        valueLabel.text = "\(Int((v * 100).rounded()))"
        var o = beauty.options
        switch currentTab {
        case .beauty: o = o.with(complexionPage ? .complexion : item, abs(v) < 0.005 ? 0 : v)
        case .makeup: o.makeupIntensity = v
        case .filter: o.filterIntensity = v
        default: return
        }
        beauty.options = o
        if currentTab == .beauty {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rerender), object: nil)
            perform(#selector(rerender), with: nil, afterDelay: 0.25)
        }
    }

    @objc private func rerender() {
        let x = rowScroll.contentOffset.x
        render()
        restoreScroll(x)
    }

    @objc private func slider2Changed() {
        var o = beauty.options
        o.filterIntensity = slider2.value
        beauty.options = o
    }

    // MARK: Categories that follow the scroll

    private func categoryHeader(_ titles: [String], _ selected: Int) {
        for (i, t) in titles.enumerated() {
            let b = headerButton(t, selected: i == selected) { [weak self] in self?.pickCategory(i) }
            catButtons.append(b)
            header.addArrangedSubview(b)
        }
    }

    /// Marks where category `ci` starts in the row, with a thin divider between categories.
    private func section(_ ci: Int) {
        if ci > 1 { row.addArrangedSubview(divider()) }
        let marker = UIView()
        marker.widthAnchor.constraint(equalToConstant: 0).isActive = true
        row.addArrangedSubview(marker)
        catStart[ci] = marker
    }

    private func currentCat() -> Int {
        switch currentTab {
        case .makeup: return makeupCat
        case .background: return bgCat
        case .mask: return maskCat
        default: return filterCat
        }
    }

    private func setCat(_ i: Int) {
        switch currentTab {
        case .makeup: makeupCat = i
        case .background: bgCat = i
        case .mask: maskCat = i
        default: filterCat = i
        }
    }

    private func pickCategory(_ i: Int) {
        let fromFav = currentCat() == 0
        if currentTab != .background && (i == 0 || fromFav) {
            // Favourites is its own list; leaving it rebuilds the full row.
            setCat(i)
            lastTab = nil
            render()
            if i > 0 { view.layoutIfNeeded(); scrollToCat(i, animated: false) }
            return
        }
        setCat(i)
        markCat(i)
        followLock = CACurrentMediaTime()
        scrollToCat(i, animated: true)
    }

    private func scrollToCat(_ i: Int, animated: Bool) {
        guard let v = catStart[i] else { return }
        scrollRow(to: v.frame.minX - 70, animated: animated)
    }

    private func scrollRow(to x: CGFloat, animated: Bool = true) {
        let maxX = Swift.max(rowScroll.contentSize.width - rowScroll.bounds.width, 0)
        rowScroll.setContentOffset(CGPoint(x: Swift.min(Swift.max(x, 0), maxX), y: 0), animated: animated)
    }

    private func restoreScroll(_ x: CGFloat) {
        guard x > 0 else { return }
        view.layoutIfNeeded()
        scrollRow(to: x, animated: false)
    }

    private func markCat(_ i: Int) {
        for (k, b) in catButtons.enumerated() {
            b.setTitleColor(k == i ? .white : dim, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: k == i ? .bold : .regular)
        }
        if i < catButtons.count {
            let b = catButtons[i]
            headerScroll.scrollRectToVisible(b.frame.insetBy(dx: -40, dy: 0), animated: true)
        }
    }

    private func markGroup() {
        for (g, b) in groupButtons {
            b.setTitleColor(g == group ? .white : dim, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: g == group ? .bold : .regular)
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === rowScroll, scrollView.isTracking || scrollView.isDecelerating,
              CACurrentMediaTime() - followLock > 0.6 else { return }
        let x = scrollView.contentOffset.x + 80
        if currentTab == .beauty && !complexionPage {
            var g = AppBeautyGroup.skin
            for cand in AppBeautyGroup.allCases { if let v = sectionStart[cand], v.frame.minX <= x { g = cand } }
            if g != group { group = g; markGroup() }
        } else if currentTab != .presets && currentCat() != 0 {
            let passed = catStart.filter { $0.value.frame.minX <= x }
            guard let c = passed.max(by: { $0.value.frame.minX < $1.value.frame.minX })?.key else { return }
            if c != currentCat() { setCat(c); markCat(c) }
        }
    }

    // MARK: Actions

    private func pickMask(_ m: AppMask) {
        if BeautyAssets.isReady(m) { beauty.mask = m; render(); return }
        loadingMask = m
        render()
        BeautyAssets.fetch(m) { [weak self] ok in
            guard let self else { return }
            if self.loadingMask == m { self.loadingMask = nil; if ok { self.beauty.mask = m } }
            if !ok { self.toast("Couldn't load this mask. Check your connection.") }
            self.render()
        }
    }

    private func pickBackground(_ bg: AppBeautyBackground) {
        if BeautyAssets.isReady(bg) { beauty.background = bg; render(); return }
        loadingBg = bg
        render()
        BeautyAssets.fetch(bg) { [weak self] ok in
            guard let self else { return }
            if self.loadingBg == bg { self.loadingBg = nil; if ok { self.beauty.background = bg } }
            if !ok { self.toast("Couldn't load this background. Check your connection.") }
            self.render()
        }
    }

    private func pickPhoto() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
            guard let img = obj as? UIImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.beauty.customBackground = img
                self.beauty.background = .custom
                self.render()
            }
        }
    }

    private func toggleFavorite(_ key: String) {
        let added = !favs.contains(key)
        if added { favs.insert(key) } else { favs.remove(key) }
        UserDefaults.standard.set(Array(favs), forKey: AppBeautyPanel.favKey)
        toast(added ? "Added to favorites" : "Removed from favorites")
        render()
    }

    private func confirmReset() {
        let a = UIAlertController(title: nil, message: "Restore the default look?", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            self?.beauty.options = AppBeauty.defaultOptions
            self?.render()
        })
        present(a, animated: true)
    }

    // MARK: Pieces

    /// A card: a rounded picture with a label under it.
    private final class Card: UIView {
        let key: String
        let imageView = UIImageView()
        let label = UILabel()
        var onTap: (() -> Void)?
        var onLong: (() -> Void)?
        var image: UIImage? {
            get { imageView.image }
            set { imageView.image = newValue }
        }

        init(key: String, side: CGFloat = 60) {
            self.key = key
            super.init(frame: .zero)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.backgroundColor = UIColor(white: 1, alpha: 0.12)
            imageView.tintColor = .white
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            let stack = UIStackView(arrangedSubviews: [imageView, label])
            stack.axis = .vertical
            stack.spacing = 5
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: side),
                imageView.heightAnchor.constraint(equalToConstant: side),
                label.widthAnchor.constraint(equalToConstant: side + 10),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func setSelected(_ on: Bool, accent: UIColor) {
            imageView.layer.borderWidth = on ? 2 : 0
            imageView.layer.borderColor = accent.cgColor
            label.font = .systemFont(ofSize: 11, weight: on ? .bold : .regular)
        }

        @objc private func tapped() { onTap?() }
        @objc private func pressed(_ g: UILongPressGestureRecognizer) { if g.state == .began { onLong?() } }
    }

    private func card(name: String?, label: String, selected: Bool, onLong: (() -> Void)? = nil, onTap: @escaping () -> Void) -> UIView {
        let c = Card(key: name ?? label)
        c.label.text = label
        c.setSelected(selected, accent: accent)
        c.onTap = onTap
        c.onLong = onLong
        if let name {
            BeautyAssets.card(name) { [weak c] img in
                guard let c, c.key == name, let img else { return }
                c.image = img
            }
        }
        return c
    }

    private func glyphItem(key: String, symbol: String, title: String, selected: Bool, on: Bool, enabled: Bool, onTap: @escaping () -> Void) -> UIView {
        let c = Card(key: key, side: 46)
        c.label.text = title
        c.imageView.contentMode = .center
        c.imageView.layer.cornerRadius = 23
        let tint: UIColor = !enabled ? UIColor(white: 1, alpha: 0.3) : (selected ? accent : (on ? .white : dim))
        c.image = (UIImage(systemName: symbol) ?? UIImage(systemName: "circle"))?.withTintColor(tint, renderingMode: .alwaysOriginal)
        c.setSelected(selected && enabled, accent: accent)
        c.label.textColor = enabled ? .white : UIColor(white: 1, alpha: 0.4)
        c.onTap = onTap
        return c
    }

    private func offItem(_ onTap: @escaping () -> Void) -> UIView {
        let c = Card(key: "off", side: 60)
        c.label.text = "Off"
        c.imageView.contentMode = .center
        c.image = UIImage(systemName: "nosign")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        c.onTap = onTap
        return c
    }

    private func headerButton(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(selected ? .white : dim, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: selected ? .bold : .regular)
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func divider() -> UIView {
        let wrap = UIView()
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.2)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 1),
            wrap.heightAnchor.constraint(equalToConstant: 60),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 36),
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    private func note(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12)
        l.textColor = dim
        l.numberOfLines = 2
        l.widthAnchor.constraint(equalToConstant: 200).isActive = true
        l.heightAnchor.constraint(equalToConstant: 60).isActive = true
        return l
    }

    private func emptyFavorites() -> UIView { note("Long press an item to add it to favorites") }

    private func toast(_ text: String) {
        let l = PaddedLabel()
        l.text = text
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .white
        l.backgroundColor = UIColor(white: 0, alpha: 0.75)
        l.layer.cornerRadius = 14
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -16),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.6, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
    }

    /// The preset's title card over the camera for a moment.
    private func showTitle(_ p: AppBeautyPreset) {
        let box = UIStackView()
        box.axis = .vertical
        box.alignment = .center
        box.spacing = 4
        box.translatesAutoresizingMaskIntoConstraints = false
        let t = UILabel(); t.text = p.title; t.font = .systemFont(ofSize: 24, weight: .bold); t.textColor = .white
        let s = UILabel(); s.text = p.subtitle; s.font = .systemFont(ofSize: 14); s.textColor = .white
        let g = PaddedLabel(); g.text = p.tag; g.font = .systemFont(ofSize: 12, weight: .semibold); g.textColor = .white
        g.backgroundColor = accent; g.layer.cornerRadius = 10; g.clipsToBounds = true
        for l in [t, s] {
            l.layer.shadowColor = UIColor.black.cgColor; l.layer.shadowOpacity = 0.6; l.layer.shadowRadius = 4; l.layer.shadowOffset = .zero
        }
        [t, s, g].forEach { box.addArrangedSubview($0) }
        view.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -60),
        ])
        UIView.animate(withDuration: 0.4, delay: 1.8, options: []) { box.alpha = 0 } completion: { _ in box.removeFromSuperview() }
    }

    private final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))) }
        override var intrinsicContentSize: CGSize {
            let s = super.intrinsicContentSize
            return CGSize(width: s.width + 24, height: s.height + 8)
        }
    }

    // MARK: Card pictures made on the device

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// The model photo through the filter's colour transform.
    private func filterCard(_ f: AppBeautyFilter, done: @escaping (UIImage?) -> Void) {
        let key = "filter:" + f.id
        if let m = BeautyAssets.remembered(key) { done(m); return }
        let model = f.category == "MALE" ? "model_male.jpg" : "model_base.jpg"
        BeautyAssets.card(model) { photo in
            guard let photo else { done(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let img = AppBeautyPanel.applyFilter(f, to: photo)
                if let img { BeautyAssets.remember(img, as: key) }
                DispatchQueue.main.async { done(img) }
            }
        }
    }

    private static func applyFilter(_ f: AppBeautyFilter, to photo: UIImage) -> UIImage? {
        guard let cg = photo.cgImage else { return nil }
        let n = 16
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        let t = Luts.transformOf(f)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let o = t(SIMD3(Float(r) / Float(n - 1), Float(g) / Float(n - 1), Float(b) / Float(n - 1)))
            let i = ((b * n + g) * n + r) * 4
            cube[i] = Swift.min(Swift.max(o.x, 0), 1)
            cube[i + 1] = Swift.min(Swift.max(o.y, 0), 1)
            cube[i + 2] = Swift.min(Swift.max(o.z, 0), 1)
        } } }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(cgImage: cg)
        let out = input.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": n, "inputCubeData": data])
        guard let res = ci.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: res)
    }

    /// The model photo, blurred, for the blur backgrounds.
    private func blurCard(_ bg: AppBeautyBackground, done: @escaping (UIImage?) -> Void) {
        let key = "bg:" + bg.id
        if let m = BeautyAssets.remembered(key) { done(m); return }
        BeautyAssets.card("model_base.jpg") { photo in
            guard let photo, let cg = photo.cgImage else { done(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let input = CIImage(cgImage: cg)
                let out = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4 * Double(bg.blur)])
                var img: UIImage?
                if let res = AppBeautyPanel.ci.createCGImage(out, from: input.extent) { img = UIImage(cgImage: res) }
                if let img { BeautyAssets.remember(img, as: key) }
                DispatchQueue.main.async { done(img) }
            }
        }
    }

    private static func symbol(for it: AppBeautyItem) -> String {
        switch it {
        case .smooth: return "drop"
        case .complexion: return "paintpalette"
        case .contour: return "circle.lefthalf.fill"
        case .light3d: return "light.max"
        case .brighten: return "sun.max"
        case .rosy: return "heart"
        case .contrast: return "circle.righthalf.fill"
        case .sharpen: return "triangle"
        case .lowLight: return "moon"
        case .lipstick: return "mouth"
        case .eyebrow, .browHeight, .browShape, .browTrim: return "line.diagonal"
        case .eyeshadow, .eyelash, .eyelid: return "eye"
        case .lenses, .pupils: return "circle.circle"
        case .blemish: return "bandage"
        case .bigEyes, .eyeHeight, .eyeAngle, .eyeDistance: return "eye.circle"
        case .brightEyes: return "sparkles"
        case .darkCircles: return "moon.circle"
        case .smileLines: return "wand.and.stars"
        case .whiteTeeth: return "sparkle"
        case .noseTip, .philtrum, .slimNose, .noseNarrow, .bridge, .nasalBridge, .noseWing: return "arrowtriangle.down"
        case .mouthWidth, .fullLip, .mouthSize, .mouthHeight, .smile: return "face.smiling"
        default: return "person.crop.circle"
        }
    }
}
