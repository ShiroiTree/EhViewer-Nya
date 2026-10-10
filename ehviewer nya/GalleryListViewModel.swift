//
//  GalleryListViewModel.swift
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

// MARK: - ViewModel

@MainActor
@Observable
class GalleryListViewModel {
    /// 列表内容。**写进来的东西会先过一遍过滤器。**
    ///
    /// 过滤放在 setter 里，而不是 didSet：`append` / 下标赋值走 `_modify`
    /// 访问器，didSet 会在那次独占访问结束前触发，此时再 `&galleries` 写回就是
    /// 嵌套写，命中 Swift 独占访问检查并崩溃（EXC_BREAKPOINT）。get/set 让原地
    /// 修改退化成「取值 → 改副本 → 写回」，过滤只在写回时做一次。
    ///
    /// 集中在这里而不是分写在各个赋值点，是为了避免新增取数路径漏掉过滤——
    /// 「漏掉」的表现是屏蔽悄悄失效，用户看不出来。
    @ObservationIgnored private var galleriesStorage: [GalleryInfo] = []
    var galleries: [GalleryInfo] {
        get {
            access(keyPath: \.galleries)
            return galleriesStorage
        }
        set {
            var value = newValue
            let hidden = GalleryFilterEngine.shared.apply(to: &value)
            withMutation(keyPath: \.galleries) {
                galleriesStorage = value
            }
            filteredOutCount = hidden
        }
    }

    /// 最近一次加载被过滤器挡掉的条数，用来在列表底部说明「少了几本」
    var filteredOutCount = 0
    var isLoading = false
    var errorMessage: String?
    /// 当前查询。**唯一真相源** —— URL 构建、历史、缓存 key 都从这里派生。
    var searchQuery: SearchQuery = .empty
    /// 渲染成 `f_search` 的字符串。仅供只读用途（历史、标题、快速搜索抽屉回显）。
    var searchText: String { searchQuery.render() }
    var hasMore = false
    var totalPages = 0 // 总页数 (对齐 Android mHelper.mPages)
    var showGoToDialog = false // 跳页对话框 (页码模式，仅 TopList 使用)
    var goToPageInput: String = "" // 跳页输入
    var showJumpDialog = false // 跳页对话框 (日期模式，对齐 Android GoToDialog)
    var jumpDate = Date() // 跳页日期

    /// 收藏夹分页导航链接 (searchnav 模式: prev/next)
    var prevHref: String?
    var nextHref: String?
    /// 是否为收藏模式 (使用 seek 跳页而非整数页码)
    var isFavoritesMode: Bool {
        if case .favorites = currentMode { return true }
        return false
    }

    /// 收藏夹搜索关键字 (由 FavoritesView 传入)
    var favSearchKeyword: String?

    // MARK: - 搜索历史 (对齐 Android SearchBar 搜索历史)
    var searchHistory: [String] = []

    private static let searchHistoryKey = "ehSearchHistory"
    private static let maxHistoryCount = 50

    func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
    }

    func addSearchToHistory(_ rawText: String) {
        let text = ListUrlBuilder.sanitizeKeyword(rawText)
        guard !text.isEmpty else { return }
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > Self.maxHistoryCount {
            history = Array(history.prefix(Self.maxHistoryCount))
        }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func removeSearchHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: Self.searchHistoryKey)
        searchHistory = []
    }

    // MARK: - 搜索建议 (对齐 Android SearchBar.updateSuggestions)
    struct TagSuggestionItem: Identifiable {
        let chinese: String
        let english: String
        var id: String { english }
    }
    var suggestions: [TagSuggestionItem] = []
    private var suggestionTask: Task<Void, Never>?

    /// 更新搜索建议 (对齐 Android SearchBar.updateSuggestions)
    /// 按输入框里正在打的文字更新建议。
    ///
    /// 参数取自输入框而非 `searchText`：后者保存的是「已提交的完整查询」，
    /// 包含已经变成 token 的标签，拿它算建议会一直命中已选过的标签。
    func updateSuggestions(for text: String) {
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor in
            // 防抖 200ms
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            guard let extracted = EhTagDatabase.extractLastKeyword(from: text) else {
                suggestions = []
                return
            }
            let results = EhTagDatabase.shared.suggest(extracted.keyword)
            if !Task.isCancelled {
                suggestions = results.map { TagSuggestionItem(chinese: $0.chinese, english: $0.english) }
            }
        }
    }

    private var currentPage = 0
    private var currentCacheKey: String?
    private var currentMode: GalleryListView.ListMode?
    /// 高级搜索参数 (对齐 Android AdvanceSearchTable 状态持久化)
    private var currentAdvanceSearch: Int = -1
    private var currentMinRating: Int = -1
    private var currentPageFrom: Int = -1
    private var currentPageTo: Int = -1
    private var currentCategory: Int = 0
    private var currentSearchMode: SearchMode = .normal

    /// 云收藏夹拉取成功时记下时刻，供收藏页显示「云端同步 · N 分钟前」。
    ///
    /// 只记 slot >= 0 的云收藏夹：本地收藏与「全部」不经网络同步，
    /// 给它们盖一个同步时间是误导。
    func recordFavoriteSyncIfNeeded(mode: GalleryListView.ListMode) {
        guard case .favorites(let slot) = mode, slot >= 0 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "fav_last_sync")
    }

    func loadGalleries(mode: GalleryListView.ListMode) {
        guard !isLoading else {
            print("[EhVM] loadGalleries: SKIPPED (already loading)")
            return
        }
        print("[EhVM] loadGalleries: START mode=\(mode)")

        currentMode = mode

        // ★ 换模式/换筛选条件时必须丢弃上一次的分页游标，
        //   否则"加载更多"会用别的列表的 nextHref 继续翻页 (issue #8 问题一)
        prevHref = nil
        nextHref = nil
        currentPage = 0

        // 先查缓存 (空结果不视为有效缓存 — 可能是之前网络失败)
        let cacheKey = self.cacheKey(for: mode, page: 0)
        if let cached = GalleryCache.shared.getListResult(forKey: cacheKey),
           !cached.galleries.isEmpty {
            print("[EhVM] loadGalleries: CACHE HIT \(cached.galleries.count) galleries")
            galleries = cached.galleries
            hasMore = cached.hasMore
            totalPages = cached.totalPages ?? 0
            // 游标随缓存一起恢复，保证继续翻页接的是这一页的下一页
            prevHref = cached.prevHref
            nextHref = cached.nextHref
            currentCacheKey = cacheKey
            return
        }

        isLoading = true
        errorMessage = nil
        currentCacheKey = cacheKey

        Task {
            // 超时保护: 如果网络请求超过 20 秒仍未完成，显示错误让用户可以重试
            let fetchTask = Task {
                await fetchPage(mode: mode, page: 0)
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(20))
                // 仅在仍处于加载状态且画廊为空时触发超时
                if self.isLoading && self.galleries.isEmpty {
                    fetchTask.cancel()
                    self.isLoading = false
                    self.errorMessage = "网络请求超时，请检查网络连接或 VPN 设置后重试"
                    print("[EhVM] loadGalleries: TIMEOUT after 20s")
                }
            }
            await fetchTask.value
            timeoutTask.cancel()
        }
    }

    func refresh(mode: GalleryListView.ListMode) {
        // 刷新时清除当前 mode 的缓存
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries — loadGalleries/fetchPage 成功后会替换
        // 避免列表被清空后触发 ProgressView，导致 .refreshable 任务被 SwiftUI 取消
        isLoading = false  // 重置状态，确保 loadGalleries 不会被 guard 拦截
        loadGalleries(mode: mode)
    }

    /// 异步刷新 — 用于 .refreshable ，等待网络请求完成后才结束下拉动画
    func refreshAsync(mode: GalleryListView.ListMode) async {
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries、不设置 isLoading = true
        // — 保持旧数据可见，防止 SwiftUI 将 galleryList 替换为 ProgressView
        //   从而取消 .refreshable 的结构化并发任务
        currentMode = mode
        errorMessage = nil
        currentPage = 0
        prevHref = nil
        nextHref = nil
        let cacheKey = self.cacheKey(for: mode, page: 0)
        currentCacheKey = cacheKey
        await fetchPage(mode: mode, page: 0)
    }

    /// 带高级搜索参数的搜索 (对齐 Android AdvanceSearchTable → ListUrlBuilder)
    /// 用给定的查询搜索。
    ///
    /// token 与自由文本在提交时才合并成一个 `SearchQuery` 传进来，
    /// `searchQuery` 保存的就是它——视图的输入框状态与它一一对应。
    func performSearch(query: SearchQuery, advanced: AdvancedSearchState) {
        searchQuery = query
        searchWithAdvanced(advanced)
    }

    func searchWithAdvanced(_ state: AdvancedSearchState) {
        // 粘贴进来的搜索词常带 \r\n，会把 `artist:foo` 之类的语法拆断
        // (对齐上游 2026-03-02 / 03-14「搜索时过滤文本中的换行符」)
        let rendered = ListUrlBuilder.sanitizeKeyword(searchQuery.render())
        if !rendered.isEmpty { addSearchToHistory(rendered) }
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode

        // 没有关键字时，按分类过滤首页 (对齐 Android: 无关键字也能按分类搜索)
        if rendered.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            prevHref = nil
            nextHref = nil
            Task {
                await fetchPage(mode: .home, page: 0)
            }
            return
        }

        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        prevHref = nil
        nextHref = nil
        Task {
            await fetchPage(mode: .search(searchQuery), page: 0)
        }
    }

    /// 高级搜索面板关闭后自动应用设置 (对齐 Android GalleryListScene.onApplySearch)
    func applyAdvancedSettings(_ state: AdvancedSearchState, initialMode: GalleryListView.ListMode) {
        syncAdvancedSettings(state)

        // 清除缓存，强制使用新参数重新加载
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }

        // 有活跃搜索关键字时，重新执行搜索
        if !searchQuery.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            prevHref = nil
            nextHref = nil
            Task {
                await fetchPage(mode: .search(searchQuery), page: 0)
            }
            return
        }

        // 首页模式: 用分类重新加载
        if case .home = initialMode {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            prevHref = nil
            nextHref = nil
            Task {
                await fetchPage(mode: .home, page: 0)
            }
        }
    }

    /// 静默同步高级搜索参数到 ViewModel (不触发搜索)
    func syncAdvancedSettings(_ state: AdvancedSearchState) {
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
    }

    func applyQuickSearch(_ search: QuickSearchRecord) {
        guard let keyword = search.keyword, !keyword.isEmpty else { return }
        searchQuery = SearchQuery.parse(keyword)
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        prevHref = nil
        nextHref = nil

        // 构建带有分类和评分过滤的搜索
        Task {
            await fetchQuickSearch(search)
        }
    }

    private func fetchQuickSearch(_ search: QuickSearchRecord) async {
        do {
            let site = AppSettings.shared.gallerySite
            let host = EhURL.host(for: site)

            var urlComponents = URLComponents(string: host)!
            var queryItems: [URLQueryItem] = []

            // 关键词
            if let keyword = search.keyword {
                queryItems.append(URLQueryItem(name: "f_search", value: keyword))
            }

            // 分类过滤 (E-Hentai 使用 f_cats 参数，是要排除的分类的位掩码)
            if search.category > 0 {
                // category 是要包含的分类，需要计算排除的分类
                let allCategories = 0x3FF  // 全部分类
                let excludeCategories = allCategories ^ search.category
                queryItems.append(URLQueryItem(name: "f_cats", value: String(excludeCategories)))
            }

            // 最低评分
            if search.minRating > 0 {
                queryItems.append(URLQueryItem(name: "f_srdd", value: String(search.minRating)))
                queryItems.append(URLQueryItem(name: "f_sr", value: "on"))
            }

            // 高级搜索标记
            if search.advanceSearch > 0 || search.minRating > 0 {
                queryItems.append(URLQueryItem(name: "advsearch", value: "1"))
            }

            urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

            let result = try await EhAPI.shared.getGalleryList(url: urlComponents.url!.absoluteString)

            self.galleries = result.galleries
            // ★ 记录分页游标: 快速搜索的 URL 是这里现拼的，
            //   不记下来 loadMore 会退回 page=N 分页并按 mode 重新拼 URL → 加载到别的列表
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            self.totalPages = result.pages
            // ★ 防止分页回绕: nextPage 必须 > 0 才有下一页 (E-Hentai 末页 ptt ">" 链接回 page=0)
            if result.pages < 0 {
                self.hasMore = result.nextHref != nil
            } else {
                self.hasMore = (result.nextPage ?? 0) > 0
                if !self.hasMore { self.nextHref = nil }
            }
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    func loadMore(mode: GalleryListView.ListMode) async {
        guard !isLoading, hasMore else { return }

        // ★ 始终优先使用 nextHref 翻页
        // ptt 和 searchnav 模式都会提供完整 href (包含 next=TIMESTAMP 等跳页上下文)
        // 这确保日期跳转后能按日期顺序加载，不会因丢失上下文而循环
        if let nextHref = nextHref {
            isLoading = true
            do {
                let result = try await EhAPI.shared.getGalleryList(url: nextHref)

                // ★ 去重保护: 如果新加载的画廊全部已在列表中，说明分页回绕了
                let existingGids = Set(self.galleries.map { $0.gid })
                let newGalleries = result.galleries.filter { !existingGids.contains($0.gid) }
                if result.galleries.count > 0 && newGalleries.isEmpty {
                    // 全重复 → 到达尽头，停止加载
                    self.hasMore = false
                    self.isLoading = false
                    return
                }

                self.galleries.append(contentsOf: newGalleries)
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                if result.pages < 0 {
                    // searchnav 模式: 有 #unext 才继续
                    self.hasMore = result.nextHref != nil
                } else {
                    // ptt 模式: 末页的 ">" 会回绕到 page=0，nextHref 同样要丢弃
                    self.hasMore = (result.nextPage ?? 0) > 0
                    if !self.hasMore { self.nextHref = nil }
                }
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
            return
        }

        // Page-based 翻页 fallback (仅在无 href 时使用)
        isLoading = true
        currentPage += 1
        await fetchPage(mode: mode, page: currentPage)
    }
    
    /// 跳转到指定页 (对齐 Android ContentHelper.goTo(page), 仅 TopList 使用)
    func goToPage(_ page: Int, mode: GalleryListView.ListMode) {
        guard page >= 0 && page < totalPages else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = page
        currentMode = mode
        
        Task {
            await fetchPage(mode: mode, page: page)
        }
    }

    /// 通用日期跳转 (对齐 Android GoToDialog: 所有模式统一使用日期选择器)
    func goToDate(_ date: Date, mode: GalleryListView.ListMode) {
        if case .favorites = mode {
            // 收藏模式: ?seek=YYYY-MM-DD
            goToFavoritesDate(date, mode: mode)
        } else {
            // 普通模式: ?next=UNIX_TIMESTAMP (对齐 Android: 日期转时间戳跳转)
            goToNormalDate(date, mode: mode)
        }
    }

    /// 普通画廊按日期跳转 (对齐 Android GoToDialog 普通模式: ?next=TIMESTAMP)
    private func goToNormalDate(_ date: Date, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        prevHref = nil
        nextHref = nil
        currentMode = mode
        
        Task {
            await fetchNormalSeek(date: date, mode: mode)
        }
    }

    /// 收藏跳转到指定日期 (对齐 Android FavoritesScene: ?seek=YYYY-MM-DD)
    func goToFavoritesDate(_ date: Date, mode: GalleryListView.ListMode) {
        guard case .favorites(let slot) = mode else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        prevHref = nil
        nextHref = nil
        currentMode = mode
        
        Task {
            await fetchFavoritesSeek(slot: slot, date: date)
        }
    }

    /// 收藏通过 URL 导航 (prev/next 链接)
    func goToFavoritesHref(_ href: String, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode
        
        Task {
            do {
                let result = try await EhAPI.shared.getGalleryList(url: href)
                self.galleries = result.galleries
                recordFavoriteSyncIfNeeded(mode: mode)
                self.hasMore = result.nextHref != nil
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 快捷跳转 (对齐 Android jumpHrefBuild + onTimeSelected)
    /// appendParam 为 "jump=1d" / "seek=2024-01-15" 之类的 URL 追加参数
    func goToJump(_ appendParam: String, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode

        Task {
            let jumpUrl = buildJumpUrl(appendParam, mode: mode)
            do {
                let result = try await EhAPI.shared.getGalleryList(url: jumpUrl)
                self.galleries = result.galleries
                recordFavoriteSyncIfNeeded(mode: mode)
                // ★ 防止回绕: nextHref 优先, 否则 nextPage 须 > 0
                if result.nextHref != nil {
                    self.hasMore = true
                } else {
                    self.hasMore = (result.nextPage ?? 0) > 0
                }
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 构建跳转 URL (对齐 Android ListUrlBuilder.jumpHrefBuild)
    /// 如果有 nextHref，修改它；否则从当前模式构建基础 URL
    private func buildJumpUrl(_ appendParam: String, mode: GalleryListView.ListMode) -> String {
        var baseUrl: String

        if let href = nextHref, !href.isEmpty {
            baseUrl = href
        } else {
            let site = AppSettings.shared.gallerySite
            switch mode {
            case .home, .subscription:
                var builder = ListUrlBuilder()
                builder.mode = mode.isSubscription
                    ? .subscription
                    : (ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal)
                builder.category = currentCategory
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                baseUrl = builder.build(site: site)
            case .search(let query):
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = query.render()
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
            case .favorites(let slot):
                if slot < 0 {
                    baseUrl = EhURL.favoritesUrl(for: site)
                } else {
                    baseUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)"
                }
            case .popular:
                baseUrl = EhURL.popularUrl(for: site)
            case .toplist(let period):
                // toplist.php 返回的就是标准的紧凑画廊列表表格 (itg gltc)，
                // 通用解析器能直接吃（TopListParsingTests 用真实排版守着），
                // 所以排行榜可以和其它列表走同一条路，卡片样式自然一致。
                baseUrl = "\(EhURL.host(for: site))toplist.php?tl=\(period)"
            }
        }

        // 移除已有的 seek/jump 参数 (对齐 Android jumpHrefBuild 正则替换逻辑)
        baseUrl = baseUrl.replacingOccurrences(
            of: "seek=\\d+-\\d+-\\d+",
            with: "",
            options: .regularExpression
        )
        baseUrl = baseUrl.replacingOccurrences(
            of: "jump=\\d[ymwd]",
            with: "",
            options: .regularExpression
        )
        // 清除残留分隔符
        baseUrl = baseUrl.replacingOccurrences(of: "&&", with: "&")
        baseUrl = baseUrl.replacingOccurrences(of: "?&", with: "?")
        while baseUrl.hasSuffix("?") || baseUrl.hasSuffix("&") {
            baseUrl.removeLast()
        }

        // 追加新参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        return "\(baseUrl)\(separator)\(appendParam)"
    }

    /// 普通画廊按日期跳转 (对齐 Android: ?next=UNIX_TIMESTAMP)
    private func fetchNormalSeek(date: Date, mode: GalleryListView.ListMode) async {
        let site = AppSettings.shared.gallerySite
        let timestamp = Int(date.timeIntervalSince1970)

        // 基于当前模式构建 URL，附加 &next=TIMESTAMP
        var baseUrl: String
        switch mode {
        case .home:
            var builder = ListUrlBuilder()
            builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
            builder.category = currentCategory
            builder.advanceSearch = currentAdvanceSearch
            builder.minRating = currentMinRating
            builder.pageFrom = currentPageFrom
            builder.pageTo = currentPageTo
            baseUrl = builder.build(site: site)
        case .search(let query):
            var builder = ListUrlBuilder()
            builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
            builder.keyword = query.render()
            builder.advanceSearch = currentAdvanceSearch
            builder.minRating = currentMinRating
            builder.pageFrom = currentPageFrom
            builder.pageTo = currentPageTo
            builder.category = currentCategory
            baseUrl = builder.build(site: site)
        case .tag(let keyword):
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
        default:
            // popular 等模式不支持日期跳转
            return
        }

        // 附加 next=TIMESTAMP 参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        let seekUrl = "\(baseUrl)\(separator)next=\(timestamp)"

        do {
            let result = try await EhAPI.shared.getGalleryList(url: seekUrl)
            self.galleries = result.galleries
            recordFavoriteSyncIfNeeded(mode: mode)
            // ★ 防止回绕: nextHref 优先, 否则 nextPage 须 > 0
            if result.nextHref != nil {
                self.hasMore = true
            } else {
                self.hasMore = (result.nextPage ?? 0) > 0
            }
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            self.totalPages = result.pages
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    /// 按日期跳转收藏 (对齐 Android: ?seek=YYYY-MM-DD)
    private func fetchFavoritesSeek(slot: Int, date: Date) async {
        let site = AppSettings.shared.gallerySite
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        
        var favUrl: String
        if slot < 0 {
            favUrl = "\(EhURL.favoritesUrl(for: site))?seek=\(dateStr)"
        } else {
            favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&seek=\(dateStr)"
        }
        
        if let keyword = favSearchKeyword, !keyword.isEmpty {
            favUrl += "&f_search=\(SearchQueryEncoder.encodeValue(keyword))"
        }

        do {
            let result = try await EhAPI.shared.getGalleryList(url: favUrl)
            self.galleries = result.galleries
            self.hasMore = result.nextHref != nil
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            self.totalPages = result.pages
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    private func fetchPage(mode: GalleryListView.ListMode, page: Int) async {
        // 占位符模式：不发网络请求，用合成的画廊行填充**网络列表**
        // （首页/热门/排行/搜索/标签/订阅），让断网时也能完整浏览、截图、跑 UI 测试。
        // 收藏列表走本地数据，不在此替换。
        let isFavorites: Bool = {
            if case .favorites = mode { return true }
            return false
        }()
        if PlaceholderMode.isEnabled, !isFavorites {
            galleries = PlaceholderMode.syntheticGalleries(
                seedBase: String(describing: mode), startIndex: page * 24
            )
            prevHref = nil
            nextHref = nil
            totalPages = 1
            hasMore = false
            currentPage = page
            isLoading = false
            errorMessage = nil
            return
        }

        print("[EhVM] fetchPage: mode=\(mode) page=\(page)")
        do {
            let site = AppSettings.shared.gallerySite
            let host = EhURL.host(for: site)
            let urlString: String

            switch mode {
            case .subscription:
                // 订阅列表: /watched，只出带订阅标签的新画廊
                var builder = ListUrlBuilder()
                builder.mode = .subscription
                builder.pageIndex = page
                builder.category = currentCategory
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                urlString = builder.build(site: site)
            case .home:
                // ★ 首页同样要带上高级搜索参数 (对齐 Android GalleryListScene:
                //   无关键字时也用同一个 ListUrlBuilder，f_sr/f_srdd 等不会被丢弃)
                //   之前这里只传 category，导致"最低评分 / 页数范围 / 订阅搜索"在无关键字时全部失效
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.pageIndex = page
                builder.category = currentCategory
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                urlString = builder.build(site: site)
            case .popular:
                urlString = EhURL.popularUrl(for: site)
            case .toplist(let period):
                // 排行榜按 p= 分页，和普通列表一致
                urlString = page > 0
                    ? "\(host)toplist.php?tl=\(period)&p=\(page)"
                    : "\(host)toplist.php?tl=\(period)"
            case .search(let query):
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = query.render()
                builder.pageIndex = page
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                if page > 0 {
                    urlString = "\(host)tag/\(encoded)/\(page)"
                } else {
                    urlString = "\(host)tag/\(encoded)"
                }
            case .favorites(let slot):
                // slot -1 = 全部收藏, 0-9 = 指定收藏夹 (对齐 Android FavoritesScene)
                var favUrl: String
                if slot < 0 {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?page=\(page)"
                } else {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&page=\(page)"
                }
                // 收藏搜索 (对齐 Android FavoritesScene.onGetFavoritesSuccess)
                if let keyword = favSearchKeyword, !keyword.isEmpty {
                    favUrl += "&f_search=\(SearchQueryEncoder.encodeValue(keyword))"
                }
                urlString = favUrl
            }

            let result = try await EhAPI.shared.getGalleryList(url: urlString)

            if page == 0 {
                self.galleries = result.galleries
                recordFavoriteSyncIfNeeded(mode: mode)
            } else {
                self.galleries.append(contentsOf: result.galleries)
            }
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            // 解析总页数 (对齐 Android: GalleryListParser 返回的 pages)
            self.totalPages = result.pages

            // ★ 防止分页循环: 根据模式正确判断 hasMore
            if case .popular = mode {
                // Popular 不分页
                self.hasMore = false
            } else if case .favorites = mode {
                // 收藏夹使用 href-based 翻页
                self.hasMore = result.nextHref != nil
            } else if result.pages < 0 {
                // searchnav 模式 (解析器置 pages = -1): 只能靠 #unext 判断
                self.hasMore = result.nextHref != nil
            } else {
                // ptt 分页: nextPage 必须 > 当前 page 才有下一页
                // E-Hentai 末页 ptt ">" 链接会回绕到 page=0，
                // 此时 nextHref 也是回绕链接，必须一并丢弃 ——
                // 否则 loadMore 会优先用它翻回第一页，表现为"列表从头循环" (issue #8 问题一)
                self.hasMore = (result.nextPage ?? 0) > page
                if !self.hasMore { self.nextHref = nil }
            }
            
            self.isLoading = false
            print("[EhVM] fetchPage: SUCCESS — \(self.galleries.count) galleries loaded")

            // 缓存第一页结果
            if page == 0 {
                let cacheKey = self.cacheKey(for: mode, page: 0)
                GalleryCache.shared.putListResult(
                    CachedGalleryListResult(
                        galleries: self.galleries,
                        hasMore: self.hasMore,
                        nextPage: result.nextPage,
                        totalPages: self.totalPages,
                        prevHref: result.prevHref,
                        nextHref: result.nextHref
                    ),
                    forKey: cacheKey
                )
            }

        } catch {
            self.isLoading = false  // 始终重置，包括取消
            print("[EhVM] fetchPage: ERROR \(error)")
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                print("[EhVM] fetchPage: cancelled, no errorMessage set")
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
        }
    }

    /// 当前生效的筛选条件签名 — 参与缓存 key，
    /// 否则改了分类/最低评分后仍会命中旧的未过滤缓存
    private var filterSignature: String {
        "\(currentSearchMode.rawValue)|\(currentCategory)|\(currentAdvanceSearch)|\(currentMinRating)|\(currentPageFrom)-\(currentPageTo)"
    }

    /// 生成缓存 key
    private func cacheKey(for mode: GalleryListView.ListMode, page: Int) -> String {
        switch mode {
        case .home: return "home:\(filterSignature):\(page)"
        case .subscription: return "watched:\(filterSignature):\(page)"
        case .popular: return "popular:\(page)"
        case .toplist(let period): return "toplist:\(period):\(page)"
        case .search(let query): return "search:\(query.render()):\(filterSignature):\(page)"
        case .tag(let kw): return "tag:\(kw):\(page)"
        case .favorites(let slot): return "fav:\(slot):\(favSearchKeyword ?? ""):\(page)"
        }
    }
}

