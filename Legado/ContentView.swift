import SwiftUI

struct ContentView: View {
    @StateObject private var webViewPresenter = WebViewPresenter.shared

    var body: some View {
        TabView {
            NavigationStack {
                BookshelfView()
            }
            .tabItem {
                Label("书架", systemImage: "books.vertical.fill")
            }

            NavigationStack {
                SourceListView()
            }
            .tabItem {
                Label("书源", systemImage: "server.rack")
            }

            NavigationStack {
                MyView()
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
        }
        // startBrowserAwait 的 WebView 载体（起点 Cookie 验证等场景）
        .sheet(item: $webViewPresenter.request) { request in
            WebViewSheet(request: request)
        }
        .onAppear {
            // 桥的 WebView 呈现入口：JS 调 startBrowserAwait 时弹出 sheet
            JsJavaBridge.webViewPresenter = { url, title in
                WebViewPresenter.shared.present(url: url, title: title)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(BookSourceStore())
            .environmentObject(BookStore())
    }
}
