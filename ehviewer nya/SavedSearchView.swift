//
//  SavedSearchView.swift
//  ehviewer nya
//
//  已保存搜索 — 把当前查询（任意标签组合，或上传者搜索）存成命名条目，
//  以后一键复用。
//
//  与「快速搜索」的区别：快速搜索存的是带分类/评分条件的搜索；
//  这里存的是用户从任意一次查询里收藏下来的**完整 term 列表**，
//  尤其是上传者——它不是一个标签，没法靠标签系统复用。
//

import SwiftUI
import EhModels
import EhDatabase

@Observable
class SavedSearchViewModel {
    var searches: [SavedSearchRecord] = []

    func loadSearches() {
        do {
            searches = try EhDatabase.shared.getAllSavedSearches()
        } catch {
            debugLog("Failed to load saved searches: \(error)")
        }
    }

    func add(name: String, query: SearchQuery) {
        do {
            let json = query.jsonString
            // 去重：同一查询已存在就先删旧行，避免重复条目
            for existing in searches where existing.query == json {
                if let id = existing.id {
                    try? EhDatabase.shared.deleteSavedSearch(id: id)
                }
            }
            try EhDatabase.shared.insertSavedSearch(
                SavedSearchRecord(name: name, query: json)
            )
            loadSearches()
        } catch {
            debugLog("Failed to add saved search: \(error)")
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            guard let id = searches[index].id else { continue }
            do {
                try EhDatabase.shared.deleteSavedSearch(id: id)
            } catch {
                debugLog("Failed to delete saved search: \(error)")
            }
        }
        searches.remove(atOffsets: offsets)
    }

    /// 删除单条（供右键菜单用：macOS 上滑动删除不好发现）
    func delete(_ record: SavedSearchRecord) {
        guard let id = record.id else { return }
        do {
            try EhDatabase.shared.deleteSavedSearch(id: id)
        } catch {
            debugLog("Failed to delete saved search: \(error)")
        }
        searches.removeAll { $0.id == record.id }
    }
}

struct SavedSearchView: View {
    /// 当前列表的查询，用于「保存当前搜索」。
    let currentQuery: SearchQuery
    /// 选中一条已保存搜索时回调（由调用方负责关闭并执行）。
    let onRun: (SearchQuery) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm = SavedSearchViewModel()
    @State private var showSavePrompt = false
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Group {
                if vm.searches.isEmpty {
                    EhStateView(kind: .empty(
                        symbol: "bookmark",
                        title: "还没有保存的搜索",
                        message: "把常用的搜索条件（含上传者）存下来，以后一点即用"
                    ))
                } else {
                    List {
                        ForEach(vm.searches) { record in
                            Button {
                                run(record)
                            } label: {
                                row(record)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", role: .destructive) { vm.delete(record) }
                            }
                        }
                        .onDelete { vm.delete(at: $0) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("已保存搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        draftName = currentQuery.render()
                        showSavePrompt = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(currentQuery.isEmpty)
                }
            }
            .alert("保存当前搜索", isPresented: $showSavePrompt) {
                TextField("名称", text: $draftName)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    vm.add(name: name.isEmpty ? currentQuery.render() : name, query: currentQuery)
                }
            } message: {
                Text(currentQuery.render())
            }
            .task { vm.loadSearches() }
        }
    }

    private func row(_ record: SavedSearchRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.name)
                .font(EhFont.body)
                .foregroundStyle(EhColor.label)
            if let query = SearchQuery.from(jsonString: record.query) {
                Text(query.render())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EhColor.secondaryLabel)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func run(_ record: SavedSearchRecord) {
        guard let query = SearchQuery.from(jsonString: record.query) else { return }
        onRun(query)
    }
}

#Preview {
    SavedSearchView(currentQuery: SearchQuery(terms: [.makeUploader("rrr1361")]), onRun: { _ in })
}
