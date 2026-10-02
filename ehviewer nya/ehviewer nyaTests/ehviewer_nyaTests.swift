//
//  ehviewer_nyaTests.swift
//  ehviewer nyaTests
//
//  Created by 晓卡 on 2026/2/12.
//

import Testing
import CoreGraphics
@testable import ehviewer_nya

struct ehviewer_nyaTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

#if os(macOS)

// MARK: - MacSpreadLayout 排版守护测试
//
// 覆盖双页排版最容易回归的几处：
// - 单页 fit 的倍率取 min(fitWidth, fitHeight)
// - 双页共享显示高度，较高的页 1:1、较矮的页按比例补宽
// - RTL 与 LTR 的左右互换
// - 单页不受方向影响
// - 五种 ScaleMode 各自的倍率
// - 非法输入不产生 NaN / Inf

@MainActor
@Suite("MacSpreadLayout 双页排版")
struct MacSpreadLayoutTests {

    /// 基准双页：均为 200 高，宽度 100 / 300
    private let portrait = CGSize(width: 100, height: 200)
    private let landscape = CGSize(width: 300, height: 200)

    private func frames(_ pages: [CGSize],
                        viewport: CGSize,
                        scaleMode: ScaleMode,
                        direction: ReadingDirection = .leftToRight) -> MacSpreadLayout.Result {
        MacSpreadLayout.frames(pages: pages, viewport: viewport,
                               scaleMode: scaleMode, direction: direction)
    }

    @Test("空页返回零结果")
    func emptyPages() {
        let r = frames([], viewport: CGSize(width: 800, height: 600), scaleMode: .fit)
        #expect(r.documentSize == .zero)
        #expect(r.pageFrames.isEmpty)
    }

    @Test("单页 fit：取宽度与高度倍率中的较小者")
    func singlePageFit() {
        // fitWidth = 400/100 = 4，fitHeight = 400/200 = 2 → fit = 2
        let r = frames([portrait], viewport: CGSize(width: 400, height: 400), scaleMode: .fit)
        #expect(r.documentSize == CGSize(width: 200, height: 400))
        #expect(r.pageFrames == [CGRect(x: 0, y: 0, width: 200, height: 400)])
    }

    @Test("双页共享高度：origin 下文档为两页宽度之和")
    func doublePageSharedHeight() {
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .origin)
        #expect(r.documentSize == CGSize(width: 400, height: 200))
        // LTR：下标 0 在左
        #expect(r.pageFrames == [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 100, y: 0, width: 300, height: 200),
        ])
    }

    @Test("最低页宽被按比例补到同一高度")
    func narrowerPageScaledUp() {
        // 第二页 100x100：baseHeight=200 → 基准宽 200，总宽 100+200=300
        let small = CGSize(width: 100, height: 100)
        let r = frames([portrait, small], viewport: CGSize(width: 600, height: 600),
                       scaleMode: .origin)
        #expect(r.documentSize == CGSize(width: 300, height: 200))
        #expect(r.pageFrames == [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 100, y: 0, width: 200, height: 200),
        ])
    }

    @Test("RTL 与 LTR 左右互换")
    func rightToLeftSwapsSides() {
        let ltr = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                         scaleMode: .origin, direction: .leftToRight)
        let rtl = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                         scaleMode: .origin, direction: .rightToLeft)

        #expect(ltr.pageFrames == [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 100, y: 0, width: 300, height: 200),
        ])
        // RTL：页码大的（index 1）在左
        #expect(rtl.pageFrames == [
            CGRect(x: 300, y: 0, width: 100, height: 200),
            CGRect(x: 0, y: 0, width: 300, height: 200),
        ])
        #expect(ltr.documentSize == rtl.documentSize)
    }

    @Test("单页不受方向影响")
    func lonePageIgnoresDirection() {
        let ltr = frames([portrait], viewport: CGSize(width: 400, height: 400),
                         scaleMode: .origin, direction: .leftToRight)
        let rtl = frames([portrait], viewport: CGSize(width: 400, height: 400),
                         scaleMode: .origin, direction: .rightToLeft)
        #expect(ltr.pageFrames == [CGRect(x: 0, y: 0, width: 100, height: 200)])
        #expect(rtl.pageFrames == [CGRect(x: 0, y: 0, width: 100, height: 200)])
        #expect(ltr.documentSize == CGSize(width: 100, height: 200))
    }

    @Test("从上到下与从左到右的摆放一致")
    func topToBottomMatchesLTRPlacement() {
        let ltr = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                         scaleMode: .origin, direction: .leftToRight)
        let ttb = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                         scaleMode: .origin, direction: .topToBottom)
        #expect(ltr == ttb)
    }

    // MARK: 五种 ScaleMode

    @Test("origin：倍率固定为 1")
    func scaleModeOrigin() {
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .origin)
        #expect(r.documentSize == CGSize(width: 400, height: 200))
    }

    @Test("fixed：倍率固定为 1")
    func scaleModeFixed() {
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .fixed)
        #expect(r.documentSize == CGSize(width: 400, height: 200))
    }

    @Test("fitWidth：按宽度铺满")
    func scaleModeFitWidth() {
        // 800 / 400 = 2
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .fitWidth)
        #expect(r.documentSize == CGSize(width: 800, height: 400))
    }

    @Test("fitHeight：按高度铺满")
    func scaleModeFitHeight() {
        // 600 / 200 = 3
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .fitHeight)
        #expect(r.documentSize == CGSize(width: 1200, height: 600))
    }

    @Test("fit：取 fitWidth 与 fitHeight 的较小者")
    func scaleModeFit() {
        // min(2, 3) = 2
        let r = frames([portrait, landscape], viewport: CGSize(width: 800, height: 600),
                       scaleMode: .fit)
        #expect(r.documentSize == CGSize(width: 800, height: 400))
    }

    // MARK: 防御

    @Test("非法尺寸不产生 NaN（零尺寸页）")
    func invalidPageSizeIsSafe() {
        let r = frames([CGSize(width: 0, height: 0)], viewport: CGSize(width: 400, height: 400),
                       scaleMode: .fit)
        #expect(r.documentSize == .zero)
        #expect(r.pageFrames == [.zero])
    }

    @Test("非正视口时倍率回退为 1，结果仍有限")
    func invalidViewportIsFinite() {
        let r = frames([portrait, landscape], viewport: .zero, scaleMode: .fit)
        #expect(r.documentSize == CGSize(width: 400, height: 200))
        #expect(r.documentSize.width.isFinite && r.documentSize.height.isFinite)
    }
}

#endif
