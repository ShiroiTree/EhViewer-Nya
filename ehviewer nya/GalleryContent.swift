//
//  GalleryContent.swift
//  ehviewer nya
//
//  画廊列表的「内容」部分：列表本体 + 行 + 加载/多选/刷新。
//
//  从 GalleryListView 里拆出来：容器（NavigationStack/分栏外壳）与页头（GalleryChrome）
//  归 GalleryListView，数据归 GalleryListViewModel，这里只管把两者画成一张列表。
//

import SwiftUI
import EhModels
import EhSettings
import EhDatabase

struct GalleryContent: View {
    /// 数据源。仅用于判断「首页」要不要挂继续阅读卡片。
    let mode: GalleryListView.ListMode
    /// 实际用于 loadMore / refresh 的模式（收藏夹内搜索时与 `mode` 不同）。
    let effectiveMode: GalleryListView.ListMode
    let viewModel: GalleryListViewModel

    /// 多选态（收藏页驱动）。非 nil 时才进入多选渲染分支。
    let isSelecting: Binding<Bool>?
    let selectedGids: Binding<Set<Int64>>?

    let highlightedTags: Set<String>
    let onRequestDownload: (GalleryInfo) -> Void
    let onRequestFavorite: (GalleryInfo) -> Void
    let onTagTap: (String) -> Void
    let isFavorited: (GalleryInfo) -> Bool

    var body: some View {
        // Perf P0-3: 一次性读取配置，避免每个 Row 重复读 UserDefaults
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        return List {
            // Fix F2-1: 首页顶部显示“继续阅读”卡片
            if case .home = mode {
                ContinueReadingCard()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            // 内联加载指示器 (不阻塞界面，用户可正常操作其他 Tab 和功能)
            if viewModel.isLoading && viewModel.galleries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
            }

            ForEach(viewModel.galleries, id: \.gid) { gallery in
                // NavigationLink 在 List 里会自动补一个 disclosure 箭头，设计稿没有它，
                // 而且每行右侧多出的 20pt 会挤压元信息行。把链接藏成零透明的底层，
                // 行本身画在它上面——点按仍由链接接收。
                Group {
                    if let isSelecting, let selectedGids, isSelecting.wrappedValue {
                        // 多选中：整行点按切换选中，不再进详情
                        HStack(spacing: 0) {
                            Image(systemName: selectedGids.wrappedValue.contains(gallery.gid)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selectedGids.wrappedValue.contains(gallery.gid)
                                                 ? EhColor.accent : EhColor.tertiaryLabel)
                                .padding(.leading, EhSpacing.page)
                            GalleryRow(
                                gallery: gallery, showJpnTitle: showJpn, fixThumbUrl: fixThumb
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            if selectedGids.wrappedValue.contains(gallery.gid) {
                                selectedGids.wrappedValue.remove(gallery.gid)
                            } else {
                                selectedGids.wrappedValue.insert(gallery.gid)
                            }
                        }
                    } else {
                        ZStack {
                            NavigationLink(value: gallery) { EmptyView() }
                                .opacity(0)
                            GalleryRow(
                                gallery: gallery, showJpnTitle: showJpn, fixThumbUrl: fixThumb,
                                onRequestDownload: onRequestDownload,
                                onRequestFavorite: onRequestFavorite,
                                onTagTap: onTagTap,
                                highlightedTags: highlightedTags
                            )
                        }
                    }
                }
                .overlay(alignment: .bottom) { EhHairline(inset: EhSpacing.page) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // 下载 (对齐 Android onItemLongClick: Download)
                    Button {
                        onRequestDownload(gallery)
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    .tint(.blue)

                    // 收藏 / 取消收藏 (对齐 Android onItemLongClick)
                    Button {
                        onRequestFavorite(gallery)
                    } label: {
                        Label(isFavorited(gallery) ? "取消收藏" : "收藏",
                              systemImage: isFavorited(gallery) ? "heart.slash" : "heart")
                    }
                    .tint(isFavorited(gallery) ? .gray : .red)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            // 加载更多
            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .task {
                        await viewModel.loadMore(mode: effectiveMode)
                    }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        // 向下滚收起底部导航条，向上滚放出来
        .ehTabBarAutoHide()
        .scrollDismissesKeyboard(.immediately)
        #endif
        .refreshable {
            await viewModel.refreshAsync(mode: effectiveMode)
        }
    }
}
