//
//  MacPageReader.swift
//  ehviewer nya
//
//  macOS 原生翻页器的 SwiftUI 包装（仅 macOS）。
//  把 AppKit 的 MacPageReaderView 暴露成声明式接口，供 ImageReaderView 在
//  macOS 分支使用。仅在「内容签名」变化时下发 configure，避免 SwiftUI 的
//  高频 updateNSView 触发无谓的换页/重置缩放。
//

#if os(macOS)

import SwiftUI
import AppKit

/// macOS 原生图片阅读面。
///
/// 一次呈现一「展」（单页或双页），并额外下发前后相邻展用于预渲染，
/// 由 `MacPageReaderView` 内部完成滑动翻页与缩放。
struct MacPageReader: NSViewRepresentable {

    let current: MacSpreadContent
    let next: MacSpreadContent?
    let prev: MacSpreadContent?
    let scaleMode: ScaleMode
    let startPosition: StartPosition
    let direction: ReadingDirection
    let isDoublePage: Bool
    let topInset: CGFloat

    var onTurn: ((Bool) -> Void)?
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastSignature: String?
    }

    func makeNSView(context: Context) -> MacPageReaderView {
        let view = MacPageReaderView(frame: .zero)
        view.topInset = topInset
        view.onTurn = onTurn
        view.onSingleTap = onSingleTap
        view.onZoomChanged = onZoomChanged
        return view
    }

    func updateNSView(_ nsView: MacPageReaderView, context: Context) {
        nsView.topInset = topInset
        // 回调每次都更新，保证闭包捕获的是最新状态
        nsView.onTurn = onTurn
        nsView.onSingleTap = onSingleTap
        nsView.onZoomChanged = onZoomChanged

        let signature = MacPageReaderView.makeSignature(
            current: current, next: next, prev: prev, scaleMode: scaleMode,
            direction: direction, isDoublePage: isDoublePage
        )
        guard context.coordinator.lastSignature != signature else { return }
        context.coordinator.lastSignature = signature

        nsView.configure(
            current: current, next: next, prev: prev,
            scaleMode: scaleMode, startPosition: startPosition,
            direction: direction, isDoublePage: isDoublePage
        )
    }
}

#endif
