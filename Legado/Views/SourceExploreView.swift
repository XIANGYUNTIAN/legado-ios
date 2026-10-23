import SwiftUI
import SwiftSoup

// MARK: - 发现的书籍

struct ExploredBook: Identifiable {
    let id = UUID()
    let name: String
    let author: String
    let intro: String
    let bookUrl: String
    let coverUrl: String
    let lastChapter: String
}

// MARK: - 书源发现视图

/// 点击书源后进入：抓取 exploreUrl，按 ruleExplore 规则解析书籍列表，可一键加入书架。
/// 加入书架的书籍保留 sourceId + bookUrl，阅读时走规则阅读路径（目录/正文由书源规则驱动）。
struct SourceExploreView: View {
    let source: BookSource

    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore

    @State private var books: [ExploredBook] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var addedMessage: String?
    @State private var showDetail = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在发现书籍…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("发现失败", systemImage: "exclamation.triangle")
                } description: {
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if books.isEmpty {
                ContentUnavailableView(
                    "该书源没有发现内容",
                    systemImage: "magnifyingglass",
                    description: Text("检查书源是否配置了 exploreUrl 与 ruleExplore 规则")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(books) { book in
                    exploredRow(book)
                }
            }
        }
        .navigationTitle(source.bookSourceName.isEmpty ? "发现" : source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("规则") {
                    showDetail = true
                }
            }
        }
        .onAppear { load() }
        .sheet(isPresented: $showDetail) {
            SourceDetailView(source: source)
        }
        .alert("提示", isPresented: .constant(addedMessage != nil)) {
            Button("好") { addedMessage = nil }
        } message: {
            Text(addedMessage ?? "")
        }
    }

    private func exploredRow(_ book: ExploredBook) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !book.coverUrl.isEmpty, let coverURL = URL(string: book.coverUrl) {
                AsyncImage(url: coverURL)
                    .frame(width: 44, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Rectangle().fill(.quaternary)
                    .frame(width: 44, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !book.lastChapter.isEmpty {
                    Text("最新：\(book.lastChapter)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !book.intro.isEmpty {
                    Text(book.intro)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                addToShelf(book)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func addToShelf(_ book: ExploredBook) {
        let newBook = Book(
            id: UUID().uuidString,
            title: book.name,
            author: book.author.isEmpty ? "未知" : book.author,
            format: .txt,
            fileRelativePath: nil,
            remoteURL: book.bookUrl,
            addedAt: Date(),
            fileSize: nil,
            sourceId: source.bookSourceUrl,
            bookUrl: book.bookUrl
        )
        bookStore.addBook(newBook)
        addedMessage = "已加入书架：《\(book.name)》"
    }

    private func load() {
        guard !isLoading else { return }
        guard let exploreURL = URL(string: source.exploreUrl ?? "") else {
            errorMessage = "该书源未配置 exploreUrl"
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let html = try await NetworkService.shared.fetchText(from: exploreURL)
                let results = try extractExplore(html: html)
                await MainActor.run {
                    books = results
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func extractExplore(html: String) throws -> [ExploredBook] {
        guard let rules = source.ruleExplore else { return [] }
        let listRule = rules.bookList ?? ""
        guard listRule.hasPrefix("@css:") || listRule.hasPrefix("@@") else { return [] }
        let selector = stripCssPrefix(listRule)
        let document = try SwiftSoup.parse(html)
        let elements = try document.select(selector)

        let nameRule = rules.name ?? ""
        let authorRule = rules.author ?? ""
        let introRule = rules.intro ?? ""
        let bookUrlRule = rules.bookUrl ?? ""
        let coverRule = rules.coverUrl ?? ""
        let lastRule = rules.lastChapter ?? ""

        var result: [ExploredBook] = []
        for element in elements {
            let name = HtmlRuleEngine.extractValue(nameRule, on: element)
            guard !name.isEmpty else { continue }

            let bookUrl = HtmlRuleEngine.extractValue(bookUrlRule, on: element)
            let author = HtmlRuleEngine.extractValue(authorRule, on: element)
            let intro = HtmlRuleEngine.extractValue(introRule, on: element)
            let cover = HtmlRuleEngine.extractValue(coverRule, on: element)
            let last = HtmlRuleEngine.extractValue(lastRule, on: element)

            result.append(ExploredBook(
                name: name, author: author, intro: intro,
                bookUrl: bookUrl, coverUrl: cover, lastChapter: last
            ))
        }
        return result
    }

    private func stripCssPrefix(_ rule: String) -> String {
        var body = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("@css:") {
            body = String(body.dropFirst(5))
        } else if body.hasPrefix("@@") {
            body = String(body.dropFirst(2))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

