//
//  GalleryListView.swift
//  ehviewer nya
//
//  画廊列表视图 — 首页/热门/搜索结果
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

struct GalleryListView: View {
    let mode: ListMode

    enum ListMode {
        case home
        /// 订阅标签列表 (/watched) —— 对齐 Android SubscriptionsScene
        case subscription
        case popular
        /// 排行榜。period 就是 toplist.php 的 tl 参数：
        /// 15 全部时间 / 13 过去一年 / 12 过去一个月 / 11 昨天
        case toplist(period: Int)
        case search(SearchQuery)
        case tag(keyword: String)
        case favorites(slot: Int)

        var isSubscription: Bool {
            if case .subscription = self { return true }
            return false
        }
    }

    @State private var viewModel = GalleryListViewModel()
    @State private var showQuickSearch = false
    @State private var showAdvancedSearch = false
    @State private var showTagSelector = false
    @State private var showSavedSearches = false
    @State private var advancedSearch = AdvancedSearchState()
    @State private var selectedQuickSearch: QuickSearchRecord?
    @State private var selectedGallery: GalleryInfo?
    /// 搜索框聚焦态。用 @State 而非 @FocusState：焦点实际由
    /// UISearchTextField 持有，这里只是把它的状态镜像出来供布局使用。
    @State private var isSearchFocused: Bool = false
    /// 跳页模式切换 (对齐 Android JumpDateSelector: DATE_PICKER_TYPE / DATE_NODE_TYPE)
    /// 跳页模式: 0 = 快捷跳转, 1 = 日期选择, 2 = 页码跳转
    @State private var jumpMode: Int = 0

    /// 窗口工具栏高度（macOS 有值）。内容铺到工具栏下后，浮起的搜索胶囊据此下移。
    @Environment(\.ehToolbarTopInset) private var toolbarTopInset

    /// 标签导航路径 — iPad 双栏布局中支持标签推入左侧
    @State private var sidebarPath = NavigationPath()

    /// 外部选择绑定（嵌入三栏布局时使用）
    private var externalSelection: Binding<GalleryInfo?>?
    private var isEmbedded: Bool { externalSelection != nil }

    /// 是否作为 push 目标（避免嵌套 NavigationStack）
    private var isPushed: Bool = false

    /// 收藏夹搜索关键字 (对齐 Android FavoritesScene 搜索)
    private var favSearchKeyword: String?

    /// 嵌在别的页面里时隐藏自带的搜索栏。
    ///
    /// 收藏页自己已经有页头和搜索按钮，内嵌列表再画一条搜索栏就成了两个搜索入口，
    /// 上下叠在一起。
    private var hidesOwnSearchBar = false
    /// 由父视图接管空状态。
    ///
    /// 收藏页的「全部」把本地收藏区块和这个在线列表叠在一起：没登录时在线
    /// 列表永远是空的，于是本地收藏下面永远吊着一句「这个收藏夹是空的」。
    private var hidesEmptyState = false
    /// 多选模式。由父视图（收藏页）驱动：云端收藏夹此前完全没有批量操作，
    /// 想从收藏夹里删掉一本只能一本本进详情页。
    private var selectionBindings: (isSelecting: Binding<Bool>, selected: Binding<Set<Int64>>)?
    /// 把当前列表内容回传给父视图。
    /// 批量操作需要 token，而 gid 是查不到 token 的：GalleryCache 里只有
    /// 用户点开过的那几本，靠它去解析会静默跳过绝大多数选中项。
    private var visibleGalleries: Binding<[GalleryInfo]>?

    /// 顶部横向切页的选中项。非 nil 时在搜索栏下方渲染「首页/订阅/热门/排行」切页条。
    /// 只有作为浏览容器的根列表才传入；标签列表、搜索结果等推入的列表不显示切页条。
    private var browseSource: Binding<BrowseSource>?
    /// 排行榜的时间范围（toplist.php 的 tl 参数）。非排行榜模式为 nil。
    private var toplistPeriod: Binding<Int>?
    /// 提交搜索时交给父容器处理（切到独立的搜索页），而不是就地把
    /// 当前数据源变成搜索结果。只有浏览容器会传它。
    private var onSearchSubmit: ((SearchQuery) -> Void)?

    static let toplistPeriods: [(tl: Int, title: String)] = [
        (15, "全部时间"), (13, "过去一年"), (12, "过去一月"), (11, "昨天"),
    ]

    private var selectionBinding: Binding<GalleryInfo?> {
        externalSelection ?? $selectedGallery
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// iPad 侧边栏由 MainTabView 统一管理，GalleryListView 不再创建自己的 SplitView
    private var isRegularWidth: Bool { false }
    #else
    /// macOS 也支持全宽单列表模式
    private var isRegularWidth: Bool { AppSettings.shared.wideScreenListMode == 0 }
    #endif

    init(mode: ListMode, toplistPeriod: Binding<Int>? = nil) {
        self.mode = mode
        self.toplistPeriod = toplistPeriod
        self.externalSelection = nil
    }

    /// 浏览容器的根列表 — 在搜索栏下方带出顶部切页条
    init(mode: ListMode, browseSource: Binding<BrowseSource>, toplistPeriod: Binding<Int>? = nil,
         onSearchSubmit: ((SearchQuery) -> Void)? = nil) {
        self.toplistPeriod = toplistPeriod
        self.onSearchSubmit = onSearchSubmit
        self.mode = mode
        self.externalSelection = nil
        self.browseSource = browseSource
    }

    /// 作为导航目标推入时使用，不创建自己的 NavigationStack/SplitView。
    /// `toplistPeriod` 非 nil 时在页头带出排行周期条（`mode` 为排行榜才有意义）。
    init(mode: ListMode, isPushed: Bool, toplistPeriod: Binding<Int>? = nil) {
        self.mode = mode
        self.isPushed = isPushed
        self.toplistPeriod = toplistPeriod
        self.externalSelection = nil
    }

    init(mode: ListMode, selection: Binding<GalleryInfo?>, toplistPeriod: Binding<Int>? = nil) {
        self.mode = mode
        self.externalSelection = selection
        self.toplistPeriod = toplistPeriod
    }

    /// 收藏搜索模式
    init(mode: ListMode, searchKeyword: String?, hidesOwnSearchBar: Bool = false,
         hidesEmptyState: Bool = false,
         isSelecting: Binding<Bool>? = nil,
         selectedGids: Binding<Set<Int64>>? = nil,
         visibleGalleries: Binding<[GalleryInfo]>? = nil) {
        self.mode = mode
        self.favSearchKeyword = searchKeyword
        self.externalSelection = nil
        self.hidesOwnSearchBar = hidesOwnSearchBar
        self.hidesEmptyState = hidesEmptyState
        self.visibleGalleries = visibleGalleries
        if let isSelecting, let selectedGids {
            self.selectionBindings = (isSelecting, selectedGids)
        }
    }

    /// 收藏搜索模式 (嵌入)
    init(mode: ListMode, selection: Binding<GalleryInfo?>, searchKeyword: String?,
         hidesOwnSearchBar: Bool = false, hidesEmptyState: Bool = false) {
        self.mode = mode
        self.externalSelection = selection
        self.favSearchKeyword = searchKeyword
        self.hidesOwnSearchBar = hidesOwnSearchBar
        self.hidesEmptyState = hidesEmptyState
    }

    /// 排行榜的周期可能来自可改的 `toplistPeriod` 绑定，以绑定值为准；
    /// 其它模式原样返回。
    private var modeRespectingToplistPeriod: ListMode {
        if case .toplist = mode, let period = toplistPeriod?.wrappedValue {
            return .toplist(period: period)
        }
        return mode
    }

    /// 当前实际运行模式 — 如果搜索框有内容，则为搜索模式
    /// 但收藏夹模式下搜索应保持在收藏夹内 (对齐 Android: 收藏夹搜索只搜收藏内容)
    private var effectiveMode: ListMode {
        if !viewModel.searchQuery.isEmpty {
            if case .favorites = mode {
                // 收藏夹下搜索保持在收藏夹模式，搜索关键词通过 searchQuery 传递给 API
                return mode
            }
            // 浏览容器里由父视图把搜索切成独立的一页（见 onSearchSubmit），
            // 这里不能再就地把「订阅」「热门」「排行」偷偷变成搜索结果 ——
            // 那正是「顶部还高亮着订阅、内容却是全站搜索」的来源。
            if onSearchSubmit != nil { return modeRespectingToplistPeriod }
            return .search(viewModel.searchQuery)
        }
        return modeRespectingToplistPeriod
    }



    var body: some View {
        // 诊断: 确认 body 是否被无限重渲染 (NSLog 不受缓冲影响，崩溃前也能看到)
        #if DEBUG
        let _ = Self._printChanges()  // ★ 精确显示触发源: @self/@identity/_property
        #endif
        let _ = NSLog("[RENDER] GalleryListView body, mode=%@, galleries=%d", String(describing: mode), viewModel.galleries.count)
        Group {
            if isEmbedded {
                // 嵌入模式: 仅展示列表，由父视图管理导航
                embeddedContent
            } else if isPushed {
                // 被推入导航栈时: 不创建自己的 NavigationStack，避免嵌套
                pushedContent
        } else if isRegularWidth {
            // iPadOS / macOS 独立模式: 双栏布局
            NavigationSplitView {
                NavigationStack(path: $sidebarPath) {
                    sidebarContent
                        .navigationTitle(navigationTitle)
                        // 侧栏里标签/上传者推入的列表同样嵌入本栈，行驱动右侧详情
                        .ehGalleryDestinations(.embedded($selectedGallery))
                }
                .navigationSplitViewColumnWidth(min: 350, ideal: 400, max: 500)
            } detail: {
                // Detail 部分需要 NavigationStack 才能支持 navigationDestination
                NavigationStack {
                    if let gallery = selectedGallery {
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)  // 强制在选择变更时重新创建视图，修复封面不刷新问题
                    } else {
                        ContentUnavailableView("选择画廊", systemImage: "photo.stack", description: Text("从左侧列表选择一个画廊"))
                    }
                }
                // 详情列点标签/上传者 → 推入侧栏栈（详情列与侧栏是两个独立栈）
                .environment(\.galleryNavigationAction, GalleryNavigationAction { route in
                    sidebarPath.append(route)
                })
            }
        } else {
            // iPhone: 单栏布局
            compactContent
        }
        }
        .task {
            print("[EhView] body .task fired, mode=\(mode), galleries=\(viewModel.galleries.count), isLoading=\(viewModel.isLoading)")
            // 异步执行 ViewModel 初始化 — 避免 .onAppear 同步变更 @Observable 导致 NavigationStack 多次更新
            viewModel.favSearchKeyword = favSearchKeyword
            viewModel.loadSearchHistory()
            // 已下载标记要有数据才画得出来
            if !GalleryStatusCache.shared.isLoaded {
                await GalleryStatusCache.shared.reload()
            }
            if case .tag(let keyword) = mode, viewModel.searchQuery.isEmpty {
                viewModel.searchQuery = SearchQuery(terms: [.keyword(keyword)])
            }
            // 搜索页刚建好时，把查询摆回输入框——否则搜索页的输入框是空的，
            // 用户看不到自己搜的是什么，也没法在此基础上增删条件
            if case .search(let query) = mode, searchTerms.isEmpty, !query.isEmpty {
                syncField(from: query)
            }

            // 安全兜底: 确保数据加载在任何分支下都能触发
            if viewModel.galleries.isEmpty && !viewModel.isLoading {
                // effectiveMode：上面几行刚把 favSearchKeyword 写进 searchText，
                // 用 mode 会忽略它，首次进入收藏搜索页会加载成整个收藏夹
                viewModel.loadGalleries(mode: effectiveMode)
            }
        }
        .onChange(of: viewModel.galleries) { _, list in
            visibleGalleries?.wrappedValue = list
        }
        // 排行周期条改了就按新周期重新加载（mode 里的周期只是初值）
        .onChange(of: toplistPeriod?.wrappedValue) { _, _ in
            viewModel.loadGalleries(mode: effectiveMode)
        }
        .onChange(of: showAdvancedSearch) { _, isShowing in
            if !isShowing {
                // 高级搜索面板关闭时，静默保存参数到 ViewModel (不自动触发搜索)
                // 用户提交搜索或点击搜索按钮时才会使用这些参数
                viewModel.syncAdvancedSettings(advancedSearch)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleryFavoriteChanged)) { notification in
            // 收藏状态同步: 详情页收藏/取消收藏后，列表内对应画廊的收藏标记实时更新，无需刷新
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64 else { return }
            let favorited = userInfo["favorited"] as? Bool ?? false
            let slot = userInfo["slot"] as? Int ?? -1
            if let index = viewModel.galleries.firstIndex(where: { $0.gid == gid }) {
                viewModel.galleries[index].favoriteSlot = favorited ? slot : -1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GalleryActionService.siteChangedNotification)) { _ in
            // 站点切换后清除缓存并重新加载 (对齐 Android: 切换站点 → 刷新列表)
            // 同样用 effectiveMode，否则切站点会把用户正在看的搜索结果换成首页
            viewModel.refresh(mode: effectiveMode)
        }
    }

    /// 画廊列表统一的页头：搜索栏 +（可选）顶部切页 +（可选）排行周期。
    ///
    /// **所有布局变体都走这一个 builder**——compact / pushed / sidebar 只是导航外壳
    /// 不同，页头控件不该随外壳变化。此前 pushed / sidebar 只画了搜索栏，
    /// 于是同一个数据源在不同入口少了切页与周期条。
    /// 切页与周期条仅在对应绑定非 nil 时出现，所以未接管这些绑定的入口行为不变。
    @ViewBuilder
    private var galleryChrome: some View {
        VStack(spacing: 0) {
            if !hidesOwnSearchBar {
                searchBarView
            }
            // 顶部横向切页 — 首页/订阅/热门/排行。
            // 这四者是同一类内容的不同数据源，放在同一层级横向切换；
            // 此前热门与排行要经「更多」标签页二级跳转才能到达。
            if let browseSource {
                EhTopTabs(
                    items: BrowseSource.allCases.map { ($0, $0.title) },
                    selection: browseSource
                )
            }
            // 排行榜的时间范围。挂在切页条下面而不是另起一屏，
            // 是因为它和「首页/订阅/热门」是同一层级的数据源筛选。
            if let toplistPeriod {
                EhFilterPills(
                    items: Self.toplistPeriods.map { ($0.tl, $0.title) },
                    selection: toplistPeriod
                )
                .padding(.bottom, 6)
            }
        }
    }

    // iPhone 布局
    private var compactContent: some View {
        NavigationStack {
            Group {
                // 聚焦搜索时由面板接管搜索框以下的区域——此时列表内容与用户无关。
                // 搜索框本身留在上面，否则用户看不到自己正在打什么。
                if isSearchFocused {
                    VStack(spacing: 0) {
                        if !hidesOwnSearchBar {
                            searchBarView
                        }
                        searchSuggestionsOverlay
                    }
                } else {
                    Group {
                        if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                            errorView
                        } else if viewModel.galleries.isEmpty && !viewModel.isLoading {
                            // 加载完但一条都没有：此前直接渲染空 List，屏幕一片白，
                            // 用户分不清是没结果、没登录，还是界面坏了
                            if !hidesEmptyState { emptyStateView }
                        } else {
                            // 离线可用: 始终显示列表结构，加载指示器为内联行，不阻塞界面
                            galleryList
                        }
                    }
                    // 页头浮在列表之上，列表内容从其下方滚过，玻璃才有内容可折射。
                    .safeAreaInset(edge: .top, spacing: 0) {
                        galleryChrome
                    }
                }
            }
            // 详情 / 标签列表 / 上传者查询的落点集中在此注册
            .ehGalleryDestinations(.pushed)
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // 作为浏览容器的根列表时隐藏系统导航栏——设计稿里这一屏
            // 从搜索胶囊开始，标题栏只是重复了顶部切页已经表达的信息。
            // 推入的列表（标签、搜索结果）仍需要标题与返回按钮，故只在根列表隐藏。
            .toolbar(browseSource != nil ? .hidden : .visible, for: .navigationBar)
            #endif
            .toolbar { galleryToolbar }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isSearchFocused = false }
                }
            }
            #endif
            // 整屏覆盖而不是贴在搜索栏下方的小浮层：
            // 聚焦时列表内容与用户无关，让面板完全接管

            .rightDrawer(isOpen: $showQuickSearch) {
                QuickSearchDrawerContent(
                    selectedSearch: $selectedQuickSearch,
                    currentKeyword: viewModel.searchText,
                    onDismiss: { showQuickSearch = false }
                )
            }
            .sheet(isPresented: $showAdvancedSearch) {
                AdvancedSearchView(state: advancedSearch)
            }
            .sheet(isPresented: $showSavedSearches) {
                SavedSearchView(currentQuery: currentQuery, onRun: { query in
                    showSavedSearches = false
                    dispatchQuery(query)
                })
            }
            .sheet(item: $pendingDownload) { gallery in
                DownloadLabelPicker(
                    onSelect: { label in
                        pendingDownload = nil
                        Task { await GalleryActionService.shared.startDownload(gallery: gallery, label: label) }
                    },
                    onCancel: { pendingDownload = nil }
                )
            }
            .sheet(item: $pendingFavorite) { gallery in
                FavoriteSlotPicker(
                    onSelect: { slot in
                        pendingFavorite = nil
                        Task {
                            if slot == -1 {
                                GalleryActionService.shared.addLocalFavorite(gallery: gallery)
                            } else {
                                try? await GalleryActionService.shared.addFavorite(
                                    gid: gallery.gid, token: gallery.token, slot: slot
                                )
                            }
                        }
                    },
                    onCancel: { pendingFavorite = nil }
                )
            }
            .sheet(isPresented: $showTagSelector) {
                TagSelectorView { keyword in
                    // 选中的标签直接进搜索框成为一条条件，
                    // 而不是在选择器里另画一条「预览」——预览是同一信息说两遍。
                    // keyword 是已渲染的搜索式（如 `f:"big breasts$"`），解析回来即可。
                    for term in SearchQuery.parse(keyword).terms {
                        if !searchTerms.contains(where: { $0.render() == term.render() }) {
                            searchTerms.append(term)
                        }
                    }
                }
            }
            .onChange(of: selectedQuickSearch) { _, newValue in
                if let search = newValue {
                    applyQuickSearch(search)
                    selectedQuickSearch = nil
                }
            }
        }
        // ★ 已移除 compactContent 级 .task — 避免与 body .task 重复加载，由 body .task 统一管理
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    /// 被推入导航栈时的内容 — 不包装 NavigationStack，避免嵌套
    private var pushedContent: some View {
        Group {
            if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                VStack(spacing: 0) {
                    galleryChrome
                    errorView
                }
            } else {
                galleryList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        galleryChrome
                    }
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { galleryToolbar }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isSearchFocused = false }
            }
        }
        #endif

        .rightDrawer(isOpen: $showQuickSearch) {
            QuickSearchDrawerContent(
                selectedSearch: $selectedQuickSearch,
                currentKeyword: viewModel.searchText,
                onDismiss: { showQuickSearch = false }
            )
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .sheet(isPresented: $showSavedSearches) {
            SavedSearchView(currentQuery: currentQuery, onRun: { query in
                showSavedSearches = false
                dispatchQuery(query)
            })
        }
        .sheet(isPresented: $showTagSelector) {
            TagSelectorView { keyword in
                for term in SearchQuery.parse(keyword).terms {
                    if !searchTerms.contains(where: { $0.render() == term.render() }) {
                        searchTerms.append(term)
                    }
                }
            }
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                applyQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .task {
            if viewModel.galleries.isEmpty {
                viewModel.loadGalleries(mode: effectiveMode)
            }
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .home: return AppSettings.shared.gallerySite == .exHentai ? "ExHentai" : "E-Hentai"
        case .subscription: return "订阅"
        case .popular: return "热门"
        case .toplist: return "排行"
        case .search(let query): return "搜索: \(query.render())"
        case .tag: return "标签搜索"  // 对齐 Android: 标签关键字显示在搜索框而非标题
        case .favorites: return "收藏"
        }
    }

    /// 列表本体拆分到 `GalleryContent`：容器/页头归本视图，数据归 ViewModel。
    private var galleryList: some View {
        GalleryContent(
            mode: mode,
            effectiveMode: effectiveMode,
            viewModel: viewModel,
            isSelecting: selectionBindings?.isSelecting,
            selectedGids: selectionBindings?.selected,
            highlightedTags: activeSearchTags,
            onRequestDownload: requestDownload,
            onRequestFavorite: toggleFavorite,
            onTagTap: searchTag,
            isFavorited: isFavorited
        )
    }

    // 嵌入模式内容（无导航包装器，用于三栏布局的 content 列）
    private var embeddedContent: some View {
        sidebarContent
            .navigationTitle(navigationTitle)
            .task {
                if viewModel.galleries.isEmpty {
                    viewModel.loadGalleries(mode: effectiveMode)
                }
            }
    }

    // iPad/Mac 侧边栏内容
    private var sidebarContent: some View {
        // Perf P0-3: 一次性读取配置
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        return Group {
            if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                VStack(spacing: 0) {
                    galleryChrome
                    errorView
                }
            } else {
                List(selection: selectionBinding) {
                        // 顶部空白占位：给浮起的搜索胶囊让位，避免初始遮住第一条。
                        // 再加上工具栏高度——内容现在铺到了工具栏下方。
                        Color.clear
                            .frame(height: EhSize.macTopContentClearance + toolbarTopInset)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        // 内联加载指示器 (不阻塞界面)
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
                            GalleryRow(
                        gallery: gallery, showJpnTitle: showJpn, fixThumbUrl: fixThumb,
                        onRequestDownload: requestDownload,
                        onRequestFavorite: toggleFavorite,
                        onTagTap: searchTag,
                        highlightedTags: activeSearchTags
                    )
                                .tag(gallery)
                        }

                        if viewModel.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                                .task {
                                    await viewModel.loadMore(mode: effectiveMode)
                                }
                        }
                    }
                    .listStyle(.sidebar)
//                    .safeAreaInset(edge: .top, spacing: 0) {
//                        Color.clear.frame(height: 54)
//                    }
                    .overlay(alignment: .top) {
                        galleryChrome
                            .padding(.top, toolbarTopInset)
                    }
                    .refreshable {
                        await viewModel.refreshAsync(mode: effectiveMode)
                    }
            }
        }
        .toolbar { galleryToolbar }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isSearchFocused = false }
            }
        }
        #endif

        .rightDrawer(isOpen: $showQuickSearch) {
            QuickSearchDrawerContent(
                selectedSearch: $selectedQuickSearch,
                currentKeyword: viewModel.searchText,
                onDismiss: { showQuickSearch = false }
            )
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .sheet(isPresented: $showSavedSearches) {
            SavedSearchView(currentQuery: currentQuery, onRun: { query in
                showSavedSearches = false
                dispatchQuery(query)
            })
        }
        .sheet(isPresented: $showTagSelector) {
            TagSelectorView { keyword in
                for term in SearchQuery.parse(keyword).terms {
                    if !searchTerms.contains(where: { $0.render() == term.render() }) {
                        searchTerms.append(term)
                    }
                }
            }
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                applyQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    // MARK: - 搜索栏 (对齐 Android SearchBar，从 toolbar 移到 body header 以获得完整宽度)

    /// 已确定的搜索条件（标签 / 上传者 / 自由文本）。文字与 term 在同一个输入框里
    /// 混排：点 term 上的叉删掉整个条件，光标在文字里时退格照常改字。
    @State private var searchTerms: [SearchTerm] = []

    /// 输入框里**正在打的文字**，只含自由文本。
    ///
    /// 不能直接绑 `viewModel.searchQuery`：那里保存的是提交给服务端的完整查询，
    /// 提交时会把 term 合并进去；绑在一起就会出现「term 胶囊后面还跟着
    /// 同一个标签的文字」的重复显示。
    @State private var searchFieldText = ""

    /// 正在把外部查询回填进输入框。回填期间要挡住 term 变化触发的重搜，
    /// 否则会把快速搜索自带的分类/评分条件冲掉，还白跑一次网络。
    @State private var isSyncingTerms = false

    /// 等待选择收藏夹的画廊（没有设默认收藏夹时）
    @State private var pendingFavorite: GalleryInfo?
    /// 待选下载标签的画廊（对齐 Android 的下载标签对话框）
    @State private var pendingDownload: GalleryInfo?


    private var searchBarView: some View {
        EhSearchBar(
            text: $searchFieldText,
            tokens: $searchTerms,
            placeholder: "搜索标签或标题",
            isFocused: $isSearchFocused,
            // 右侧不再放小图标：15pt 的点按目标远低于 HIG 的 44pt，手机上按不中。
            // 标签选择器、高级搜索、快速搜索都移进聚焦面板，那里有整行宽度。
            trailingButtons: [],
            onSubmit: { submitSearch() }
        )
        .onChange(of: searchFieldText) { _, text in
            viewModel.updateSuggestions(for: text)
        }
        .onChange(of: searchTerms) { _, _ in
            guard !isSyncingTerms else { return }
            // term 变了就重搜：删掉一个条件本身就是一次条件变更
            dispatchCurrentQuery()
        }
        // 外部改了查询就回填到输入框。
        //
        // 输入框显示的是 searchTerms + searchFieldText，而不是
        // viewModel.searchQuery（两者当初为了修「同一标签既是 term 又是文字」
        // 的重复显示而解耦）。于是任何只写 viewModel.searchQuery 的路径
        // ——快速搜索、收藏夹内搜索、从详情页点标签进来——输入框都是空的。
        // 与其逐条去补，不如在这里统一回填：新增路径也自动生效。
        .onChange(of: viewModel.searchQuery) { _, newValue in
            guard newValue != currentQuery else { return }
            syncField(from: newValue)
        }
    }

    /// 当前搜索里用到的标签。用于把命中的 chip 排到前面并高亮——
    /// 搜某个标签时，最想确认的就是「这本是因为哪个标签被搜出来的」，
    /// 而它常常排在第五个之后，根本看不见。
    private var activeSearchTags: Set<String> {
        Set(searchTerms.compactMap { term in
            switch term.kind {
            case .tag, .keyword: return term.bareText
            case .uploader: return nil
            }
        })
    }

    /// 输入框当前表达的查询（已确定 term + 正在打的字）
    private var currentQuery: SearchQuery {
        let typed = searchFieldText.trimmingCharacters(in: .whitespaces)
        var terms = searchTerms
        if !typed.isEmpty { terms.append(.keyword(typed)) }
        return SearchQuery(terms: terms)
    }

    /// 把一条查询摆进输入框，拆成 term 显示
    private func syncField(from query: SearchQuery) {
        isSyncingTerms = true
        searchTerms = query.terms
        searchFieldText = ""
        // 下一个 runloop 再解锁：onChange(searchTerms) 是在本次更新之后才跑的
        DispatchQueue.main.async { isSyncingTerms = false }
    }

    /// 这一本收藏过没有。云端收藏夹或本地收藏都算。
    private func isFavorited(_ gallery: GalleryInfo) -> Bool {
        GalleryStatusCache.shared.isFavorited(gallery)
    }

    /// 收藏 / 取消收藏。
    ///
    /// 此前无论已收藏与否都只调 quickFavorite（只会「加」）：侧滑出来的按钮
    /// 明明写着「取消收藏」，按下去却是再收藏一次。云端收藏夹里想删掉一本，
    /// 只能进详情页——列表页那个按钮是个谎。
    private func toggleFavorite(_ gallery: GalleryInfo) {
        if isFavorited(gallery) {
            Task {
                try? await GalleryActionService.shared.removeFavorite(
                    gid: gallery.gid, token: gallery.token)
            }
        } else {
            requestFavorite(gallery)
        }
    }

    /// 收藏。没设默认收藏夹时弹选择器——此前这里直接丢掉了
    /// `quickFavorite` 的返回值，于是没设默认的用户点侧滑/长按收藏毫无反应。
    /// 成功与失败的提示由 GalleryActionService 统一发出。
    private func requestFavorite(_ gallery: GalleryInfo) {
        Task {
            if await GalleryActionService.shared.quickFavorite(gallery: gallery) == .needsPicker {
                pendingFavorite = gallery
            }
        }
    }

    /// 快速搜索。在浏览容器里同样要切到搜索页，
    /// 而不是把当前这一页原地变成搜索结果。
    private func applyQuickSearch(_ search: QuickSearchRecord) {
        if let onSearchSubmit, let keyword = search.keyword, !keyword.isEmpty {
            onSearchSubmit(SearchQuery.parse(keyword))
        } else {
            viewModel.applyQuickSearch(search)
        }
    }

    /// 点列表行里的标签 chip：把它**追加**成一枚 term 并立刻搜。
    ///
    /// 追加而不是覆盖是关键——此前 `searchTokens = [quoted]` 的覆盖式赋值
    /// 让点第二个标签会顶掉第一个，多标签根本无法组合。
    /// 在浏览容器里同样要切到搜索页，否则点个标签就把「热门」变成了搜索结果。
    private func searchTag(_ tag: String) {
        appendTerm(SearchTerm.makeTag(tag))
        dispatchCurrentQuery()
    }

    /// 追加一枚 term（按渲染形式去重）。
    ///
    /// 用 `isSyncingTerms` 挡住它触发的 `onChange(of: searchTerms)` 重搜，
    /// 否则会和调用点显式的 dispatch 撞成两次网络请求。
    private func appendTerm(_ term: SearchTerm) {
        guard !searchTerms.contains(where: { $0.render() == term.render() }) else { return }
        isSyncingTerms = true
        searchTerms.append(term)
        DispatchQueue.main.async { isSyncingTerms = false }
    }

    /// 用当前输入框表达的条件发起搜索。
    ///
    /// 标签点击、上传者点击、已保存搜索、历史选择与手动提交都走这里，
    /// 避免各写一套而出现重复提交或状态不一致。
    private func dispatchCurrentQuery() {
        isSearchFocused = false
        let query = currentQuery
        guard !query.isEmpty else { return }
        if let onSearchSubmit {
            // 交给浏览容器切到搜索页；这一份列表随之被重建
            onSearchSubmit(query)
        } else {
            viewModel.performSearch(query: query, advanced: advancedSearch)
        }
    }

    /// 用一个现成的查询替换当前条件并搜索（历史条目、已保存搜索）。
    private func dispatchQuery(_ query: SearchQuery) {
        isSyncingTerms = true
        searchTerms = query.terms
        DispatchQueue.main.async { isSyncingTerms = false }
        searchFieldText = ""
        isSearchFocused = false
        if let onSearchSubmit {
            onSearchSubmit(query)
        } else {
            viewModel.performSearch(query: query, advanced: advancedSearch)
        }
    }

    /// 下载。建过下载标签且没设默认时先问放哪个标签——
    /// 对齐 Android CommonOperations.startDownload。
    private func requestDownload(_ gallery: GalleryInfo) {
        if GalleryActionService.shared.downloadLabelChoiceNeeded() {
            pendingDownload = gallery
        } else {
            Task { await GalleryActionService.shared.startDownload(gallery: gallery) }
        }
    }

    /// 提交搜索。
    ///
    /// 正在打的文字在**提交时**才收成一枚 term，不写回 viewModel.searchQuery——
    /// 写回去会让同一个条件既显示为 term 又显示为文字（搜索框里出现
    /// 「bdsm」胶囊后面还跟着 f:bdsm$ 这样的重复）。
    private func submitSearch() {
        let typed = searchFieldText.trimmingCharacters(in: .whitespaces)

        // 打出来的自由文本收成一枚 term 留在输入框里，这样从列表回来仍能看到
        // 当前搜索条件，也能逐个删掉某一条重搜，而不必整串清空重打。
        if !typed.isEmpty { appendTerm(.keyword(typed)) }
        searchFieldText = ""
        dispatchCurrentQuery()
    }

    // MARK: - 统一工具栏 (对齐 Android FAB secondaryButtons)

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        // 其余按钮 (对齐 Android FAB secondaryButtons)
        ToolbarItemGroup(placement: .automatic) {
            // 快速搜索 (对齐 Android QuickSearch)
            Button { showQuickSearch.toggle() } label: {
                Image(systemName: showQuickSearch ? "bookmark.fill" : "bookmark")
            }

            // 跳页 (对齐 Android showGoToDialog: 支持页码/日期/快捷跳转；按钮开关浮层)
            Button {
                viewModel.showJumpDialog.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .disabled(viewModel.galleries.isEmpty)
            .popover(isPresented: $viewModel.showJumpDialog) {
                jumpPopover
            }
        }
    }

    // MARK: - 搜索建议浮层 (对齐 Android SearchBar.updateSuggestions 下拉列表)

    /// 搜索聚焦面板 —— 设计稿第 2 屏。
    ///
    /// 此前是个 300pt 高的下拉浮层，只放了历史与建议；标签选择器、高级搜索、
    /// 快速搜索被塞进搜索胶囊右侧的三个 15pt 图标里，手机上点不中，
    /// 「快速搜索」还在改版时整个丢了。整屏接管后这些都有整行的落点。
    @ViewBuilder
    private var searchSuggestionsOverlay: some View {
        if isSearchFocused {
            SearchFocusPanel(
                text: searchFieldText,
                tokens: $searchTerms,
                suggestions: viewModel.suggestions,
                history: viewModel.searchHistory,
                onPickSuggestion: { tag in
                    // 建议取代了正在打的那段文字：清掉它，否则提交时它会再变成
                    // 一条条件，同一个标签就出现两遍。建议给的是 `female:big breasts`
                    // 这样的原文，收成结构化 tag 才能正确加引号。
                    searchFieldText = ""
                    let term = SearchTerm.makeTag(tag)
                    if !searchTerms.contains(where: { $0.render() == term.render() }) {
                        searchTerms.append(term)
                    }
                },
                onClearHistory: { viewModel.clearSearchHistory() },
                onPickHistory: { term in
                    // 历史条目本身就是一条完整查询，替换掉当前条件直接搜，
                    // 不塞进输入框再拼一次
                    dispatchQuery(SearchQuery.parse(term))
                },
                onOpenTagSelector: { showTagSelector = true },
                onOpenAdvancedSearch: { showAdvancedSearch = true },
                onOpenQuickSearch: { showQuickSearch = true },
                onOpenSavedSearch: { isSearchFocused = false; showSavedSearches = true },
                isAdvancedActive: advancedSearch.isEnabled
            )
            .transition(.opacity)
        }
    }

    // MARK: - 跳页 Sheet (对齐 Android JumpDateSelector: 日期 / 快捷节点 双模式)

    /// 快捷跳转节点 (对齐 Android JumpDateSelector DATE_NODE_TYPE)
    private static let jumpNodes: [(label: String, value: String)] = [
        ("1 天", "1d"), ("3 天", "3d"),
        ("1 周", "1w"), ("2 周", "2w"),
        ("1 月", "1m"), ("6 月", "6m"),
        ("1 年", "1y"), ("2 年", "2y"),
    ]
    @State private var selectedJumpNode: String = "1d"

    /// 把 "2w" 这样的相对跨度换算成实际日期，显示在快捷项下面
    private static func targetDateHint(for node: String) -> String {
        guard let unit = node.last,
              let amount = Int(node.dropLast()) else { return "" }
        var component = DateComponents()
        switch unit {
        case "d": component.day = -amount
        case "w": component.day = -amount * 7
        case "m": component.month = -amount
        case "y": component.year = -amount
        default: return ""
        }
        guard let date = Calendar.current.date(byAdding: component, to: Date()) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    /// 跳页浮层。用 `.popover` 从工具栏按钮弹出，系统会自动给它套上液态玻璃；
    /// 所以这里不能铺任何不透明底色，否则玻璃会被盖住。
    private var jumpPopover: some View {
        VStack(spacing: 0) {
            Text("跳页")
                .font(EhFont.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, EhSpacing.page)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 16) {
                    // 模式切换 (对齐 Android JumpDateSelector 的 toggle 按钮)
                    EhSegmented(
                        items: viewModel.totalPages > 0
                            ? [(0, "快捷"), (1, "按日期"), (2, "按页码")]
                            : [(0, "快捷"), (1, "按日期")],
                        selection: $jumpMode
                    )
                    .padding(.horizontal, EhSpacing.page)
                    .padding(.top, 8)

                    if jumpMode == 0 {
                        // 快捷节点 (对齐 Android JumpDateSelector RadioGroup)
                        VStack(spacing: 12) {
                            Text("选择时间范围快速跳转")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 10) {
                                ForEach(Self.jumpNodes, id: \.value) { node in
                                    Button {
                                        selectedJumpNode = node.value
                                    } label: {
                                        VStack(spacing: 2) {
                                            Text(node.label)
                                                .font(EhFont.body)
                                            // 「1 周」不如「跳到 08-21」直观：
                                            // 用户脑子里想的是日期，不是相对天数
                                            Text(Self.targetDateHint(for: node.value))
                                                .font(EhFont.mono(11))
                                                .foregroundStyle(EhColor.tertiaryLabel)
                                        }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                selectedJumpNode == node.value
                                                    ? EhColor.accentWash
                                                    : EhColor.fill
                                            )
                                            .foregroundStyle(
                                                selectedJumpNode == node.value
                                                    ? EhColor.accent
                                                    : EhColor.label
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(
                                                        selectedJumpNode == node.value
                                                            ? Color.accentColor
                                                            : Color.clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    } else if jumpMode == 1 {
                        // 日期选择器 (对齐 Android JumpDateSelector DATE_PICKER_TYPE)
                        Text("选择日期跳转到对应时间的画廊")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        DatePicker(
                            "跳转日期",
                            selection: $viewModel.jumpDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                    } else if jumpMode == 2 {
                        // 页码跳转
                        VStack(spacing: 12) {
                            Text("输入页码跳转 (1-\(viewModel.totalPages))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            TextField("页码", text: $viewModel.goToPageInput)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }

                    // 前/后页快捷按钮 (仅收藏模式)
                    if viewModel.isFavoritesMode {
                        HStack(spacing: 16) {
                            if let prevHref = viewModel.prevHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(prevHref, mode: effectiveMode)
                                } label: {
                                    Label("上一页", systemImage: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let nextHref = viewModel.nextHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(nextHref, mode: effectiveMode)
                                } label: {
                                    Label("下一页", systemImage: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            HStack(spacing: 10) {
                Button("取消") { viewModel.showJumpDialog = false }
                    .buttonStyle(EhTintedButtonStyle(height: 40))
                Button("跳转") { performJump() }
                    .buttonStyle(EhFilledButtonStyle(height: 40))
            }
            .padding(14)
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        .frame(height: 440)
    }

    private func performJump() {
        viewModel.showJumpDialog = false
        if jumpMode == 0 {
            viewModel.goToJump("jump=\(selectedJumpNode)", mode: effectiveMode)
        } else if jumpMode == 1 {
            viewModel.goToDate(viewModel.jumpDate, mode: effectiveMode)
        } else if jumpMode == 2 {
            if let page = Int(viewModel.goToPageInput), page >= 1,
               page <= viewModel.totalPages {
                viewModel.goToPage(page - 1, mode: effectiveMode)
            }
            viewModel.goToPageInput = ""
        }
    }

    /// 当前错误是不是 IP 封禁 (issue #1: 以前这种情况只显示一片空白)
    private var isIPBanned: Bool {
        viewModel.errorMessage?.contains("临时封禁") == true
    }

    /// 空结果态。按当前模式给出对应的下一步，而不是一句笼统的「暂无内容」。
    @ViewBuilder
    private var emptyStateView: some View {
        switch mode {
        case .favorites:
            EhStateView(kind: .empty(
                symbol: "heart",
                title: "这个收藏夹是空的",
                message: "在画廊详情页点 ♡ 就能加进来；云收藏夹需要登录后才会同步"
            ))
        case .subscription:
            EhStateView(kind: .empty(
                symbol: "bell",
                title: "订阅里还没有内容",
                message: "在「我的 → 订阅标签」里加几个标签，符合的画廊会出现在这里"
            ))
        case .search, .tag:
            EhStateView(
                kind: .empty(
                    symbol: "magnifyingglass",
                    title: "没有符合条件的画廊",
                    message: "换个关键词，或放宽高级搜索里的筛选条件"
                ),
                primaryAction: advancedSearch.isEnabled
                    ? ("清除筛选条件", {
                        advancedSearch = AdvancedSearchState()
                        viewModel.searchWithAdvanced(advancedSearch)
                    })
                    : nil
            )
        default:
            EhStateView(
                kind: .empty(
                    symbol: "tray",
                    title: "这里暂时没有内容",
                    message: "下拉可以重新加载"
                ),
                // effectiveMode 而不是 mode：有搜索词时用 mode 会悄悄把搜索丢掉，
                // 按钮写着「重新加载」，实际做的是「退回首页列表」。
                // 隔壁 errorView 的「重试」一直是对的，这里漏了。
                primaryAction: ("重新加载", { viewModel.refresh(mode: effectiveMode) })
            )
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: isIPBanned ? "hand.raised.slash" : "wifi.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isIPBanned ? EhColor.warning : EhColor.danger)
            Text(viewModel.errorMessage ?? "加载失败")
                .font(EhFont.caption)
                .foregroundStyle(EhColor.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // IP 封禁 —— 换节点是唯一有效动作，单独给一组提示
            if isIPBanned {
                VStack(alignment: .leading, spacing: 6) {
                    Label("这是 E-Hentai 的限制，与 App 无关", systemImage: "info.circle")
                    Label("换一个 VPN 节点通常立即恢复", systemImage: "arrow.triangle.2.circlepath")
                    Label("同一节点被多人共用时最容易触发", systemImage: "person.2")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            }

            // 网络提示
            if let msg = viewModel.errorMessage, !isIPBanned,
               msg.contains("超时") || msg.contains("timed out") || msg.contains("连接") || msg.contains("域名") || msg.contains("DNS") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("请确认 VPN / 代理已开启", systemImage: "lock.shield")
                    Label("可在设置中尝试开启域名前置", systemImage: "server.rack")
                    Label("检查 DNS 是否被污染", systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            }

            Button("重试") {
                viewModel.loadGalleries(mode: effectiveMode)
            }
            .buttonStyle(.bordered)
        }
    }
}

#if os(iOS)
// iOS already has secondarySystemBackground
#else
extension NSColor {
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}
#endif

#Preview {
    GalleryListView(mode: .home)
}
