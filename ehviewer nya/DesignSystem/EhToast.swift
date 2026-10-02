//
//  EhToast.swift
//  ehviewer nya
//
//  轻提示 — 对齐 Android BaseScene.showTip
//
//  收藏、下载这类动作在 Android 上都会弹一条 Toast（「已添加至收藏」
//  「已添加至下载列表」）。iOS 端此前只有一次触感反馈：动作其实执行了，
//  但屏幕上什么都不变，用起来就是「点了没反应」。
//
//  这里补一条浮在底部导航条上方的胶囊提示，2 秒后自动消失。
//

import SwiftUI

@Observable
@MainActor
final class EhToastCenter {
    static let shared = EhToastCenter()

    struct Toast: Equatable {
        enum Kind { case success, failure, info }
        let text: String
        let kind: Kind
        /// 同样的文字连续弹两次也要能重新计时，用序号区分
        let seq: Int
    }

    private(set) var current: Toast?
    private var seq = 0
    private var dismissTask: Task<Void, Never>?

    // MARK: - 提示层叠放

    /// 提示层（host）的注册次序。根视图和 sheet 各挂一个 host，
    /// 两个都画就会「同一条提示弹两次」。只让最后注册的那个（最上层）渲染。
    private var hostOrder: [UUID] = []

    /// 当前负责渲染的 host —— 叠在最上面的那个
    private(set) var topHostId: UUID?

    func registerHost(_ id: UUID) {
        if !hostOrder.contains(id) { hostOrder.append(id) }
        topHostId = hostOrder.last
    }

    func unregisterHost(_ id: UUID) {
        hostOrder.removeAll { $0 == id }
        topHostId = hostOrder.last
    }

    private init() {}

    func show(_ text: String, kind: Toast.Kind = .info) {
        seq += 1
        current = Toast(text: text, kind: kind, seq: seq)
        dismissTask?.cancel()
        let mySeq = seq
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.current?.seq == mySeq else { return }
            self.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// 便捷入口：`EhToast.success("已添加至收藏")`
enum EhToast {
    @MainActor static func success(_ text: String) {
        Haptics.success()
        EhToastCenter.shared.show(text, kind: .success)
    }

    @MainActor static func failure(_ text: String) {
        Haptics.error()
        EhToastCenter.shared.show(text, kind: .failure)
    }

    @MainActor static func info(_ text: String) {
        EhToastCenter.shared.show(text, kind: .info)
    }
}

private struct EhToastHost: ViewModifier {
    /// 距底部的边距。根视图上要让开浮起导航条；弹层（sheet）里没有导航条，
    /// 用小值即可，否则提示会浮到半空中。
    var bottomInset: CGFloat

    @State private var center = EhToastCenter.shared
    @State private var hostId = UUID()

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            // 只让最上层的 host 渲染：根视图与 sheet 各挂一个，
            // 都画的话同一条提示会在两处各弹一次。
            if center.topHostId == hostId, let toast = center.current {
                toastView(toast)
            }
        }
        // 提示是纯反馈，不该拦住下面的列表
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.current)
        .onAppear { center.registerHost(hostId) }
        .onDisappear { center.unregisterHost(hostId) }
    }

    private func toastView(_ toast: EhToastCenter.Toast) -> some View {
        HStack(spacing: 8) {
            if let symbol = symbol(for: toast.kind) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint(for: toast.kind))
            }
            Text(toast.text)
                .font(EhFont.caption)
                .foregroundStyle(EhColor.label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .ehLiquidGlass(in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .padding(.bottom, bottomInset)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onTapGesture { center.dismiss() }
        .allowsHitTesting(true)
    }

    private func symbol(for kind: EhToastCenter.Toast.Kind) -> String? {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: nil
        }
    }

    private func tint(for kind: EhToastCenter.Toast.Kind) -> Color {
        switch kind {
        case .success: EhColor.success
        case .failure: EhColor.danger
        case .info: EhColor.secondaryLabel
        }
    }
}

extension View {
    /// 挂在根视图上，全 App 共用一个提示层。
    ///
    /// sheet 是独立的呈现层，根视图上的提示层盖不住它 —— sheet 里若要弹提示，
    /// 得在该 sheet 的内容上再挂一个（同一个 `EhToastCenter`，不会重复显示）。
    func ehToastHost(
        bottomInset: CGFloat = EhSize.tabBarHeight + EhSize.tabBarBottomInset + 14
    ) -> some View {
        modifier(EhToastHost(bottomInset: bottomInset))
    }
}
