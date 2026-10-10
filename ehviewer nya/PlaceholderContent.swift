//
//  PlaceholderContent.swift
//  ehviewer nya
//
//  占位符模式 —— 公开场合开发/调试用的脱敏开关
//
//  软件展示的内容具有敏感性，不宜在公开场合显示；而开发调试常在公开场合进行。
//  开启后：所有图片换成合成占位图、所有可见文字换成稳定生成的假文本，
//  且**完全不发起图片下载**（真实图片字节不流动、不落盘）。
//
//  触发方式（参照 DebugStorageReset 的约定）：
//    - 编译条件 `PLACEHOLDER_MODE`（"ehviewer nya Demo" 配置恒开）
//    - 启动参数 `-EhPlaceholder`
//    - 环境变量 `EH_PLACEHOLDER=1`
//

import Foundation
import CoreGraphics
import EhModels
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
private typealias PlaceholderColor = UIColor
#else
private typealias PlaceholderColor = NSColor
#endif

// MARK: - 开关与文本

enum PlaceholderMode {

    /// 是否处于占位符模式。占位模式关闭时全 App 行为与改动前完全一致。
    static var isEnabled: Bool {
        #if PLACEHOLDER_MODE
        return true
        #else
        if ProcessInfo.processInfo.arguments.contains("-EhPlaceholder") { return true }
        if ProcessInfo.processInfo.environment["EH_PLACEHOLDER"] == "1" { return true }
        return false
        #endif
    }

    // MARK: 稳定哈希
    //
    // 绝不能用 `String.hashValue`：它每个进程随机加盐，同一本书/标签
    // 每次启动都会得到不同的占位色与假文本，排版调试时会一直闪。

    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325           // FNV-1a 64 位偏移基准
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3                // FNV 质数
        }
        return hash
    }

    // MARK: 假文本
    //
    // 由 seed 稳定生成，长度接近真实内容，方便看排版。

    private static let words = [
        "amber", "basalt", "cobalt", "dusk", "ember", "fjord", "garnet", "harbor",
        "ivory", "jade", "kelp", "lumen", "marble", "nimbus", "onyx", "opal",
        "prism", "quartz", "ridge", "sable", "topaz", "umber", "verdant", "willow",
        "xenon", "yarrow", "zephyr", "cinder", "drift", "echo", "fable", "glimmer",
        "haze", "inlet", "jetty", "kestrel", "lagoon", "moss", "nectar", "orbit",
        "petal", "quill", "reef", "slate", "thistle", "vellum", "walnut", "zircon",
    ]

    /// 标题：形如 `Synthetic Entry 4821 — Harbor Nimbus Quartz Ember`
    static func title(_ seed: String) -> String {
        var rng = PlaceholderRNG(seed: seed)
        let number = 1000 + Int(stableHash(seed) % 9000)
        let count = rng.int(3..<6)
        let phrase = (0..<count).map { _ in rng.pick(words).capitalized }.joined(separator: " ")
        return "Synthetic Entry \(number) — \(phrase)"
    }

    /// 上传者 / 评论者：`uploader_42`
    static func uploader(_ seed: String) -> String {
        "uploader_\(stableHash(seed) % 1000)"
    }

    /// 标签：保留命名空间结构（artist:/female: …），值替换成稳定的假词
    static func tag(_ seed: String) -> String {
        "\(namespaceLabel(seed)):\(line(seed))"
    }

    /// 标签命名空间（详情页左侧那一列）
    static func namespaceLabel(_ seed: String) -> String {
        var rng = PlaceholderRNG(seed: seed)
        return rng.pick(["artist", "female", "male", "language", "group", "parody", "character", "misc"])
    }

    /// 评论正文：两三句首字母大写的假句
    static func comment(_ seed: String) -> String {
        var rng = PlaceholderRNG(seed: seed)
        let sentences = rng.int(2..<4)
        return (0..<sentences).map { _ -> String in
            let count = rng.int(5..<12)
            let words = (0..<count).map { _ in rng.pick(self.words) }
            return (words.first!.capitalized + " " + words.dropFirst().joined(separator: " ")) + "."
        }.joined(separator: " ")
    }

    /// 单行短语：搜索名等
    static func line(_ seed: String) -> String {
        var rng = PlaceholderRNG(seed: seed)
        return (0..<rng.int(2..<4)).map { _ in rng.pick(words) }.joined(separator: " ")
    }
}

// MARK: - 合成列表数据

extension PlaceholderMode {

    /// 合成一批画廊行，供断网时的**网络列表**（首页/热门/排行/搜索/标签/订阅）使用。
    ///
    /// 稳定生成（同一 seedBase + 起始序号 → 同一批数据），不随机；缩略图 URL 也填成
    /// 合成值，`CachedAsyncImage` 会据此出占位图。这样整条浏览链路（列表 → 详情 → 阅读器）
    /// 在离线状态下也能完整走通，且全程不接触真实内容。
    static func syntheticGalleries(
        seedBase: String,
        startIndex: Int = 0,
        count: Int = 24
    ) -> [GalleryInfo] {
        let categories: [EhCategory] = [
            .doujinshi, .manga, .artistCG, .gameCG, .imageSet,
            .cosplay, .nonH, .western, .misc,
        ]
        return (0..<count).map { offset in
            let idx = startIndex + offset
            let seed = "\(seedBase)-\(idx)"
            let pages = 8 + Int(stableHash(seed + "#pages") % 40)
            var tags = (0..<4).map { tag("\(seed)-t\($0)") }
            tags.insert("language:english", at: 0)
            let ratingHundredths = Int(stableHash(seed + "#rating") % 150)  // 3.50 … 4.99
            return GalleryInfo(
                gid: 900_000_000 + Int64(idx),
                token: "placeholder",
                title: title(seed),
                titleJpn: title(seed),
                thumb: "placeholder://thumb/\(idx)",
                category: categories[idx % categories.count],
                posted: "2026-01-01 00:00",
                uploader: uploader(seed),
                rating: 3.5 + Float(ratingHundredths) / 100,
                rated: true,
                pages: pages,
                simpleTags: tags,
                simpleLanguage: "EN",
                thumbWidth: 300,
                thumbHeight: 400
            )
        }
    }

    /// 合成一整套详情数据（标签组 / 预览集 / 评论），供断网时详情页与预览页使用。
    ///
    /// 预览集按画廊页数生成——每页一个预览，position 与阅读器页码一一对应，
    /// 点预览即跳到对应占位页。评论为纯文本（无 HTML），经详情 VM 的
    /// `preprocessComments` 也只会原样通过。
    static func syntheticDetail(gid: Int64, token: String, pages: Int) -> GalleryDetail {
        let seed = "detail-\(gid)"
        let pageCount = max(pages, 1)
        let info = GalleryInfo(
            gid: gid, token: token,
            title: title(seed), titleJpn: title(seed),
            thumb: "placeholder://detail/\(gid)",
            category: .doujinshi, posted: "2026-01-01 00:00",
            uploader: uploader(seed), rating: 4.0, rated: true,
            pages: pageCount, simpleTags: [], simpleLanguage: "EN",
            thumbWidth: 300, thumbHeight: 400
        )
        let groups = ["artist", "female", "male", "language", "misc"].map { ns in
            GalleryTagGroup(groupName: ns, tags: (0..<3).map { line("\(seed)-\(ns)-\($0)") })
        }
        let previewSet = PreviewSet.large((0..<pageCount).map {
            LargePreview(position: $0, imageUrl: "placeholder://preview/\(gid)/\($0)", pageUrl: "")
        })
        return GalleryDetail(
            info: info,
            language: "English",
            size: "42.0 MB",
            favoriteCount: 17,
            isFavorited: false,
            ratingCount: 128,
            tags: groups,
            comments: GalleryCommentList(
                comments: syntheticComments(seedBase: seed, count: 6), hasMore: false
            ),
            previewPages: 1,
            previewSet: previewSet
        )
    }

    /// 合成一批评论（纯文本，无 HTML）
    static func syntheticComments(seedBase: String, count: Int, startIndex: Int = 0) -> [GalleryComment] {
        (0..<count).map { offset in
            let i = startIndex + offset
            let seed = "\(seedBase)-c\(i)"
            return GalleryComment(
                id: Int64(i + 1),
                score: Int(stableHash(seed + "#s") % 9) - 3,
                editable: false,
                voteUpAble: true, voteUpEd: false,
                voteDownAble: true, voteDownEd: false,
                voteState: nil,
                time: Date(timeIntervalSince1970: 1_767_000_000 - Double(i) * 86_400),
                user: uploader(seed),
                comment: comment(seed),
                lastEdited: nil
            )
        }
    }
}

/// 由 seed 决定的确定性伪随机数发生器（xorshift64）
private struct PlaceholderRNG {
    private var state: UInt64

    init(seed: String) {
        // 保证状态非零
        state = PlaceholderMode.stableHash(seed) | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ range: Range<Int>) -> Int {
        guard range.count > 0 else { return range.lowerBound }
        return Int(next() % UInt64(range.count)) + range.lowerBound
    }

    mutating func pick<T>(_ array: [T]) -> T {
        array[int(0..<array.count)]
    }
}

// MARK: - 占位图合成

/// 合成占位图：底色由 seed 稳定决定（低饱和、深浅模式都可读），
/// 叠淡斜纹 + 一个 SF Symbol + 等宽标签（IMG / PAGE n）。
enum PlaceholderImage {

    /// 绘制结果缓存 —— 滚动时同一张图不重画。
    nonisolated(unsafe) private static let cache = NSCache<NSString, PlatformImage>()

    /// 通用入口。`size` 建议与实际展示比例接近（缩略图 3:4，阅读页 2:3）。
    nonisolated static func make(
        seed: String,
        size: CGSize,
        label: String,
        symbol: String = "photo"
    ) -> PlatformImage {
        let key = "\(seed)|\(Int(size.width))x\(Int(size.height))|\(label)|\(symbol)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = render(size: size, hue: hue(for: seed), label: label, symbol: symbol)
        cache.setObject(image, forKey: key)
        return image
    }

    /// 列表封面 / 缩略图 / 预览格子
    nonisolated static func thumbnail(seed: String) -> PlatformImage {
        make(seed: seed, size: CGSize(width: 300, height: 400), label: "IMG", symbol: "photo")
    }

    /// 阅读器整页
    nonisolated static func page(seed: String, pageNumber: Int, total: Int) -> PlatformImage {
        let label = total > 0 ? "PAGE \(pageNumber) / \(total)" : "PAGE \(pageNumber)"
        return make(seed: seed, size: CGSize(width: 1200, height: 1700), label: label, symbol: "doc.richtext")
    }

    /// seed → 色相（0..1）
    private static func hue(for seed: String) -> CGFloat {
        CGFloat(PlaceholderMode.stableHash(seed) % 360) / 360
    }

    // MARK: 绘制（按平台）

    private static func render(size: CGSize, hue: CGFloat, label: String, symbol: String) -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            drawBackground(cg: ctx.cgContext, size: size, hue: hue)
            drawSymbol(symbol, size: size, cg: ctx.cgContext)
            drawLabel(label, size: size, cg: ctx.cgContext)
        }
        #else
        return NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            self.drawBackground(cg: cg, size: rect.size, hue: hue)
            self.drawSymbol(symbol, size: rect.size, cg: cg)
            self.drawLabel(label, size: rect.size, cg: cg)
            return true
        }
        #endif
    }

    /// 底色 + 45° 淡斜纹（纯 CGContext，两平台共用）
    private static func drawBackground(cg: CGContext, size: CGSize, hue: CGFloat) {
        let base = PlaceholderColor(hue: hue, saturation: 0.24, brightness: 0.88, alpha: 1)
        cg.setFillColor(base.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))

        cg.saveGState()
        cg.setStrokeColor(PlaceholderColor.white.withAlphaComponent(0.10).cgColor)
        cg.setLineWidth(max(6, size.width * 0.05))
        let step = max(24, size.width * 0.20)
        var x = -size.height
        while x < size.width + size.height {
            cg.move(to: CGPoint(x: x, y: 0))
            cg.addLine(to: CGPoint(x: x + size.height, y: size.height))
            x += step
        }
        cg.strokePath()
        cg.restoreGState()
    }

    private static func drawSymbol(_ name: String, size: CGSize, cg: CGContext) {
        let side = min(size.width, size.height) * 0.30
        let rect = CGRect(
            x: (size.width - side) / 2,
            y: size.height * 0.5 - side * 1.15,
            width: side, height: side
        )
        let tint = PlaceholderColor.black.withAlphaComponent(0.42)
        #if canImport(UIKit)
        guard let symbol = UIImage(systemName: name)?
            .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
        symbol.draw(in: rect)
        #else
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: rect.size))
        tint.set()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect)
        #endif
    }

    private static func drawLabel(_ label: String, size: CGSize, cg: CGContext) {
        let fontSize = max(14, size.width * 0.075)
        #if canImport(UIKit)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: PlaceholderColor.black.withAlphaComponent(0.62),
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: (size.width - textSize.width) / 2,
                        y: size.height * 0.5 + min(size.width, size.height) * 0.08),
            withAttributes: attrs
        )
        #else
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: PlaceholderColor.black.withAlphaComponent(0.62),
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: (size.width - textSize.width) / 2,
                        y: size.height * 0.5 + min(size.width, size.height) * 0.08),
            withAttributes: attrs
        )
        #endif
    }
}
