import SwiftUI

@main
struct LegadoApp: App {
    @StateObject private var store = BookSourceStore()
    @StateObject private var bookStore = BookStore()
    @StateObject private var settings = ReaderSettings.shared
    @StateObject private var shelfSettings = BookshelfSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(bookStore)
                .environmentObject(settings)
                .environmentObject(shelfSettings)
        }
    }
}
