//
//  GalleryFilterTests.swift
//  ehviewer nyaTests
//
//  过滤规则此前**从来没有被应用过**：FilterView 能增删改查，记录也写进了
//  数据库，但整个项目没有任何地方读它们——「屏蔽这个标签」点完，被屏蔽的
//  画廊照常出现在列表里。这组测试守住两件事：规则能匹配对，以及匹配的
//  边界（命名空间）不能放宽或收紧。
//

import Testing
import EhModels
@testable import ehviewer_nya

@MainActor
struct GalleryFilterTests {

    // MARK: - 标签匹配（对齐 Android EhFilter.matchTag）

    /// 裸标签能挡住任何命名空间下的同名标签
    @Test func bareFilterMatchesNamespacedTag() {
        #expect(GalleryFilterEngine.tagMatches("female:big ass", "big ass"))
        #expect(GalleryFilterEngine.tagMatches("male:big ass", "big ass"))
    }

    /// 带命名空间的规则只挡同一命名空间
    @Test func namespacedFilterOnlyMatchesSameNamespace() {
        #expect(GalleryFilterEngine.tagMatches("female:big ass", "female:big ass"))
        #expect(!GalleryFilterEngine.tagMatches("male:big ass", "female:big ass"))
    }

    /// 标签名必须完全相等，不做子串匹配 —— 否则 `ass` 会顺手挡掉 `big ass`
    @Test func tagNameMustMatchExactly() {
        #expect(!GalleryFilterEngine.tagMatches("female:big ass", "ass"))
        #expect(!GalleryFilterEngine.tagMatches("female:bigass", "big ass"))
    }

    /// 裸标签对裸标签
    @Test func bareToBare() {
        #expect(GalleryFilterEngine.tagMatches("translated", "translated"))
        #expect(!GalleryFilterEngine.tagMatches("translated", "translate"))
    }
}

/// `galleries` 的原地修改此前会崩：`append` / 下标赋值走 `_modify` 访问器，
/// didSet 在独占访问结束前触发，里面再 `&galleries` 写回就是嵌套写，命中
/// Swift 独占访问检查（EXC_BREAKPOINT，栈顶 `_galleries.didset`）。
/// 这条守住翻页 append 与收藏标记下标赋值这两条路径。
@MainActor
struct GalleryListViewModelMutationTests {
    @Test func appendAndSubscriptDoNotCrash() {
        let vm = GalleryListViewModel()
        let a = GalleryInfo(gid: 1, token: "aaa")
        let b = GalleryInfo(gid: 2, token: "bbb")
        let c = GalleryInfo(gid: 3, token: "ccc")

        vm.galleries = [a, b]
        #expect(vm.galleries.map(\.gid) == [1, 2])

        vm.galleries.append(c)
        #expect(vm.galleries.map(\.gid) == [1, 2, 3])

        vm.galleries[0].favoriteSlot = 3
        #expect(vm.galleries[0].favoriteSlot == 3)
    }
}
