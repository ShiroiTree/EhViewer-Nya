//
//  ToplistChromeUITests.swift
//  ehviewer nyaUITests
//
//  验证「排行榜」在各入口都带出周期选择条（此前只有 iPhone 首页切页有，
//  iPad/macOS 侧栏进排行锁死「全部时间」）。
//
//  在 iPad 模拟器上跑：侧栏 → 排行榜 → 断言出现「过去一年」这个周期 pill。
//

import XCTest

final class ToplistChromeUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testToplistHasPeriodPillsInSidebar() throws {
        let app = XCUIApplication()
        app.launch()
        enterMainIfNeeded(app)

        // iPad 侧栏的「排行榜」
        let toplist = app.buttons["排行榜"]
        XCTAssertTrue(toplist.waitForExistence(timeout: 30), "侧栏未出现（非 iPad? 或在引导页）")
        toplist.tap()

        // 周期条 pill —— 之前这一步是不存在的
        let aYear = app.buttons["过去一年"]
        XCTAssertTrue(aYear.waitForExistence(timeout: 30), "排行榜页没有周期选择条")

        // 切换周期应当真的重排序（点一下不崩即可；网络数据由 App 自行加载）
        aYear.tap()
        sleep(3)
        XCTAssertTrue(app.buttons["昨天"].exists, "周期条切换后消失")
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
