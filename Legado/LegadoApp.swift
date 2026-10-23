import SwiftUI

@main
struct LegadoApp: App {
    @StateObject private var store = BookSourceStore()
    @StateObject private var bookStore = BookStore()
    @StateObject private var settings = ReaderSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(bookStore)
                .environmentObject(settings)
        }
    }
}
