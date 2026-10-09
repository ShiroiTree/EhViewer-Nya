//
//  MainTabView.swift
//  ehviewer nya
//
//  主导航: TabView (iOS) / 三栏 NavigationSplitView (macOS)
//

import SwiftUI
import EhModels
import EhSettings

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = Tab.fromLaunchPage(AppSettings.shared.launchPage)
    /// 剪贴板打开画廊 (iOS sheet 展示)
    @State private var clipboardGallery: GalleryInfo?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    @State private var selectedGallery: GalleryInfo?
    /// 标签导航路径 — 支持从 Detail 列点击标签推入新画廊列表到 Content 列
    @State private var contentPath = NavigationPath()
    /// 侧栏可见性。阅读器打开时收成 detailOnly（阅读器不显示工具栏，否则没法手动收展）。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private static let detailTransitionAnimation = Animation.easeInOut(duration: 0.26)

    /// 画廊选中统一走这里：macOS 的 `List(selection:)` 由 AppKit 提交，落在 SwiftUI
    /// 事务之外，直接改 `selectedGallery` 不会触发过渡；在 setter 里包一层 withAnimation。
    private var selection: Binding<GalleryInfo?> {
        Binding(
            get: { selectedGallery },
            set: { newValue in
                withAnimation(Self.detailTransitionAnimation) { selectedGallery = newValue }
            }
        )
    }

    private func closeDetail() {
        withAnimation(Self.detailTransitionAnimation) { selectedGallery = nil }
    }
    #endif

    enum Tab: String, CaseIterable {
        case home = "首页"
        case subscription = "订阅"
        case popular = "热门"
        case toplist = "排行榜"
        case favorites = "收藏"
        case downloads = "下载"
        case history = "历史"
        case settings = "设置"
        case more = "更多"
        case profile = "我的"

        var icon: String {
            switch self {
            case .home: return "house"
            case .subscription: return "bell"
            case .popular: return "flame"
            case .toplist: return "chart.bar"
            case .favorites: return "heart"
            case .downloads: return "arrow.down.circle"
            case .history: return "clock"
            case .settings: return "gear"
            case .more: return "ellipsis.circle"
            case .profile: return "person.crop.circle"
            }
        }

        /// 固定的底部默认标签页。
        /// 「热门」「排行」已提到首页顶部的横向切页，不再占用底部位置；
        /// 「设置」并入「我的」，底部因此空出一格给「历史」。
        private static let defaultBottomTabs: [Tab] = [.home, .favorites, .downloads, .history, .profile]

        /// iPhone 底部标签固定为这五项。
        ///
        /// 此前会按「启动页面」设置把首页替换成热门/排行，但那两者现在是首页顶部的
        /// 横向切页而非独立标签页；继续替换会让底部栏在不同设置下项数与顺序都不同，
        /// 而底部栏是肌肉记忆最强的控件，不该随设置变形。
        /// 启动页指向热门/排行时改为落到首页并选中对应切页，见 initialBrowseSource。
        static var bottomTabs: [Tab] { defaultBottomTabs }

        /// "更多"菜单中的标签页 — 不在底部栏且非 .more 的标签
        static var moreTabs: [Tab] {
            let bottom = Set(bottomTabs)
            return allCases.filter { $0 != .more && $0 != .profile && !bottom.contains($0) }
        }

        /// 浮起导航条的图标（选中态用实心变体）
        var filledIcon: String {
            switch self {
            case .home: return "house.fill"
            case .favorites: return "heart.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .history: return "clock.fill"
            case .profile: return "person.crop.circle.fill"
            default: return icon
            }
        }

        /// 启动页面设置映射
        /// 启动页面设置 → 底部标签。
        ///
        /// ⚠️ 返回值必须落在 `bottomTabs` 里。
        ///
        /// 这里原本给「热门」「排行」返回 .popular / .toplist，但那两者早就不是
        /// 独立标签页了，已经并进首页顶部的切页（见 initialBrowseSource，它才是
        /// 处理这两项的地方）。而底部内容是
        /// `ForEach(bottomTabs) { .opacity(selectedTab == tab ? 1 : 0) }`——
        /// selectedTab 落在 bottomTabs 之外时没有任何图层匹配，
        /// 全部 opacity 0：整屏黑，只剩浮起导航条。
        /// 把「启动页面」设成热门或排行的用户，每次冷启动都是这个画面。
        static func fromLaunchPage(_ page: Int) -> Tab {
            let tab: Tab
            switch page {
            // 热门 / 排行 → 首页，具体切页由 initialBrowseSource 决定
            case 1, 2: tab = .home
            case 3: tab = .favorites
            case 4: tab = .downloads
            case 5: tab = .history
            default: tab = .home
            }
            // 兜底：万一以后又有人往这里加一个不在底部栏的标签，
            // 也只是回到首页，而不是黑屏
            return bottomTabs.contains(tab) ? tab : .home
        }
    }

    var body: some View {
        let _ = NSLog("[RENDER] MainTabView body")
        #if DEBUG
        let _ = Self._printChanges()  // ★ 诊断: 精确显示哪个属性触发了 body 重新求值
        #endif
        #if os(macOS)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 「我的」不占侧栏。它的内容（账号资料、图片配额）已并入设置页的
            // 「账号」分类——侧栏本来就是平铺全部入口，再单开一格只有一个
            // 二级页的入口，反而多一层。（iOS 的底部栏仍保留「我的」。）
            List(Tab.allCases.filter { $0 != .more && $0 != .profile },
                 id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationTitle("EhViewer")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            macDetail
        }
        .onChange(of: selectedTab) { _, newTab in
            closeDetail()
            contentPath = NavigationPath()
        }
        .onAppear {
            // 启动时确保左侧边栏展开：macOS 的窗口状态恢复可能把上次收起的
            // 侧栏带回来，首次出现时强制展开。
            columnVisibility = .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerVisibilityChanged)) { note in
            let reading = (note.userInfo?["reading"] as? Bool) ?? false
            columnVisibility = reading ? .detailOnly : .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selectedTab = .home
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPopular)) { _ in
            selectedTab = .popular
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTopList)) { _ in
            selectedTab = .toplist
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFavorites)) { _ in
            selectedTab = .favorites
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64,
                  let token = userInfo["token"] as? String else { return }
            let gallery = GalleryInfo(gid: gid, token: token)
            selection.wrappedValue = gallery
        }
        #else
        // iOS: iPad regular → 侧边栏 NavigationSplitView, iPhone → 底部 TabView
        Group {
            if horizontalSizeClass == .regular {
                // iPad 横屏 / 外接键盘: 侧边栏导航
                NavigationSplitView {
                    List {
                        ForEach(Tab.allCases.filter { $0 != .more }, id: \.self) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                HStack {
                                    Label(tab.rawValue, systemImage: tab.icon)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.15) : nil)
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("EhViewer")
                } detail: {
                    tabContent(selectedTab)
                        .id(selectedTab)
                }
            } else {
                // iPhone / iPad 竖屏: 浮起玻璃导航条
                //
                // 不再用系统 TabView：设计需要一条离开屏幕边缘、带圆角与模糊的浮条，
                // 而 TabBar 的外观定制到不了这个程度。代价是要自己补回系统行为，
                // 见 EhFloatingTabBar 的说明（安全区避让、重复点击回顶、无障碍）。
                ZStack {
                    ForEach(Tab.bottomTabs, id: \.self) { tab in
                        tabContent(tab)
                            // 保留全部页面的视图状态：切走的页面只是隐藏，
                            // 不销毁，回来时滚动位置与已加载数据都还在
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            .accessibilityHidden(selectedTab != tab)
                    }
                }
                .ehFloatingTabBar(
                    items: Tab.bottomTabs.map {
                        .init(value: $0, title: $0.rawValue, symbol: $0.icon, selectedSymbol: $0.filledIcon)
                    },
                    selection: $selectedTab,
                    onReselect: { tab in
                        NotificationCenter.default.post(
                            name: .ehScrollToTop, object: nil, userInfo: ["tab": tab.rawValue]
                        )
                    }
                )
            }
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64,
                  let token = userInfo["token"] as? String else { return }
            clipboardGallery = GalleryInfo(gid: gid, token: token)
        }
        .sheet(item: $clipboardGallery) { gallery in
            NavigationStack {
                GalleryDetailView(gallery: gallery)
                    .id(gallery.gid)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { clipboardGallery = nil }
                        }
                    }
                    .ehGalleryDestinations(.pushed)
            }
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            // iPad 旋转切换时确保选中标签有效
            if newSizeClass == .compact {
                if !Tab.bottomTabs.contains(selectedTab) {
                    selectedTab = .more
                }
            }
        }
        #endif
    }

    #if os(macOS)
    /// 列表栏：当前标签页的内容（画廊列表 / 设置 / 下载 …），并承载标签与查询的推入导航。
    ///
    /// `.id(selectedTab)` 让换标签时这一栏整体重建——
    /// 与改动前 content 栏的行为一致，列表不会残留上一个标签的滚动位置。
    private var galleryListColumn: some View {
        NavigationStack(path: $contentPath) {
            macOSContentView(for: selectedTab)
                // 历史页的列表用它推入画廊详情；标签/上传者推入的列表嵌入本栈，
                // 行驱动右侧详情。画廊列表页走的是选中绑定，不产生取值式跳转。
                .ehGalleryDestinations(.embedded(selection))
        }
        .id(selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 详情栏：只在有选中画廊时由主体容器加入，所以不存在空占位状态。
    ///
    /// 紧凑模式（窄窗）详情覆盖在列表之上，点标签/上传者要先撤回详情再推列表，
    /// 否则会被详情盖住；宽屏模式详情并排常驻，直接推入列表栈即可。
    private func galleryDetailColumn(_ gallery: GalleryInfo, isCompact: Bool) -> some View {
        NavigationStack {
            GalleryDetailView(gallery: gallery)
                .id(gallery.gid)
                .background(.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 详情列点标签/上传者 → 推入列表列栈（详情列与列表列是两个独立栈）。
        // 窄窗下先撤回详情，否则详情会盖住刚推入的列表。
        .environment(\.galleryNavigationAction, GalleryNavigationAction { route in
            if isCompact { closeDetail() }
            contentPath.append(route)
        })
    }

    /// macOS 主体栏：够宽时列表与详情并排；窄时回退单栏（列表或详情二选一）。
    ///
    /// 不用 NavigationSplitView 常驻第三栏：三栏布局在没选中时也会把第三栏画出来
    /// （「选择画廊」占位），切到设置、下载这些与画廊无关的页时那一栏同样还在。
    ///
    /// 宽度在 detail 列内部量：`proxy.size` 就是该列被分配到的宽度（窗口 − 侧栏），
    /// 与子视图内容无关，不会形成「内容撑大 → 量到更大」的反馈。测得后显式算出的宽度
    /// 总和恰等于可用宽度，详情不会溢出，侧栏也不会被挤扁。
    @ViewBuilder
    private var macDetail: some View {
        GeometryReader { outer in
            GeometryReader { geo in
                let width = geo.size.width
                let isCompact = width < MacDetailLayout.twoColumnMin
                let listWidth = min(
                    max(MacDetailLayout.listMin, width * 0.42),
                    MacDetailLayout.listMax
                )
                let detailWidth = max(MacDetailLayout.detailMin, width - listWidth)

                // 只换布局算法、不换子视图树：galleryListColumn 始终是第一个子视图，
                // 跨越阈值时承载列表的 NSOutlineView 不会被 dismantle。否则 AppKit 的
                // viewDidEndLiveResize 会在 SwiftUI 拆解 AttributeGraph 途中同步重入并 abort。
                let layout: AnyLayout = isCompact
                    ? AnyLayout(ZStackLayout(alignment: .topLeading))
                    : AnyLayout(HStackLayout(spacing: 0))

                layout {
                    galleryListColumn
                        .frame(width: (isCompact || selectedGallery == nil) ? width : listWidth)

                    if let gallery = selectedGallery {
                        galleryDetailColumn(gallery, isCompact: isCompact)
                            .frame(width: isCompact ? width : detailWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .zIndex(isCompact ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 内容铺到窗口工具栏下方，滚动内容才会进入工具栏背后被原生玻璃模糊。
            // 工具栏高度通过 environment 下发，供浮起的搜索胶囊让位。
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.ehToolbarTopInset, outer.safeAreaInsets.top)
        }
        .toolbar {
            if selectedGallery != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        closeDetail()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .help("关闭详情")
                }
                ToolbarSpacer()
            }
        }
    }

    @ViewBuilder
    private func macOSContentView(for tab: Tab) -> some View {
        switch tab {
        case .home:
            GalleryListView(mode: .home, selection: selection)
        case .subscription:
            GalleryListView(mode: .subscription, selection: selection)
        case .popular:
            GalleryListView(mode: .popular, selection: selection)
        case .toplist:
            GalleryListView(mode: .toplist(period: 15), selection: selection)
        case .favorites:
            FavoritesView(selection: selection)
        case .downloads:
            // 与设置页同理：标题交给窗口顶部工具栏，页内不再自建导航栈。
            DownloadsView(isPushed: true)
        case .history:
            HistoryView(isPushed: true)
        case .settings:
            // 复用列表栏已有的 NavigationStack，不让设置页再套一层。
            //
            // SettingsView() 默认会自建 NavigationStack（那层是给 iOS 用的，
            // 手机上没有外层栈）。在 macOS 这里再套一层，就会多画一条只属于
            // 内层栈的标题条——它和下面的内容对不齐。二级页本来也只要推入
            // 外层栈即可，与 MoreTabView 里的 SettingsView(isPushed: true) 同理。
            SettingsView(isPushed: true)
        case .profile:
            // macOS 侧栏不再有「我的」这一格（见侧栏的过滤），落到这里只有
            // 兜底意义：账号资料与图片配额都在设置页的「账号」分类里。
            EmptyView()
        case .more:
            // macOS 不使用 "更多" 标签，不应出现
            EmptyView()
        }
    }
    #endif

    #if os(iOS)
    /// 保留全部页面的视图状态：切走的页面只是隐藏而不销毁，
    /// 回来时滚动位置与已加载数据都还在。
    @ViewBuilder
    private func tabLayer<Content: View>(
        _ tab: Tab, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
    }

    /// 启动页面设置指向「热门 / 排行」时，落到首页并选中对应的顶部切页。
    /// 这两者已经不是独立标签页了，不能再去替换底部栏的第一项。
    private static var initialBrowseSource: BrowseSource {
        switch AppSettings.shared.launchPage {
        case 1: return .popular
        case 2: return .toplist
        default: return .home
        }
    }
    #endif

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .home:
            // 浏览容器：顶部横向切页承载首页/订阅/热门/排行
            BrowseHomeView()
        case .subscription:
            GalleryListView(mode: .subscription)
        case .popular:
            GalleryListView(mode: .popular)
        case .toplist:
            GalleryListView(mode: .toplist(period: 15))
        case .favorites:
            FavoritesView()
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .more:
            // 保留给 iPad/macOS 侧边栏的兼容路径；iPhone 底部栏已改用 .profile
            MoreTabView(onNavigate: { tab in selectedTab = tab })
        case .profile:
            ProfileHomeView()
        }
    }
}

#if os(macOS)
/// macOS 主体栏的尺寸常量：列表/详情各自的宽度下限，以及两栏 ↔ 单栏的切换阈值。
enum MacDetailLayout {
    static let listMin: CGFloat = 340
    static let listMax: CGFloat = 460
    static let detailMin: CGFloat = 360
    /// 可用内容宽度低于此值时回退单栏。
    static var twoColumnMin: CGFloat { listMin + detailMin }
}
#endif

#Preview {
    MainTabView()
        .environment(AppState())
}
