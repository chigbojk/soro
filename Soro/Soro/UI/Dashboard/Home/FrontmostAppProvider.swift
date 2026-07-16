import SwiftUI
import AppKit

/// Resolves the current frontmost application and a small set of running-app icons
/// for the Home header accent (Willow-style "dictate on <App>" with app icons).
///
/// Purely presentational. Fails gracefully: if nothing resolves the header simply
/// shows no icons and a neutral app name.
@MainActor
final class FrontmostAppProvider: ObservableObject {
    /// Display name of the frontmost app, or nil when it can't be resolved
    /// (e.g. our own app is frontmost, or during headless test runs).
    @Published var frontmostName: String?

    /// A few tasteful running-app icons to show as an accent (deduped, our own app excluded).
    @Published var icons: [AppIcon] = []

    struct AppIcon: Identifiable {
        let id: String        // bundle id
        let image: NSImage
    }

    private var timer: Timer?

    func start() {
        refresh()
        // Light polling so the header stays current while the dashboard is open.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let workspace = NSWorkspace.shared
        let ownBundleId = Bundle.main.bundleIdentifier

        // Frontmost app name (skip our own app so the header reads naturally).
        if let front = workspace.frontmostApplication,
           front.bundleIdentifier != ownBundleId,
           let name = front.localizedName {
            frontmostName = name
        }

        // Collect up to 3 regular (dock-visible) running apps' icons.
        var seen = Set<String>()
        var collected: [AppIcon] = []
        for app in workspace.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleId = app.bundleIdentifier,
                  bundleId != ownBundleId,
                  !seen.contains(bundleId),
                  let icon = app.icon else { continue }
            seen.insert(bundleId)
            collected.append(AppIcon(id: bundleId, image: icon))
            if collected.count == 3 { break }
        }
        if !collected.isEmpty {
            icons = collected
        }
    }
}
