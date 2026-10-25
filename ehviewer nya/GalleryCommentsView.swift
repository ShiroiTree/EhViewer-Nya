//
//  GalleryCommentsView.swift
//  ehviewer nya
//
//  评论列表页面 (对齐 Android GalleryCommentsScene)
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct GalleryCommentsView: View {
    let gid: Int64
    let token: String
    let apiUid: Int64
    let apiKey: String
    let initialComments: [GalleryComment]
    let hasMore: Bool

    @State private var vm = GalleryCommentsViewModel()
    @State private var composing: CommentComposeTarget?
    /// 评论里点开的站内画廊（iOS 直接推入当前导航栈；macOS 走通知选中详情列）
    @State private var linkedGallery: GalleryInfo?

    /// 未登录时不显示发表入口 —— 点了也只会拿到服务端的拒绝
    private var canComment: Bool { AppSettings.shared.isLogin }

    private var galleryUrl: String {
        "\(GalleryActionService.siteBaseURL)g/\(gid)/\(token)/"
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(vm.comments.enumerated()), id: \.offset) { idx, comment in
                    commentRow(comment)
                    
                    if idx < vm.comments.count - 1 {
                        Divider()
                            .padding(.leading)
                    }
                }
                
                // 加载更多
                if vm.hasMore {
                    Button {
                        Task { await vm.loadAllComments(gid: gid, token: token) }
                    } label: {
                        HStack {
                            if vm.isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(vm.isLoading ? "加载中..." : "加载全部评论")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .disabled(vm.isLoading)
                }
            }
        }
        .navigationTitle("评论 (\(vm.comments.count)\(vm.hasMore ? "+" : ""))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $linkedGallery) { gallery in
            GalleryDetailView(gallery: gallery).id(gallery.gid)
        }
        #endif
        .onAppear {
            vm.setInitialComments(initialComments, hasMore: hasMore)
        }
        .toolbar {
            if canComment {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        composing = CommentComposeTarget(comment: nil)
                    } label: {
                        Label("发表评论", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .sheet(item: $composing) { target in
            CommentComposerView(
                gid: gid,
                token: token,
                galleryUrl: galleryUrl,
                editing: target.comment,
                apiUid: apiUid,
                apiKey: apiKey,
                onPosted: { list in
                    vm.setInitialComments(list.comments, hasMore: list.hasMore)
                }
            )
        }
    }
    
    // MARK: - 单条评论
    
    private func commentRow(_ comment: GalleryComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：用户名、上传者徽标、时间、分数
            HStack(spacing: 8) {
                Text(PlaceholderMode.isEnabled ? PlaceholderMode.uploader(comment.user) : comment.user)
                    .font(EhFont.body.weight(.semibold))
                    .foregroundStyle(EhColor.label)

                // 上传者本人的评论单独标出来：同一串评论里，作者的说明
                // （补图、修正、致歉）和读者的闲聊分量完全不同。
                // 服务端不单独下发标记，但上传者评论的 id 固定为 0（也因此不可投票）。
                if comment.id == 0 {
                    Text("上传者")
                        .font(EhFont.footnote.weight(.semibold))
                        .foregroundStyle(EhColor.onAccentFill)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(EhColor.accentFill))
                }

                Spacer(minLength: 4)

                Text(comment.time, style: .date)
                    .font(EhFont.mono(11))
                    .foregroundStyle(EhColor.tertiaryLabel)

                if comment.score != 0 {
                    Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                        .font(EhFont.mono(12, weight: .semibold))
                        .foregroundStyle(comment.score > 0 ? EhColor.success : EhColor.danger)
                }
            }

            // 评论内容 (HTML 转富文本，完整显示，链接可点)
            if PlaceholderMode.isEnabled {
                Text(PlaceholderMode.comment("\(comment.user):\(comment.id)"))
                    .font(EhFont.body)
                    .foregroundStyle(EhColor.label)
            } else {
                CommentBodyView(html: comment.comment, font: EhFont.body) { gallery in
                    openLinkedGallery(gallery)
                }
            }
            
            // 投票 / 编辑
            if comment.voteUpAble || comment.voteDownAble || comment.editable {
                HStack(spacing: 16) {
                    // editable 由服务端下发 —— 只有自己的评论才有
                    if comment.editable {
                        Button {
                            composing = CommentComposeTarget(comment: comment)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if comment.voteUpAble {
                        Button {
                            Task {
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: 1
                                )
                            }
                        } label: {
                            Label("赞同", systemImage: comment.voteUpEd ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    if comment.voteDownAble {
                        Button {
                            Task {
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: -1
                                )
                            }
                        } label: {
                            Label("反对", systemImage: comment.voteDownEd ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            // 编辑信息
            if let lastEdited = comment.lastEdited {
                Text("最后编辑: \(lastEdited, style: .date)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        // 长按菜单（对齐 Android GalleryCommentsScene 的 copy_comment_text /
        // join_blacklist）。此前评论行只有投票和编辑按钮，想复制一段评论
        // 或者屏蔽一个反复刷屏的人，都没有出口。
        .contextMenu {
            Button {
                #if os(iOS)
                UIPasteboard.general.string = Self.plainText(comment.comment)
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.plainText(comment.comment), forType: .string)
                #endif
                EhToast.success("已复制评论")
            } label: {
                Label("复制评论内容", systemImage: "doc.on.doc")
            }

            if !comment.user.isEmpty {
                Button(role: .destructive) {
                    blockCommenter(comment.user)
                } label: {
                    Label("屏蔽「\(comment.user)」", systemImage: "person.slash")
                }
            }
        }
    }

    /// 打开评论里的站内画廊链接。
    ///
    /// macOS 的详情列与列表列是两个独立的导航栈，推入当前栈会在详情列里套一层
    /// 详情；交给全 App 统一的通知，等同于从剪贴板打开画廊——直接换掉详情列的
    /// 内容。iOS 没有这层分栏，推入当前栈才是正常的详情页交互。
    private func openLinkedGallery(_ gallery: GalleryInfo) {
        #if os(macOS)
        NotificationCenter.default.post(
            name: .openGalleryDetail,
            object: nil,
            userInfo: ["gid": gallery.gid, "token": gallery.token]
        )
        #else
        linkedGallery = gallery
        #endif
    }

    /// 复制时给纯文本，不给 HTML —— 评论正文在模型里是带标签的原始 HTML，
    /// 直接贴出去是一串 <br> 和 <a href>。
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把评论者加进过滤器。
    /// mode 1 = 上传者过滤，与 FilterView 里那一类是同一套（评论者用的也是
    /// E-Hentai 的用户名，和上传者同一个命名空间）。
    private func blockCommenter(_ user: String) {
        do {
            try EhDatabase.shared.insertFilter(
                FilterRecord(mode: 1, text: user, enable: true)
            )
            EhToast.success("已屏蔽「\(user)」")
        } catch {
            EhToast.failure("屏蔽失败")
            debugLog("[Comments] 屏蔽评论者失败: \(error)")
        }
    }
}

// MARK: - ViewModel

@Observable
class GalleryCommentsViewModel {
    var comments: [GalleryComment] = []
    var hasMore = false
    var isLoading = false
    var errorMessage: String?
    
    func setInitialComments(_ comments: [GalleryComment], hasMore: Bool) {
        self.comments = comments
        self.hasMore = hasMore
    }
    
    func loadAllComments(gid: Int64, token: String) async {
        // 占位符模式：初始评论已是合成的完整列表，不再联网
        if PlaceholderMode.isEnabled { return }
        guard !isLoading else { return }
        isLoading = true
        
        do {
            let result = try await EhAPI.shared.getAllComments(gid: gid, token: token)
            
            await MainActor.run {
                self.comments = result.comments
                self.hasMore = result.hasMore
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 评论投票 — 连通 EhAPI.voteComment (对齐 Android GalleryCommentsScene.voteComment)
    func voteComment(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String,
        commentId: Int64, vote: Int
    ) async {
        do {
            let result = try await EhAPI.shared.voteComment(
                apiUid: apiUid, apiKey: apiKey,
                gid: gid, token: token,
                commentId: commentId, commentVote: vote
            )
            // 更新本地评论状态
            await MainActor.run {
                if let idx = comments.firstIndex(where: { $0.id == commentId }) {
                    comments[idx].score = result.score
                    // vote == 1 → 用户点赞; vote == -1 → 用户点踩
                    // result.vote: 服务端返回的最终投票状态 (1 = 已赞, -1 = 已踩, 0 = 取消)
                    comments[idx].voteUpEd = result.vote == 1
                    comments[idx].voteDownEd = result.vote == -1
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
            }
        }
    }
}



// MARK: - 评论正文 (链接识别与点击)

/// 评论正文渲染 — 把评论 HTML 里的链接变成可点击的富文本。
///
/// 站内详情页链接交给 `onOpenGallery` 走导航；站内其它链接（标签页、用户页、
/// 论坛等）与无法解析的链接弹「链接解析错误」；站外链接先确认，再交给系统浏览器。
struct CommentBodyView: View {
    let html: String
    var font: Font = EhFont.body
    var lineLimit: Int?
    let onOpenGallery: (GalleryInfo) -> Void

    @State private var alert: LinkAlert?

    var body: some View {
        Text(CommentRichText.attributed(for: html))
            .font(font)
            .foregroundStyle(EhColor.label)
            .lineLimit(lineLimit)
            // 接管 Text 内链接的点击，避免站内链接被交给系统浏览器
            .environment(\.openURL, OpenURLAction { url in
                handle(url)
                return .handled
            })
            .alert(
                alert?.title ?? "",
                isPresented: Binding(
                    get: { alert != nil },
                    set: { if !$0 { alert = nil } }
                ),
                presenting: alert
            ) { current in
                if current.isExternal {
                    Button("打开") { openInBrowser(current.url) }
                }
                Button(current.isExternal ? "取消" : "好", role: .cancel) {}
            } message: { current in
                Text(current.message)
            }
    }

    private func handle(_ url: URL) {
        switch CommentLinkResolver.resolve(url) {
        case .gallery(let gid, let token):
            onOpenGallery(GalleryInfo(gid: gid, token: token))
        case .invalidInternal:
            alert = .parseError(url)
        case .external:
            alert = .external(url)
        }
    }

    private func openInBrowser(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private struct LinkAlert {
        let url: URL
        let isExternal: Bool

        static func external(_ url: URL) -> LinkAlert { .init(url: url, isExternal: true) }
        static func parseError(_ url: URL) -> LinkAlert { .init(url: url, isExternal: false) }

        var title: String { isExternal ? "打开外部链接？" : "链接解析错误" }
        var message: String {
            isExternal
                ? url.absoluteString
                : "该链接指向站内，但不是有效的画廊详情页。\n\(url.absoluteString)"
        }
    }
}

// MARK: - 链接分类

enum CommentLinkResolution {
    case gallery(gid: Int64, token: String)
    /// 指向站内，但不是 `/g/<gid>/<token>/` 形式的详情页
    case invalidInternal
    case external
}

enum CommentLinkResolver {
    /// 与 RootView 的剪贴板检测使用同一套画廊 URL 规则：
    /// `https://e-hentai.org/g/<gid>/<10 位十六进制 token>/`
    static func resolve(_ url: URL) -> CommentLinkResolution {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .external }

        let host = url.host?.lowercased() ?? ""
        let isInternal = host == "e-hentai.org" || host == "exhentai.org"
            || host.hasSuffix(".e-hentai.org") || host.hasSuffix(".exhentai.org")
        guard isInternal else { return .external }

        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[0].lowercased() == "g",
              let gid = Int64(parts[1]), gid > 0,
              parts[2].count == 10,
              parts[2].allSatisfy({ $0.isHexDigit }) else {
            return .invalidInternal
        }
        return .gallery(gid: gid, token: String(parts[2]).lowercased())
    }
}

// MARK: - HTML → AttributedString

/// 评论 HTML 只用到很窄的一组标签：`<a>`、`<br>`，偶尔有 `<p>` / `<blockquote>`。
/// 走 WebKit/NSAttributedString 的 HTML 导入太重，这里直接按标签切开自己拼。
enum CommentRichText {
    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// 评论行会随滚动、投票、编辑反复求值，同一段 HTML 不重复解析。
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        return cache
    }()

    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let hrefRegex = try! NSRegularExpression(
        pattern: #"(?i)\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    )
    private static let numericEntityRegex = try! NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);")
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func attributed(for html: String) -> AttributedString {
        let key = html as NSString
        if let boxed = cache.object(forKey: key) { return boxed.value }
        let value = build(html)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func build(_ html: String) -> AttributedString {
        var result = AttributedString()
        var activeLink: URL?
        let source = html as NSString
        var cursor = 0

        for match in tagRegex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor {
                let chunk = source.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                append(decoded(chunk), link: activeLink, to: &result)
            }

            let rawTag = source.substring(with: match.range)
            let tag = rawTag.lowercased()
            if tag.hasPrefix("</a") {
                activeLink = nil
            } else if isAnchorOpen(tag) {
                activeLink = href(from: rawTag)
            } else if isLineBreakTag(tag) {
                append("\n", link: nil, to: &result)
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < source.length {
            append(decoded(source.substring(from: cursor)), link: activeLink, to: &result)
        }
        return result
    }

    private static func isAnchorOpen(_ tag: String) -> Bool {
        guard tag.hasPrefix("<a") else { return false }
        let rest = tag.dropFirst(2)
        return rest.isEmpty || rest.first == ">" || rest.first?.isWhitespace == true
    }

    private static func isLineBreakTag(_ tag: String) -> Bool {
        if tag.hasPrefix("<br") { return true }
        if tag.hasPrefix("<p>") || tag.hasPrefix("<p ") || tag.hasPrefix("</p") { return true }
        if tag.hasPrefix("<div") || tag.hasPrefix("</div") { return true }
        if tag.hasPrefix("<blockquote") || tag.hasPrefix("</blockquote") { return true }
        return false
    }

    private static func href(from tag: String) -> URL? {
        let source = tag as NSString
        guard let match = hrefRegex.firstMatch(
            in: tag, range: NSRange(location: 0, length: source.length)
        ) else { return nil }

        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { continue }
            let raw = decoded(source.substring(with: range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedURL(raw)
        }
        return nil
    }

    /// 只接受能在系统里打开的链接；`javascript:` 之类一律不变成链接。
    private static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        var string = raw
        let hasScheme = string.range(
            of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression
        ) != nil

        if string.hasPrefix("//") {
            string = "https:" + string
        } else if !hasScheme {
            if string.hasPrefix("/") {
                // 站内相对路径（评论 HTML 里少见）按 E-Hentai 解析，
                // 交给 CommentLinkResolver 判定是否为详情页
                string = "https://e-hentai.org" + string
            } else {
                guard string.contains(".") else { return nil }
                string = "https://" + string
            }
        }

        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return url
    }

    /// 一段普通文本：先识别裸 URL，再按识别结果切成可点/不可点的片段。
    private static func append(_ text: String, link: URL?, to result: inout AttributedString) {
        guard !text.isEmpty else { return }
        if let link {
            append(text, url: link, to: &result)
            return
        }
        guard let detector = linkDetector else {
            result += AttributedString(text)
            return
        }

        let source = text as NSString
        let matches = detector.matches(
            in: text, range: NSRange(location: 0, length: source.length)
        )
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += AttributedString(source.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                ))
            }
            let matched = source.substring(with: match.range)
            if let detected = match.url, let url = normalizedURL(detected.absoluteString) {
                append(matched, url: url, to: &result)
            } else {
                result += AttributedString(matched)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            result += AttributedString(source.substring(from: cursor))
        }
    }

    private static func append(_ text: String, url: URL, to result: inout AttributedString) {
        var part = AttributedString(text)
        part.link = url
        part.foregroundColor = EhColor.accent
        result += part
    }

    private static let namedEntities: [(String, String)] = [
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"), ("&amp;", "&")
    ]

    /// 只解一层实体：`&amp;#039;` 是用户字面输入的 `&#039;`，不该再解成引号。
    /// 先解数字实体，再解命名实体，否则 `&amp;lt;` 会被连着解两次。
    private static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var work = text as NSString

        let matches = numericEntityRegex.matches(
            in: work as String, range: NSRange(location: 0, length: work.length)
        )
        for match in matches.reversed() {
            let token = work.substring(with: match.range(at: 1))
            let value: UInt32? = token.hasPrefix("x") || token.hasPrefix("X")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token)
            let replacement = value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
                ?? work.substring(with: match.range)
            work = work.replacingCharacters(in: match.range, with: replacement) as NSString
        }

        var string = work as String
        for (entity, replacement) in namedEntities {
            string = string.replacingOccurrences(of: entity, with: replacement)
        }
        return string
    }
}

#Preview {
    NavigationStack {
        GalleryCommentsView(
            gid: 12345,
            token: "abc123",
            apiUid: -1,
            apiKey: "",
            initialComments: [],
            hasMore: true
        )
    }
}
