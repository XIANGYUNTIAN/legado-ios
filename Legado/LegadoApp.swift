import SwiftUI

@main
struct LegadoApp: App {
    @StateObject private var store = BookSourceStore()
    @StateObject private var bookStore = BookStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(bookStore)
        }
    }
}
