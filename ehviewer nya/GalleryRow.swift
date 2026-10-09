//
//  GalleryRow.swift
//  ehviewer nya
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 星级评分视图 (对齐 Android SimpleRatingView)

struct SimpleRatingView: View {
    let rating: Float

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                starImage(for: index)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func starImage(for index: Int) -> Image {
        let threshold = Float(index) + 1
        if rating >= threshold {
            return Image(systemName: "star.fill")
        } else if rating >= threshold - 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        } else {
            return Image(systemName: "star")
        }
    }
}

// MARK: - Gallery Row (对齐 Android item_gallery_list.xml 布局)
// Perf P0-3: showJpnTitle 从外部传入，禁止在 body 中读 AppSettings.shared

struct GalleryRow: View {
    let gallery: GalleryInfo
    let showJpnTitle: Bool
    let fixThumbUrl: Bool
    /// 由父视图处理：收藏可能需要弹收藏夹选择器，下载需要移动网络确认，
    /// 这些都不是一行自己能决定的。
    var onRequestDownload: (GalleryInfo) -> Void = { _ in }
    var onRequestFavorite: (GalleryInfo) -> Void = { _ in }
    /// 点标签直接按这个标签搜
    var onTagTap: ((String) -> Void)? = nil
    /// 当前搜索用到的标签，命中的 chip 会排前并高亮
    var highlightedTags: Set<String> = []

    /// 行的显示全部交给 EhGalleryRow(gallery:)，这里只负责把封面 URL 修正好。
    /// 显示开关、缩略图缩放、已下载/已收藏都在那个组件里统一处理——
    /// 放在调用方就会出现「首页有、别的页没有」。
    private var displayGallery: GalleryInfo {
        guard let fixed = thumbURL?.absoluteString, fixed != gallery.thumb else { return gallery }
        var copy = gallery
        copy.thumb = fixed
        return copy
    }

    /// 对齐 Android EhUrl.getFixedThumbUrl: 修复缩略图 CDN 域名不可达问题
    /// 开启时将 ehgt.org / gt0-3.ehgt.org 替换为当前站点的缩略图前缀
    private var thumbURL: URL? {
        guard var urlStr = gallery.thumb, !urlStr.isEmpty else { return nil }
        if fixThumbUrl {
            // 替换 ehgt.org 变体 (gt0.ehgt.org, gt1.ehgt.org ...)
            let site = AppSettings.shared.gallerySite
            let fixedPrefix = EhURL.thumbPrefix(for: site)
            // 匹配 https://ehgt.org/ 或 https://gt[0-3].ehgt.org/
            if let range = urlStr.range(of: "https://(?:gt\\d\\.)?ehgt\\.org/", options: .regularExpression) {
                urlStr.replaceSubrange(range, with: fixedPrefix)
            }
        }
        return URL(string: urlStr)
    }

    var body: some View {
        EhGalleryRow(gallery: displayGallery, onTagTap: onTagTap,
                     highlightedTags: highlightedTags)
            .contentShape(Rectangle())
        .contextMenu {
            // 下载
            Button {
                onRequestDownload(gallery)
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }

            // 收藏 / 取消收藏
            Button {
                onRequestFavorite(gallery)
            } label: {
                let favorited = GalleryStatusCache.shared.isFavorited(gallery)
                Label(favorited ? "取消收藏" : "收藏",
                      systemImage: favorited ? "heart.slash" : "heart")
            }

            Divider()

            // 复制链接
            Button {
                GalleryActionService.shared.copyLink(gid: gallery.gid, token: gallery.token)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }

            // 分享 (仅 iOS)
            #if os(iOS)
            ShareLink(item: URL(string: GalleryActionService.shared.galleryURL(gid: gallery.gid, token: gallery.token))!) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            #endif
        }
    }
}

