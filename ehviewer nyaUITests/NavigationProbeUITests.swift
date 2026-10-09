//
//  NavigationProbeUITests.swift
//  ehviewer nyaUITests
//
//  探针：走完引导进入主界面，观察首页是否有网络数据（决定行为测试是否可行）。
//

import XCTest

final class NavigationProbeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReachMainAndDumpHome() throws {
        let app = XCUIApplication()
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        // 18+ 警告 → 站点选择 → 登录页（以访客身份进入 → 二次确认）
        for label in ["我已满 18 岁，继续", "开始使用", "以访客身份浏览", "继续"] {
            let b = app.buttons[label]
            if b.waitForExistence(timeout: 6) { b.tap() }
        }

        let history = app.buttons["历史"]
        if !history.waitForExistence(timeout: 30) {
            print("UI_HIERARCHY_BEGIN\n\(app.debugDescription)\nUI_HIERARCHY_END")
            XCTFail("未能进入主界面")
            return
        }

        // 等首页网络数据落地
        sleep(30)
        print("HOME_CELLS=\(app.cells.count)")
        print("HOME_HIERARCHY_BEGIN\n\(app.debugDescription)\nHOME_HIERARCHY_END")
        XCTAssertTrue(history.exists)
    }
}
