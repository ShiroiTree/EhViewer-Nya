//
//  MacAppDelegate.swift
//  ehviewer nya
//
//  macOS App Delegate — 冷启动置顶 + 关闭窗口即退出
//

#if os(macOS)
import AppKit
import SwiftUI

/// 让窗口内容延伸到顶部工具栏之下，滚动内容才会进入工具栏背后，
/// 由系统在 macOS 26 下自动施加的 scroll edge effect 模糊。
///
/// 只设置 `fullSizeContentView`：**不要**再设 `titlebarAppearsTransparent`，
/// 那会把系统工具栏自身的毛玻璃底色一并关掉，反而变成实心。
struct WindowUnderToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.styleMask.insert(.fullSizeContentView) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.styleMask.insert(.fullSizeContentView) }
    }
}

class MacAppDelegate: NSObject, NSApplicationDelegate {

    /// 关闭最后一个窗口即退出应用，不留在 Dock
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 冷启动时强制把窗口抬到最前。
    /// 只在进程启动时跑一次，Cmd+N 新建的窗口不会重复抢焦点。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 激活被系统拒绝时（协作式激活），仍然把窗口本身提到最前
        window.orderFrontRegardless()
    }
}
#endif
