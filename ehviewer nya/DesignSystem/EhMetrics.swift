//
//  EhMetrics.swift
//  ehviewer nya
//
//  设计系统 — 字号、间距、圆角、尺寸
//
//  字号用 `.system(size:)` 而不是 `.body` / `.caption` 这类语义档位：设计稿给的是
//  具体像素值，语义档位在不同动态字体设置下的实际尺寸对不上。需要支持动态字体时
//  用 `EhFont.scaled(_:)`，它以对应的语义档位为基准做缩放。
//

import SwiftUI

// MARK: - 字号

enum EhFont {
    /// 34 — 配额等大数字
    static let display = Font.system(size: 34, weight: .bold).monospacedDigit()
    /// 28 — 页面大标题
    static let largeTitle = Font.system(size: 28, weight: .bold)
    /// 22 — 详情页评分
    static let rating = Font.system(size: 22, weight: .bold).monospacedDigit()
    /// 17 — 导航标题、区块标题
    static let title = Font.system(size: 17, weight: .semibold)
    /// 16 — 主按钮
    static let button = Font.system(size: 16, weight: .semibold)
    /// 15 — 正文、列表标题
    static let body = Font.system(size: 15)
    /// 14 — 次级标题
    static let subheadline = Font.system(size: 14)
    /// 13 — 说明文字、工具条
    static let caption = Font.system(size: 13)
    /// 12 — 元信息
    static let meta = Font.system(size: 12)
    /// 11 — 脚注
    static let footnote = Font.system(size: 11)
    /// 10 — 导航条标签、页码角标
    static let tiny = Font.system(size: 10, weight: .medium)

    /// 分组头：11px / 600 / 字距 .1em / 大写
    static let sectionHeader = Font.system(size: 11, weight: .semibold)

    /// 等宽数字版本 — 页数、评分、时间、体积、配额、ping 一律用这个，
    /// 否则数字变化时宽度会跳。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension View {
    /// 分组头样式：大写 + 字距 + 三级文字色
    func ehSectionHeader() -> some View {
        self.font(EhFont.sectionHeader)
            .tracking(1.1)              // ≈ .1em @ 11px
            .textCase(.uppercase)
            .foregroundStyle(EhColor.tertiaryLabel)
    }
}

// MARK: - 间距

enum EhSpacing {
    /// 页边距
    static let page: CGFloat = 16
    /// 行内间距（缩略图 ↔ 文字）
    static let row: CGFloat = 12
    /// 元信息行内各项间距
    static let meta: CGFloat = 8
    /// 分组之间
    static let section: CGFloat = 14
}

// MARK: - 圆角

enum EhRadius {
    static let card: CGFloat = 18
    static let group: CGFloat = 14
    static let control: CGFloat = 12
    static let smallControl: CGFloat = 10
    static let thumbnail: CGFloat = 6
    static let smallThumbnail: CGFloat = 4
    static let sheet: CGFloat = 24
    /// 胶囊 — 实际用 Capsule()，此值供需要具体数字的场合
    static let pill: CGFloat = 100
}

// MARK: - 尺寸

enum EhSize {
    /// 列表缩略图基准尺寸。实际使用请走 `ResponsiveLayout.galleryThumbnailSize`，
    /// 它会按 iPad ×1.15 / iPad Pro ×1.3 缩放。
    static let listThumbnail = CGSize(width: 76, height: 106)
    /// 详情封面
    static let detailCover = CGSize(width: 120, height: 168)
    /// 详情封面（大号，设置里可选）
    static let detailCoverLarge = CGSize(width: 160, height: 224)
    /// 预览网格单元
    static let preview = CGSize(width: 100, height: 142)
    /// 预览网格列数与间距
    static let previewColumns = 3
    static let previewGap: CGFloat = 10
    /// 历史行 / 下载行的缩略图。
    ///
    /// 与列表缩略图同尺寸。设计稿给的是 52×72 与 56×78，但三处并排看时
    /// 三种大小很扎眼——同一个东西在不同页面长得不一样，用户会以为是两类内容。
    /// 统一到 listThumbnail，行高也因此一致。
    static let historyThumbnail = listThumbnail
    static let downloadThumbnail = listThumbnail
    /// 「继续阅读」条的小封面
    static let resumeThumbnail = CGSize(width: 40, height: 56)

    /// macOS 内容顶部让位的基础高度（不含窗口工具栏）。
    ///
    /// 主体栏内容在 `MainTabView.macDetail` 里铺到工具栏下方
    /// （`ignoresSafeArea(.container, edges: .top)`），列表页与详情页都要让开
    /// 这段空间。实际让位高度 = 本常量 + `\.ehToolbarTopInset`（窗口工具栏高度）。
    /// 列表页与详情页共用同一个常量，两栏首行才不会上下错位。
    static let macTopContentClearance: CGFloat = 54

    /// 浮起导航条
    static let tabBarHeight: CGFloat = 58
    static let tabBarRadius: CGFloat = 29
    static let tabBarSideInset: CGFloat = 16
    static let tabBarBottomInset: CGFloat = 12

    /// 最小点按目标（HIG 要求 44×44）
    static let minTapTarget: CGFloat = 44

    /// 详情页操作区
    static let actionButtonHeight: CGFloat = 48
    static let actionSquareButton: CGFloat = 48

    /// 分类色条宽度
    static let categoryBarWidth: CGFloat = 3
    /// 评分条高度
    static let ratingBarHeight: CGFloat = 2
    /// 阅读进度条高度（历史/预览缩略图底部）
    static let progressBarHeight: CGFloat = 2
}

// MARK: - 玻璃层

extension View {
    /// 原生液态玻璃 —— 全 App 浮起控件的唯一玻璃 API。
    ///
    /// 搜索栏、浮起导航条、过滤胶囊、工具条、提示条等一律用它，
    /// 不再自绘材质。阅读器底是纯黑，用 `EhReaderChrome.glassTint` 压暗，
    /// 保证白色标签可读。
    func ehLiquidGlass<S: Shape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: shape)
    }

    /// 卡面容器
    func ehCard(cornerRadius: CGFloat = EhRadius.group) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(EhColor.card)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(EhColor.cardStroke, lineWidth: 0.5)
                }
        }
    }
}

// MARK: - 窗口工具栏高度

/// 窗口顶部工具栏在内容坐标系里的高度（仅 macOS 有值，其它平台恒为 0）。
///
/// 内容铺到工具栏下方后，浮起的搜索胶囊等控件据此下移，避免被工具栏盖住。
private struct EhToolbarTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var ehToolbarTopInset: CGFloat {
        get { self[EhToolbarTopInsetKey.self] }
        set { self[EhToolbarTopInsetKey.self] = newValue }
    }
}
