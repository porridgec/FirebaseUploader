import SwiftUI

@main
struct FirebaseUploaderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1060, height: 820)
        .windowResizability(.contentMinSize)
        // 禁用 File > New Window：多窗口会有各自独立的 AppModel，状态不同步却写同一份缓存
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
