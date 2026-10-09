//
//  RightDrawerOverlay.swift
//  ehviewer nya
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Right Drawer Overlay (对齐 Android EhDrawerLayout 右侧抽屉)

struct RightDrawerOverlay<DrawerContent: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let drawerContent: () -> DrawerContent

    private let drawerWidth: CGFloat = 280
    /// 实时拖拽偏移 (正值 = 向右拖, 负值 = 向左拖)
    @State private var dragOffset: CGFloat = 0
    /// 边缘拖拽进度 (0 = 关闭, 1 = 完全打开)
    @State private var edgeDragProgress: CGFloat = 0
    private let edgeSwipeWidth: CGFloat = 30

    /// 抽屉实际偏移量 (0 = 完全打开, drawerWidth = 完全关闭)
    private var currentOffset: CGFloat {
        if isOpen {
            // 打开状态: 向右拖拽关闭
            return max(0, dragOffset)
        } else {
            // 关闭状态: 边缘拖拽打开
            return drawerWidth * (1 - edgeDragProgress)
        }
    }

    /// 遮罩透明度
    private var overlayOpacity: Double {
        let progress = 1 - (currentOffset / drawerWidth)
        return Double(max(0, min(0.3, progress * 0.3)))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 半透明遮罩
            Color.black
                .opacity(overlayOpacity)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isOpen = false
                    }
                }
                .allowsHitTesting(isOpen || edgeDragProgress > 0)

            // ★ 懒加载抽屉内容: 仅在打开或拖拽时才渲染 drawerContent，避免每次父视图重渲染时创建 QuickSearchDrawerContent
            Group {
                if isOpen || edgeDragProgress > 0 {
                    drawerContent()
                } else {
                    Color.clear
                }
            }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .glassEffect(
                    .regular,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: EhRadius.control,
                        bottomLeadingRadius: EhRadius.control
                    )
                )
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: EhRadius.control,
                    bottomLeadingRadius: EhRadius.control
                ))
                .shadow(color: .black.opacity(overlayOpacity > 0.05 ? 0.15 : 0), radius: 8, x: -3)
                .offset(x: currentOffset)
                .gesture(
                    // 打开状态: 向右拖拽关闭
                    isOpen ?
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { value in
                            let translation = value.translation.width
                            if translation > 0 {
                                dragOffset = translation
                            }
                        }
                        .onEnded { value in
                            let velocity = value.predictedEndTranslation.width
                            if dragOffset > drawerWidth * 0.3 || velocity > 200 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    isOpen = false
                                }
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    dragOffset = 0
                                }
                            }
                            dragOffset = 0
                        }
                    : nil
                )

            // 右侧边缘滑动感应区 (关闭时: 从右向左滑动打开)
            if !isOpen {
                HStack {
                    Spacer()
                    Color.clear
                        .frame(width: edgeSwipeWidth)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                                .onChanged { value in
                                    let translation = -value.translation.width  // 向左为正
                                    if translation > 0 {
                                        edgeDragProgress = min(1, translation / drawerWidth)
                                    }
                                }
                                .onEnded { value in
                                    let velocity = -value.predictedEndTranslation.width
                                    if edgeDragProgress > 0.3 || velocity > 200 {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            isOpen = true
                                        }
                                    }
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                        edgeDragProgress = 0
                                    }
                                }
                        )
                }
            }
        }
        .onChange(of: isOpen) { _, newValue in
            dragOffset = 0
            edgeDragProgress = 0
        }
    }
}

extension View {
    /// 右侧抽屉修饰器 (对齐 Android EhDrawerLayout)
    func rightDrawer<Content: View>(isOpen: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        self.overlay {
            RightDrawerOverlay(isOpen: isOpen, drawerContent: content)
        }
    }
}

