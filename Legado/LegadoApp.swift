import SwiftUI

@main
struct LegadoApp: App {
    @StateObject private var store = BookSourceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
