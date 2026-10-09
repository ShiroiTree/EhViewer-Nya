//
//  NavigationComponents.swift
//  ehviewer nya
//
//  全局导航规范组件:
//  1. AppBackButton — 统一返回按钮 (Chevron 圆形半透明)
//  2. EdgeSwipeBackModifier — 恢复边缘滑动返回手势
//  3. NavigationBarCompact — 强制 inline 标题栏修饰符
//

import SwiftUI
import EhModels

#if os(iOS)
import UIKit
#endif

// MARK: - 1. 统一返回按钮 (对齐 Android Toolbar NavigationIcon)

/// 全局统一返回按钮 — 所有二级及深层页面使用同一样式
///
/// 样式: Chevron 图标 + 半透明圆形背景
/// 位置: 左上角叠加 (overlay alignment: .topLeading)
///
/// 使用方式:
/// ```swift
/// .overlay(alignment: .topLeading) {
///     AppBackButton { dismiss() }
/// }
/// ```
struct AppBackButton: View {
    let action: () -> Void
    
    /// 背景风格: 当页面有深色/图片背景时使用 dark, 普通页面用 light
    var style: Style = .dark
    
    enum Style {
        case dark   // 白色图标 + 黑色半透明背景 (用于图片/深色背景上)
        case light  // 系统颜色 + 浅色材质背景 (用于普通列表页)
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style == .dark ? .white : Color.primary)
                .padding(8)
                .glassEffect(
                    style == .dark
                        ? .regular.tint(Color.black.opacity(0.5)).interactive()
                        : .regular.interactive(),
                    in: .circle
                )
        }
        .accessibilityLabel("返回")
    }
}

// MARK: - 2. 边缘滑动返回手势修复

/// 修复 SwiftUI 隐藏原生返回按钮后边缘滑动返回手势失效的问题
///
/// 原理: 在 UINavigationController 上重新启用 interactivePopGestureRecognizer
/// 并将其 delegate 替换为自定义实现，确保在任何自定义导航栏下都能滑动返回
///
/// 使用方式:
/// ```swift
/// NavigationStack {
///     content
/// }
/// .enableEdgeSwipeBack()
/// ```
#if os(iOS)
struct EdgeSwipeBackModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EdgeSwipeBackHelper())
    }
}

/// UIKit 辅助视图 — 查找最近的 UINavigationController 并启用滑动返回
private struct EdgeSwipeBackHelper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        EdgeSwipeBackViewController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private class EdgeSwipeBackViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePopGesture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enableInteractivePopGesture()
    }
    
    private func enableInteractivePopGesture() {
        guard let nav = navigationController else { return }
        // 仅在有多个视图控制器时启用 (栈顶不需要)
        guard nav.viewControllers.count > 1 else { return }
        // 如果 delegate 已被清除或是系统默认的，替换为允许手势的 delegate
        if nav.interactivePopGestureRecognizer?.isEnabled == false {
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
        // 确保手势识别器的 delegate 不会阻止手势
        if nav.interactivePopGestureRecognizer?.delegate !== nav {
            nav.interactivePopGestureRecognizer?.delegate = nav
        }
    }
}

// MARK: - UINavigationController + InteractivePopGesture

/// 让 UINavigationController 自身作为滑动返回手势的 delegate
/// 这样即使隐藏了原生返回按钮，边缘滑动返回依然有效
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 导航栈只有一个 VC 时禁止滑动 (没有上一页可返回)
        viewControllers.count > 1
    }
    
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 允许与其他手势同时识别，避免冲突
        false
    }
}
#endif

// MARK: - 3. View 扩展

extension View {
    /// 启用边缘滑动返回手势 (修复隐藏原生返回按钮后手势失效)
    @ViewBuilder
    func enableEdgeSwipeBack() -> some View {
        #if os(iOS)
        self.modifier(EdgeSwipeBackModifier())
        #else
        self
        #endif
    }
    
    /// 紧凑导航栏修饰符 — 强制 inline 标题 + 隐藏大标题空间
    @ViewBuilder
    func compactNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - 4. 画廊导航路由 (统一收口)

/// 全 App 统一的路由值。
///
/// 此前标签与上传者各是一个 Hashable 目标类型（`TagSearchDestination` /
/// `GalleryQueryDestination`），承载页得为「每一种」分别注册 `navigationDestination`。
/// 漏注册一处，那条路径上的标签/上传者就静默失效（历史页即如此）；注册重了又会
/// 触发 SwiftUI 的未定义行为。收口成单一枚举后，每个栈只注册一种类型，
/// 由 `.ehGalleryDestinations(_:)` 一次挂载。
enum AppRoute: Hashable {
    case tagList(String)
    case queryList(SearchQuery)
}

/// 画廊列表在各栈里的呈现差异 —— 这是唯一允许影响列表形态的开关。
///
/// 变体来自物理约束（独立栈 vs 分栏内容列），不是入口差异：
/// 同一个数据源在任何入口都取同一个变体。
enum GalleryListPresentation {
    /// 独立栈 / compact / 分栏侧栏：自己画搜索栏与标题。
    case pushed
    /// 嵌入分栏内容列：行驱动右侧详情，不自己建栈。
    case embedded(Binding<GalleryInfo?>)

    @ViewBuilder
    func makeList(_ mode: GalleryListView.ListMode) -> some View {
        switch self {
        case .pushed:
            GalleryListView(mode: mode, isPushed: true)
        case .embedded(let selection):
            GalleryListView(mode: mode, selection: selection)
        }
    }
}

/// 跨列导航动作 —— macOS 分栏里「详情列点标签 → 推入内容列」。
///
/// 详情列与内容列是两个独立的 NavigationStack，value-based 链接只能在同一栈内
/// 解析，跨列必须由外部注入一个动作，把路由 append 到内容列自己的 path 上。
/// 标签与上传者共用这一个动作（此前是两个各管一半）。
struct GalleryNavigationAction {
    let push: (AppRoute) -> Void
}

private struct GalleryNavigationActionKey: EnvironmentKey {
    static let defaultValue: GalleryNavigationAction? = nil
}

extension EnvironmentValues {
    var galleryNavigationAction: GalleryNavigationAction? {
        get { self[GalleryNavigationActionKey.self] }
        set { self[GalleryNavigationActionKey.self] = newValue }
    }
}

extension View {
    /// 每个承载画廊页面的 NavigationStack 根挂一次。
    ///
    /// 集中注册两类目标：
    ///   - `GalleryInfo` → 画廊详情（列表行的 `NavigationLink(value:)`）
    ///   - `AppRoute`    → 标签 / 上传者列表（详情页内发出）
    ///
    /// 类型可穷举，因此不存在「漏注册一种」或「重复注册一类」。
    func ehGalleryDestinations(_ presentation: GalleryListPresentation = .pushed) -> some View {
        self
            .navigationDestination(for: GalleryInfo.self) { gallery in
                GalleryDetailView(gallery: gallery).id(gallery.gid)
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .tagList(let tag):
                    presentation.makeList(.tag(keyword: tag))
                case .queryList(let query):
                    presentation.makeList(.search(query))
                }
            }
    }
}
