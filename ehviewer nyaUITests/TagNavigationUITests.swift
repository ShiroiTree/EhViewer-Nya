//
//  TagNavigationUITests.swift
//  ehviewer nyaUITests
//
//  标签导航回归测试。
//
//  背景：标签 chip 的跳转从「TagSearchDestination + 各栈各自注册」改成
//  「AppRoute + `.ehGalleryDestinations()` 一次注册」。本用例端到端验证
//  详情页点标签确实会离开详情页、打开标签列表。
//
//  前置：模拟器里 App 需能联网（本机用 127.0.0.1:2081 代理，已写进 App 的代理设置），
//  且已跳过引导（skip_sign_in）。否则第一步就加载不出画廊。
//
//  注：从「历史」进入详情这条路径同样是本修复的目标，但历史行的
//  「零透明 NavigationLink 垫底 + 内容在上」布局让 XCUITest 的坐标点击无法
//  命中垫底链接，故此处用首页入口；历史入口建议在 Xcode 里手动回归。
//

import XCTest

final class TagNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDetailTagOpensTagList() throws {
        let app = XCUIApplication()
        app.launch()
        enterMainIfNeeded(app)

        XCTAssertTrue(app.buttons["历史"].waitForExistence(timeout: 30), "未进入主界面")

        // ① 首页 → 点第一个画廊 → 详情
        let firstCell = app.cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 45), "首页未加载出画廊（网络？）")
        firstCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        sleep(9)

        // 详情页标记
        XCTAssertTrue(app.staticTexts["评论"].waitForExistence(timeout: 15), "详情页未加载")
        print("DETAIL_BEGIN\n\(app.debugDescription)\nDETAIL_END")

        // ② 点第一个标签 chip → 应打开标签列表（离开详情页）
        guard let tagEl = firstTagChip(in: app) else {
            XCTFail("详情页没找到可点的标签 chip")
            return
        }
        tagEl.tap()
        sleep(6)
        print("AFTERTAG_BEGIN\n\(app.debugDescription)\nAFTERTAG_END")

        // 标签列表推入后，详情页的「评论」区块应当消失
        XCTAssertFalse(app.staticTexts["评论"].waitForExistence(timeout: 3),
                       "点标签没有跳转（仍停留在详情页）")
    }

    // MARK: - Helpers

    /// 定位详情页里的一个标签 chip。
    ///
    /// 标签 chip 是 `Button`；而「原作 / 角色 / 女性」这些是分类名，是 `StaticText`。
    /// 早先按固定文字匹配会点到分类名（点它不跳转），故改为：在「标签」区标题
    /// 下方，取第一个不是操作按钮的 Button。
    @MainActor
    private func firstTagChip(in app: XCUIApplication) -> XCUIElement? {
        let actionLabels: Set<String> = ["阅读", "喜欢", "归档", "下载", "箭头向下圆圈", "书签", "评论"]
        let header = app.staticTexts["标签"].firstMatch
        let upperBoundY = header.exists ? header.frame.minY : 0
        for b in app.buttons.allElementsBoundByIndex {
            guard !actionLabels.contains(b.label), !b.label.isEmpty else { continue }
            if upperBoundY == 0 || b.frame.minY >= upperBoundY {
                return b
            }
        }
        return nil
    }

    @MainActor
    private func enterMainIfNeeded(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        for label in ["我已满 18 岁，继续", "开始使用", "以访客身份浏览", "继续"] {
            let b = app.buttons[label]
            if b.waitForExistence(timeout: 4) { b.tap() }
        }
    }
}
