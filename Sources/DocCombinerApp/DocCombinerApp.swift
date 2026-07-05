import SwiftUI

@main
struct DocCombinerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
