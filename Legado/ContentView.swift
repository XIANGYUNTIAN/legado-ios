import SwiftUI

struct ContentView: View {
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
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(BookSourceStore())
    }
}
