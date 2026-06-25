import SwiftUI

@main
struct AffectiveCoreAppleApp: App {
    @State private var model = BrainDashboardModel()

    init() {
        #if os(macOS)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                try DashboardSnapshot.write(to: CommandLine.arguments[index + 1])
                Foundation.exit(0)
            } catch {
                fputs("snapshot failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        #endif
    }
}
