import SwiftUI

#if os(macOS)
import AppKit

@MainActor
enum DashboardSnapshot {
    static func write(to path: String) throws {
        let model = BrainDashboardModel.snapshotDefaultBrain()
        let view = DashboardView(model: model)
            .frame(width: 1180, height: 920)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1180, height: 920)
        hostingView.wantsLayer = true
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.renderFailed
        }
        bitmap.size = hostingView.bounds.size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed
        }

        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

enum SnapshotError: Error {
    case renderFailed
    case encodeFailed
}
#endif
