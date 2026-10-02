//
//  MacPageReaderView.swift
//  ehviewer nya
//
//  macOS 原生图片翻页核心（仅 macOS）
//  - MacSpreadLayout:      纯函数排版，单/双页的尺寸与位置计算，不碰 AppKit 视图
//  - MacCenteringClipView: 文档小于视口时居中
//  - MacSpreadScrollView:  单个缩放/滚动面（整个阅读器里唯一的缩放所有者）
//  - MacPageReaderView:    翻页器，3 个面的对象池 + 滑动动画
//
// 本文件整体包在 #if os(macOS) 内，iOS 目标不编译任何内容。
//

#if os(macOS)

import AppKit
import QuartzCore

// MARK: - 展页内容

/// 一「展」的完整内容：页码、已加载的图片、以及是否所有页都已就绪。
/// 翻页器据此决定「原地更新 / 滑动 / 停等 / 跳页」，也据此预渲染相邻展。
struct MacSpreadContent {
    let pageIndex: Int
    let images: [NSImage]
    let isReady: Bool
}

// MARK: - 展页排版（纯逻辑，不依赖 AppKit 视图）

/// 计算一「展」里若干页的文档尺寸与各自在文档中的矩形。
///
/// 算法（对齐 Android 双页排版）：
/// 1. `pages` 为空 → 返回 `.zero`；任何一页宽/高非正、或需要用到视口而视口非正时
///    都做防御处理，保证结果里不出现 NaN / Inf。
/// 2. 所有页共享一个显示高度 `baseHeight = max(page.height)`：最高的那页 1:1 渲染，
///    其余页按比例缩放到同一高度。
/// 3. 每页基准宽度 `baseWidth_i = page.width * (baseHeight / page.height)`，
///    基准总宽 `baseTotalWidth = Σ baseWidth_i`。
/// 4. 缩放倍率：`.origin`→1、`.fixed`→1、`.fitWidth`→viewport.width/baseTotalWidth、
///    `.fitHeight`→viewport.height/baseHeight、`.fit`→min(两者)。除零时回退为 1。
/// 5. `displayHeight = baseHeight * multiplier`，`displayWidth_i = baseWidth_i * multiplier`，
///    文档宽度 = Σ displayWidth_i。
/// 6. 摆放：返回的 `pageFrames` 顺序与入参 `pages` 一致（阅读顺序 = 页码小者在前）。
///    - 单页：直接放在 (0,0)，文档就是该页大小。方向不影响单页位置，
///      由 MacCenteringClipView 负责把它在视口里居中。
///    - 多页：从左到右 / 从上到下 → 下标 0 在最左，x 递增；
///      从右到左 → 反向摆放，下标 i 的 x = Σ_{j>i} displayWidth_j，
///      于是页码较大的那页落在左边。
///    - 所有 frame 的 y = 0、高 = displayHeight。
enum MacSpreadLayout {

    struct Result: Equatable {
        let documentSize: CGSize
        let pageFrames: [CGRect]
    }

    static func frames(pages: [CGSize], viewport: CGSize,
                       scaleMode: ScaleMode, direction: ReadingDirection) -> Result {
        // 1. 空输入
        guard !pages.isEmpty else {
            return Result(documentSize: .zero, pageFrames: [])
        }

        // 1b. 清理非法尺寸，避免后面除零 / NaN
        let safePages = pages.map { CGSize(width: max(0, $0.width), height: max(0, $0.height)) }
        let baseHeight = safePages.map(\.height).max() ?? 0
        guard baseHeight > 0 else {
            let zeroFrames = Array(repeating: CGRect.zero, count: pages.count)
            return Result(documentSize: .zero, pageFrames: zeroFrames)
        }

        // 2/3. 共享显示高度与各页基准宽度
        let baseWidths: [CGFloat] = safePages.map { page in
            guard page.height > 0 else { return 0 }
            return page.width * (baseHeight / page.height)
        }
        let baseTotalWidth = baseWidths.reduce(0, +)

        // 4. 倍率
        let viewportW = max(0, viewport.width)
        let viewportH = max(0, viewport.height)
        var multiplier: CGFloat
        switch scaleMode {
        case .origin, .fixed:
            multiplier = 1
        case .fitWidth:
            multiplier = baseTotalWidth > 0 ? viewportW / baseTotalWidth : 1
        case .fitHeight:
            multiplier = viewportH / baseHeight
        case .fit:
            let fitW = baseTotalWidth > 0 ? viewportW / baseTotalWidth : 1
            let fitH = viewportH / baseHeight
            multiplier = min(fitW, fitH)
        }
        if !multiplier.isFinite || multiplier <= 0 {
            multiplier = 1
        }

        // 5. 实际尺寸
        let displayHeight = baseHeight * multiplier
        let displayWidths = baseWidths.map { $0 * multiplier }
        let totalWidth = displayWidths.reduce(0, +)

        // 6. 摆放
        var frames: [CGRect] = []
        frames.reserveCapacity(pages.count)

        if pages.count == 1 {
            // 单页：方向不移动它，居中交给 MacCenteringClipView
            frames.append(CGRect(x: 0, y: 0, width: displayWidths[0], height: displayHeight))
        } else if direction == .rightToLeft {
            // RTL：下标 i 的 x = 其后所有页的宽度之和 → 页码大的在左
            for i in 0..<pages.count {
                let tail = displayWidths[(i + 1)...].reduce(0, +)
                frames.append(CGRect(x: tail, y: 0, width: displayWidths[i], height: displayHeight))
            }
        } else {
            // LTR / 从上到下：下标 0 在最左，依次向右
            var x: CGFloat = 0
            for i in 0..<pages.count {
                frames.append(CGRect(x: x, y: 0, width: displayWidths[i], height: displayHeight))
                x += displayWidths[i]
            }
        }

        return Result(documentSize: CGSize(width: totalWidth, height: displayHeight),
                      pageFrames: frames)
    }
}

// MARK: - 居中裁剪视图

/// 文档比视口小时把内容居中；否则保持 NSScrollView 的默认约束。
final class MacCenteringClipView: NSClipView {

    /// 顶部让位高度（macOS 窗口工具栏）。未缩放时内容居中在它下方；
    /// 放大后 doc 大于可视区，居中分支不生效，内容即可铺到工具栏下方。
    var topInset: CGFloat = 0

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return result }
        let docSize = docView.frame.size
        if docSize.width < result.width {
            result.origin.x = (docSize.width - result.width) * 0.5
        }
        if docSize.height < result.height {
            result.origin.y = (docSize.height - result.height) * 0.5 - topInset * 0.5
        }
        return result
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 翻转容器（子视图坐标以左上为原点）

/// isFlipped = true，便于用「左上原点」摆放最多 2 张图。
final class MacSpreadContainerView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 单个缩放/滚动面

/// 一个「展」的显示面：文档视图里最多放 2 张 NSImageView。
///
/// 缩放的所有权只在这里：文档尺寸由 `MacSpreadLayout` 按 `contentSize`
/// （与 magnification 无关）算出，re-fit 时保留用户当前的 magnification。
final class MacSpreadScrollView: NSScrollView {

    private let container = MacSpreadContainerView()
    private var imageViews: [NSImageView] = []

    /// 当前排版参数（只读给翻页器比较用）
    private(set) var scaleMode: ScaleMode = .fit
    private(set) var direction: ReadingDirection = .leftToRight

    private var lastLayoutSize: CGSize = .zero
    private var isRelayouting = false

    /// 顶部让位高度（窗口工具栏）。透传给裁剪视图，并让 fit 视口高度相应减少。
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            (contentView as? MacCenteringClipView)?.topInset = topInset
            lastLayoutSize = .zero
            applyLayout()
        }
    }

    var onScrollWheel: ((NSEvent) -> Bool)?
    /// 单击：回调左上角坐标 + 视口尺寸
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        allowsMagnification = true
        minMagnification = 1.0
        maxMagnification = 5.0
        scrollerStyle = .overlay
        autohidesScrollers = true
        hasVerticalScroller = true
        hasHorizontalScroller = true
        drawsBackground = true
        backgroundColor = .black

        let clip = MacCenteringClipView()
        clip.topInset = topInset
        contentView = clip
        container.frame = .zero
        documentView = container

        for _ in 0..<2 {
            let iv = NSImageView()
            // 用 .scaleNone 会按原图像素尺寸绘制再裁剪，导致页面巨大；必须交给 AppKit 缩放到 frame
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.animates = true
            iv.imageAlignment = .alignCenter
            container.addSubview(iv)
            imageViews.append(iv)
        }

        // 单击 / 双击手势
        let single = NSClickGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        single.numberOfClicksRequired = 1
        single.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(single)

        let double = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfClicksRequired = 2
        addGestureRecognizer(double)

        // 缩放结束后同步给翻页器
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(magnifyDidEnd(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 配置

    /// 换页/首次配置：写入图片，重置缩放到适应，然后排版。
    func configure(images: [NSImage], scaleMode: ScaleMode, direction: ReadingDirection) {
        self.scaleMode = scaleMode
        self.direction = direction
        applyImages(images)
        magnification = 1.0
        lastLayoutSize = .zero
        applyLayout()
    }

    /// 同页内图片内容更新：保留缩放。
    func updateImages(_ images: [NSImage], scaleMode: ScaleMode, direction: ReadingDirection) {
        self.scaleMode = scaleMode
        self.direction = direction
        applyImages(images)
        applyLayout()
    }

    /// 同页内排版参数变化：保留缩放。
    func updateLayout(scaleMode: ScaleMode, direction: ReadingDirection) {
        self.scaleMode = scaleMode
        self.direction = direction
        applyLayout()
    }

    /// 重置为适应（magnification = 1）
    func resetZoomToFit() {
        magnification = 1.0
    }

    /// 用户是否处于放大状态
    var isUserZoomed: Bool { magnification > 1.001 }

    /// 文档在指定轴上是否放不下（需要滚动）。用于判断滚轮应该平移还是翻页。
    func documentOverflows(horizontal: Bool) -> Bool {
        guard let doc = documentView else { return false }
        let docSize = doc.frame.size
        let viewport = contentSize
        return horizontal
            ? docSize.width > viewport.width + 0.5
            : docSize.height > viewport.height + 0.5
    }

    private func applyImages(_ images: [NSImage]) {
        for (i, iv) in imageViews.enumerated() {
            if i < images.count {
                iv.image = images[i]
                iv.isHidden = false
            } else {
                iv.image = nil
                iv.isHidden = true
            }
        }
    }

    // MARK: 排版

    /// 用 contentSize（magnification 无关）算文档尺寸与图片 frame。
    private func applyLayout() {
        let fullSize = contentSize
        guard fullSize.width > 0, fullSize.height > 0 else { return }
        // 顶部工具栏区域不计入 fit：未缩放时页面排在工具栏下方
        let viewport = CGSize(width: fullSize.width, height: max(1, fullSize.height - topInset))

        var sizes: [CGSize] = []
        var visibleIndexes: [Int] = []
        for (i, iv) in imageViews.enumerated() where !iv.isHidden {
            guard let img = iv.image else { continue }
            sizes.append(img.size)
            visibleIndexes.append(i)
        }

        let result = MacSpreadLayout.frames(
            pages: sizes, viewport: viewport, scaleMode: scaleMode, direction: direction
        )

        container.frame = CGRect(origin: .zero, size: result.documentSize)
        for (k, frame) in result.pageFrames.enumerated() {
            imageViews[visibleIndexes[k]].frame = frame
        }
        lastLayoutSize = fullSize
        recenter()
    }

    /// 文档比视口小时重新居中（含顶部工具栏让位）。程序化设置 bounds 不会自动走
    /// constrainBoundsRect，所以必须显式调用，否则翻页后内容会贴到顶部。
    private func recenter() {
        guard let clip = contentView as? MacCenteringClipView else { return }
        let constrained = clip.constrainBoundsRect(
            NSRect(origin: clip.bounds.origin, size: clip.bounds.size))
        guard constrained.origin != clip.bounds.origin else { return }
        clip.setBoundsOrigin(constrained.origin)
        reflectScrolledClipView(clip)
    }

    /// 视口变化时重新排版：保留 magnification，并恢复滚动中心。
    override func layout() {
        super.layout()

        guard !isRelayouting else { return }
        let newSize = contentSize
        guard newSize.width > 0, newSize.height > 0, newSize != lastLayoutSize else { return }

        isRelayouting = true
        defer { isRelayouting = false }

        let savedMagnification = magnification
        let oldDocSize = documentView?.frame.size ?? .zero
        let visible = documentVisibleRect
        let centerFractionX = oldDocSize.width > 0 ? (visible.midX / oldDocSize.width) : 0.5
        let centerFractionY = oldDocSize.height > 0 ? (visible.midY / oldDocSize.height) : 0.5

        applyLayout()
        // re-fit 不重置用户缩放
        magnification = savedMagnification

        // 恢复滚动中心（clamp 到合法范围）
        if let docSize = documentView?.frame.size, docSize.width > 0, docSize.height > 0 {
            let targetX = centerFractionX * docSize.width - contentSize.width / 2
            let targetY = centerFractionY * docSize.height - contentSize.height / 2
            let maxX = max(0, docSize.width - contentSize.width)
            let maxY = max(0, docSize.height - contentSize.height)
            let clamped = CGPoint(x: min(max(0, targetX), maxX),
                                  y: min(max(0, targetY), maxY))
            contentView.scroll(to: clamped)
            reflectScrolledClipView(contentView)
        }
        recenter()
    }

    // MARK: 事件

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if let handler = onScrollWheel, handler(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    @objc private func magnifyDidEnd(_ note: Notification) {
        onZoomChanged?(isUserZoomed)
    }

    @objc private func handleSingleTap(_ gesture: NSClickGestureRecognizer) {
        let p = gesture.location(in: self)
        let size = bounds.size
        // macOS 坐标原点在左下角，翻转 Y 轴匹配 iOS 左上原点
        let flipped = CGPoint(x: p.x, y: size.height - p.y)
        onSingleTap?(flipped, size)
    }

    @objc private func handleDoubleTap(_ gesture: NSClickGestureRecognizer) {
        if isUserZoomed {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.animator().magnification = 1.0
            }
            onZoomChanged?(false)
        } else {
            let point = gesture.location(in: container)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.animator().setMagnification(2.5, centeredAt: point)
            }
            onZoomChanged?(true)
        }
        onDoubleTap?()
    }
}

// MARK: - 翻页器

/// 原生翻页器：4 个 `MacSpreadScrollView` 的面池。
/// 当前面 + 最多 2 个已预渲染的相邻面（next/prev）+ 若干空闲面。
/// 翻到相邻页时直接复用预渲染好的邻面，翻页只剩动画；
/// 同页不重置缩放；跳页直接换页并重置缩放。
final class MacPageReaderView: NSView {

    private var surfaces: [MacSpreadScrollView] = []
    private var currentSurface: MacSpreadScrollView!
    private var incomingSurface: MacSpreadScrollView?

    // 预渲染好的相邻面：pageIndex → 已 configure 好的 surface
    private var neighborSurfaces: [Int: MacSpreadScrollView] = [:]
    private var neighborImageIDs: [Int: [ObjectIdentifier]] = [:]
    private var freeSurfaces: [MacSpreadScrollView] = []

    private(set) var currentPageIndex = -1
    private var currentImageIDs: [ObjectIdentifier] = []
    private var isAnimating = false
    private var generation = 0

    // 最新的相邻页内容：滑动提交是异步的，提交时用最新的 next/prev 重备邻面
    private var latestNext: MacSpreadContent?
    private var latestPrev: MacSpreadContent?

    // 滑动翻页的滚动累积状态
    private var accumulatedScroll: CGFloat = 0
    private var didEmitTurnInGesture = false
    private var lastScrollTime: Date = .distantPast

    // 动画收尾所需状态（便于动画中途被 configure 打断时瞬间完成）
    private var pendingIncoming: MacSpreadScrollView?
    private var pendingOld: MacSpreadScrollView?
    private var pendingPageIndex = -1
    private var pendingStartPosition: StartPosition = .topLeft
    private var pendingIncomingImageIDs: [ObjectIdentifier] = []

    var onTurn: ((Bool) -> Void)?
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    /// 顶部让位高度（窗口工具栏），透传给所有 surface。
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            for surface in surfaces { surface.topInset = topInset }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// 临时诊断日志（DEBUG 生效），用于定位翻页状态错位。定位后可删。
    private func log(_ message: String) {
        #if DEBUG
        print("[MacPager] \(message)")
        #endif
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        // 4 个面：1 当前 + 2 预渲染邻面 + 1 备用
        for _ in 0..<4 {
            surfaces.append(makeSurface())
        }
        currentSurface = surfaces[0]
        freeSurfaces = [surfaces[1], surfaces[2], surfaces[3]]
        currentSurface.frame = CGRect(origin: .zero, size: bounds.size)
        addSubview(currentSurface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeSurface() -> MacSpreadScrollView {
        let surface = MacSpreadScrollView()
        surface.topInset = topInset
        surface.onSingleTap = { [weak self, weak surface] location, size in
            guard let self, let surface, surface === self.currentSurface else { return }
            self.onSingleTap?(location, size)
        }
        surface.onZoomChanged = { [weak self] zoomed in
            guard let self else { return }
            self.onZoomChanged?(zoomed)
        }
        surface.onScrollWheel = { [weak self, weak surface] event in
            guard let self, let surface else { return false }
            return self.handleScrollWheel(event, surface: surface)
        }
        return surface
    }

    // MARK: 对外配置

    func configure(current: MacSpreadContent, next: MacSpreadContent?, prev: MacSpreadContent?,
                   scaleMode: ScaleMode, startPosition: StartPosition,
                   direction: ReadingDirection, isDoublePage: Bool) {
        latestNext = next
        latestPrev = prev

        // 防御：动画标记卡住却没有待提交的面（completion 丢失）时复位，避免后续都不再起动画
        if isAnimating, pendingIncoming == nil {
            isAnimating = false
            incomingSurface = nil
        }

        let imageIDs = current.images.map { ObjectIdentifier($0) }

        log("configure page=\(current.pageIndex) cur=\(currentPageIndex) "
            + "delta=\(current.pageIndex - currentPageIndex) animating=\(isAnimating) "
            + "imgs=\(current.images.count) ready=\(current.isReady) "
            + "next=\(next?.pageIndex ?? -1) prev=\(prev?.pageIndex ?? -1)")

        // 正在滑向同一目标页：只把最新到的图填进 incoming，绝不打断动画。
        // （图是异步到达的，翻页后 updateNSView 会再调一次 configure；
        //  若在此处收尾动画，滑动就永远看不到。）
        if isAnimating, let incoming = pendingIncoming, pendingPageIndex == current.pageIndex {
            if imageIDs != pendingIncomingImageIDs {
                incoming.updateImages(current.images, scaleMode: scaleMode, direction: direction)
                pendingIncomingImageIDs = imageIDs
            }
            currentImageIDs = imageIDs
            return
        }

        // 正在动画但目标已变（连续翻页）：先瞬间收尾，再从提交后的状态继续。
        if isAnimating {
            finishAnimationImmediately()
        }

        let delta = current.pageIndex - currentPageIndex

        // 同页：不重置缩放，只在内容/排版变化时更新
        if currentPageIndex >= 0 && delta == 0 {
            let imagesChanged = imageIDs != currentImageIDs
            let layoutChanged = currentSurface.scaleMode != scaleMode
                || currentSurface.direction != direction
            if imagesChanged {
                currentSurface.updateImages(current.images, scaleMode: scaleMode, direction: direction)
            } else if layoutChanged {
                currentSurface.updateLayout(scaleMode: scaleMode, direction: direction)
            }
            currentImageIDs = imageIDs
            prepareNeighbors(next: next, prev: prev, scaleMode: scaleMode, direction: direction)
            return
        }

        // 相邻页：滑动
        if currentPageIndex >= 0 && abs(delta) == 1 {
            let forward = delta > 0

            let incoming: MacSpreadScrollView
            if let prepared = neighborSurfaces[current.pageIndex] {
                neighborSurfaces.removeValue(forKey: current.pageIndex)
                // 预渲染内容可能已过期（页图刚到达等）：不匹配就地重配，避免滑到空白
                if neighborImageIDs[current.pageIndex] != imageIDs {
                    prepared.frame = CGRect(origin: .zero, size: bounds.size)
                    prepared.layoutSubtreeIfNeeded()
                    prepared.configure(images: current.images, scaleMode: scaleMode, direction: direction)
                }
                neighborImageIDs.removeValue(forKey: current.pageIndex)
                incoming = prepared
            } else if let free = takeFreeSurface() {
                free.frame = CGRect(origin: .zero, size: bounds.size)
                free.layoutSubtreeIfNeeded()
                free.configure(images: current.images, scaleMode: scaleMode, direction: direction)
                incoming = free
            } else {
                // 没有备用面（理论上不会发生）：退化为交叉淡入，保留动画而不是硬切
                crossfadeTo(current: current, scaleMode: scaleMode,
                            startPosition: startPosition, direction: direction)
                return
            }

            // 进入方向：LTR 下一页从右进；RTL 反过来；纵向按前进方向
            let enterFromRight: Bool
            switch direction {
            case .leftToRight: enterFromRight = forward
            case .rightToLeft: enterFromRight = !forward
            case .topToBottom: enterFromRight = forward
            }

            let w = bounds.width
            let h = bounds.height
            let inStartX: CGFloat = enterFromRight ? w : -w
            let oldEndX: CGFloat = enterFromRight ? -w : w
            log("slide \(currentPageIndex)->\(current.pageIndex) forward=\(forward) w=\(w) h=\(h)")

            // 视图 model 直接放终点：显式 CA 只驱动 presentation。
            // 这样动画结束、被移除、或 layout 重同步图层，都落到同一终点，不会回弹闪黑帧。
            incoming.alphaValue = 1
            incoming.frame = CGRect(x: 0, y: 0, width: w, height: h)
            currentSurface.frame = CGRect(x: oldEndX, y: 0, width: w, height: h)
            addSubview(incoming, positioned: .above, relativeTo: currentSurface)
            incoming.layoutSubtreeIfNeeded()

            let oldSurface = currentSurface!
            incomingSurface = incoming
            pendingIncoming = incoming
            pendingOld = oldSurface
            pendingPageIndex = current.pageIndex
            pendingStartPosition = startPosition
            pendingIncomingImageIDs = imageIDs
            isAnimating = true
            generation += 1
            let gen = generation

            incoming.wantsLayer = true
            oldSurface.wantsLayer = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == gen else { return }
                self.commitPendingSlide()
            }
            if let il = incoming.layer, let ol = oldSurface.layer {
                let dur: Double = 0.22
                let ia = CABasicAnimation(keyPath: "position.x")
                ia.fromValue = inStartX
                ia.toValue = 0
                ia.duration = dur
                ia.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let oa = CABasicAnimation(keyPath: "position.x")
                oa.fromValue = 0
                oa.toValue = oldEndX
                oa.duration = dur
                oa.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                CATransaction.setDisableActions(true)
                il.add(ia, forKey: "slide")
                ol.add(oa, forKey: "slide")
            }
            CATransaction.commit()

            currentImageIDs = imageIDs
            return
        }

        // 首次配置直接换页；非相邻跳页交叉淡入，不硬切
        if currentPageIndex < 0 {
            jumpTo(current: current, scaleMode: scaleMode,
                   startPosition: startPosition, direction: direction)
        } else {
            log("ELSE->crossfade \(currentPageIndex)->\(current.pageIndex)")
            crossfadeTo(current: current, scaleMode: scaleMode,
                        startPosition: startPosition, direction: direction)
        }
    }

    // MARK: 预渲染相邻面

    /// 备齐 next / prev 两个邻面：丢弃失效的，补上缺失的。
    private func prepareNeighbors(next: MacSpreadContent?, prev: MacSpreadContent?,
                                  scaleMode: ScaleMode, direction: ReadingDirection) {
        var desired: [Int: [NSImage]] = [:]
        if let next, next.pageIndex != currentPageIndex {
            desired[next.pageIndex] = next.images
        }
        if let prev, prev.pageIndex != currentPageIndex, desired[prev.pageIndex] == nil {
            desired[prev.pageIndex] = prev.images
        }

        // 丢弃失效邻面：不再需要，或图片内容已变化
        for pageIndex in Array(neighborSurfaces.keys) {
            guard let surface = neighborSurfaces[pageIndex] else { continue }
            let desiredIDs = desired[pageIndex]?.map { ObjectIdentifier($0) }
            let keep = surface !== currentSurface
                && desiredIDs != nil
                && desiredIDs == neighborImageIDs[pageIndex]
            if !keep {
                neighborSurfaces.removeValue(forKey: pageIndex)
                neighborImageIDs.removeValue(forKey: pageIndex)
                returnToFree(surface)
            }
        }

        // 补上缺失邻面
        for (pageIndex, images) in desired {
            guard neighborSurfaces[pageIndex] == nil else { continue }
            guard let free = takeFreeSurface() else { continue }
            // 先定尺寸再排版：否则 configure 里读到的 contentSize 是 0，会退回到翻页时才排版
            free.frame = CGRect(origin: .zero, size: bounds.size)
            free.layoutSubtreeIfNeeded()
            free.configure(images: images, scaleMode: scaleMode, direction: direction)
            neighborSurfaces[pageIndex] = free
            neighborImageIDs[pageIndex] = images.map { ObjectIdentifier($0) }
        }
    }

    // MARK: 内部

    private func takeFreeSurface() -> MacSpreadScrollView? {
        guard let surface = freeSurfaces.popLast() else { return nil }
        // 防御：当前面绝不作为邻居面复用
        guard surface !== currentSurface else { return takeFreeSurface() }
        return surface
    }

    private func returnToFree(_ surface: MacSpreadScrollView) {
        guard surface !== currentSurface else { return }
        if surface.superview != nil { surface.removeFromSuperview() }
        // 复用前必须不透明：交叉淡出会把旧面留成 alpha 0，否则复用后整面隐形
        surface.alphaValue = 1
        if !freeSurfaces.contains(where: { $0 === surface }) {
            freeSurfaces.append(surface)
        }
    }

    private func jumpTo(current: MacSpreadContent, scaleMode: ScaleMode,
                        startPosition: StartPosition, direction: ReadingDirection) {
        log("jumpTo \(currentPageIndex)->\(current.pageIndex)")
        currentSurface.configure(images: current.images, scaleMode: scaleMode, direction: direction)
        currentSurface.frame = CGRect(origin: .zero, size: bounds.size)
        currentPageIndex = current.pageIndex
        currentImageIDs = current.images.map { ObjectIdentifier($0) }
        applyStartPosition(startPosition, on: currentSurface)
        prepareNeighbors(next: latestNext, prev: latestPrev, scaleMode: scaleMode, direction: direction)
    }

    /// 动画被中途打断：撤销动画并把暂存的 incoming 瞬间提交。
    private func finishAnimationImmediately() {
        guard isAnimating else { return }
        generation += 1  // 让旧的 completion 失效
        currentSurface?.layer?.removeAllAnimations()
        incomingSurface?.layer?.removeAllAnimations()
        isAnimating = false
        commitPendingSlide()
    }

    /// 真正提交一次滑动：incoming 变 current，old 回收，并按最新 next/prev 重备邻面。
    private func commitPendingSlide() {
        guard let incoming = pendingIncoming, let old = pendingOld else {
            isAnimating = false
            incomingSurface = nil
            log("commit SKIPPED (no pending)")
            return
        }
        log("commit -> \(pendingPageIndex)")
        incoming.frame = CGRect(origin: .zero, size: bounds.size)
        incoming.alphaValue = 1
        old.removeFromSuperview()

        currentSurface = incoming
        incomingSurface = nil
        currentPageIndex = pendingPageIndex
        currentImageIDs = pendingIncomingImageIDs
        isAnimating = false

        let startPosition = pendingStartPosition
        pendingIncoming = nil
        pendingOld = nil
        pendingIncomingImageIDs = []

        applyStartPosition(startPosition, on: incoming)
        returnToFree(old)
        prepareNeighbors(next: latestNext, prev: latestPrev,
                         scaleMode: incoming.scaleMode, direction: incoming.direction)
    }

    /// 非相邻跳页：新面淡入、旧面淡出，避免硬切。
    private func crossfadeTo(current: MacSpreadContent, scaleMode: ScaleMode,
                             startPosition: StartPosition, direction: ReadingDirection) {
        let incoming: MacSpreadScrollView
        if let prepared = neighborSurfaces.removeValue(forKey: current.pageIndex) {
            let ids = current.images.map { ObjectIdentifier($0) }
            if neighborImageIDs[current.pageIndex] != ids {
                prepared.frame = CGRect(origin: .zero, size: bounds.size)
                prepared.layoutSubtreeIfNeeded()
                prepared.configure(images: current.images, scaleMode: scaleMode, direction: direction)
            }
            neighborImageIDs.removeValue(forKey: current.pageIndex)
            incoming = prepared
        } else if let free = takeFreeSurface() {
            free.frame = CGRect(origin: .zero, size: bounds.size)
            free.layoutSubtreeIfNeeded()
            free.configure(images: current.images, scaleMode: scaleMode, direction: direction)
            incoming = free
        } else {
            jumpTo(current: current, scaleMode: scaleMode,
                   startPosition: startPosition, direction: direction)
            return
        }

        incoming.frame = CGRect(origin: .zero, size: bounds.size)
        incoming.alphaValue = 0
        addSubview(incoming, positioned: .above, relativeTo: currentSurface)

        let old = currentSurface!
        incomingSurface = incoming
        pendingIncoming = incoming
        pendingOld = old
        pendingPageIndex = current.pageIndex
        pendingStartPosition = startPosition
        pendingIncomingImageIDs = current.images.map { ObjectIdentifier($0) }
        isAnimating = true
        generation += 1
        let gen = generation

        incoming.wantsLayer = true
        old.wantsLayer = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == gen else { return }
            self.commitPendingSlide()
        }
        if let il = incoming.layer, let ol = old.layer {
            let ia = CABasicAnimation(keyPath: "opacity")
            ia.fromValue = 0; ia.toValue = 1; ia.duration = 0.2
            ia.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let oa = CABasicAnimation(keyPath: "opacity")
            oa.fromValue = 1; oa.toValue = 0; oa.duration = 0.2
            oa.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.setDisableActions(true)
            il.add(ia, forKey: "fade")
            ol.add(oa, forKey: "fade")
            il.opacity = 1
            ol.opacity = 0
        }
        CATransaction.commit()

        currentImageIDs = current.images.map { ObjectIdentifier($0) }
    }

    /// 提交时按 startPosition 摆放滚动位置（尽力而为；文档小于视口时由居中裁剪视图接管）。
    private func applyStartPosition(_ position: StartPosition, on surface: MacSpreadScrollView) {
        let clip = surface.contentView
        guard let doc = surface.documentView else { return }
        let docSize = doc.frame.size
        let viewSize = surface.contentSize
        let maxX = max(0, docSize.width - viewSize.width)
        let maxY = max(0, docSize.height - viewSize.height)

        // 文档放得下时不强制滚动，交给居中裁剪视图（按 topInset 让位到工具栏下方）
        guard maxX > 0 || maxY > 0 else { return }

        let point: CGPoint
        switch position {
        case .topLeft: point = .zero
        case .topRight: point = CGPoint(x: maxX, y: 0)
        case .bottomLeft: point = CGPoint(x: 0, y: maxY)
        case .bottomRight: point = CGPoint(x: maxX, y: maxY)
        case .center: point = CGPoint(x: maxX / 2, y: maxY / 2)
        }

        clip.scroll(to: point)
        surface.reflectScrolledClipView(clip)
    }

    /// 滚动/滑动规则：
    /// - 放大、或文档在滑动主轴上溢出 → 交回 surface 平移（保证两指拖动跟手）
    /// - 页面完整放得下 → 按手势方向翻页，每个手势只翻一次（忽略惯性）
    private func handleScrollWheel(_ event: NSEvent, surface: MacSpreadScrollView) -> Bool {
        if surface.isUserZoomed { return false }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let horizontal = abs(dx) > abs(dy)

        if surface.documentOverflows(horizontal: horizontal) { return false }

        // 惯性阶段直接吞掉，不翻页
        if !event.momentumPhase.isEmpty { return true }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulatedScroll = 0
            didEmitTurnInGesture = false
            return true
        }

        let now = Date()
        // 传统滚轮没有 phase，用时间做手势边界
        if event.phase.isEmpty, now.timeIntervalSince(lastScrollTime) > 0.5 {
            accumulatedScroll = 0
            didEmitTurnInGesture = false
        }
        lastScrollTime = now

        // 横向取负：此前的横向翻页方向是反的
        let delta = horizontal ? -dx : dy
        accumulatedScroll += delta

        let threshold: CGFloat = 40
        if !didEmitTurnInGesture {
            if accumulatedScroll > threshold {
                didEmitTurnInGesture = true
                onTurn?(false)  // 正值 → 上一页
            } else if accumulatedScroll < -threshold {
                didEmitTurnInGesture = true
                onTurn?(true)   // 负值 → 下一页
            }
        }
        return true
    }

    override func layout() {
        super.layout()
        guard !isAnimating else { return }
        let size = bounds.size
        for surface in surfaces where surface.superview === self {
            if surface.frame.size != size {
                surface.frame = CGRect(origin: .zero, size: size)
            }
        }
    }

    /// 内容签名：当前展 + 相邻展的页码/就绪态/图片对象，配合排版参数，
    /// 任一变化都应重新下发 configure（图片异步到达时刷新邻面）。
    static func makeSignature(current: MacSpreadContent, next: MacSpreadContent?,
                              prev: MacSpreadContent?, scaleMode: ScaleMode,
                              direction: ReadingDirection, isDoublePage: Bool) -> String {
        func part(_ content: MacSpreadContent?) -> String {
            guard let content else { return "-" }
            let ids = content.images.map { String(describing: ObjectIdentifier($0)) }
                .joined(separator: ",")
            return "\(content.pageIndex):\(content.isReady):\(ids)"
        }
        return "\(part(current))|\(part(next))|\(part(prev))"
            + "|\(scaleMode.rawValue)|\(direction.rawValue)|\(isDoublePage)"
    }
}

#endif
