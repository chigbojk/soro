import Foundation
import XCTest
@testable import Soro

/// Creates a unique temp `AppPaths` root for a test and cleans it up.
func makeTempPaths() -> AppPaths {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoroTests-\(UUID().uuidString)", isDirectory: true)
    let paths = AppPaths(root: dir)
    paths.ensureDirectories()
    return paths
}

func removeTemp(_ paths: AppPaths) {
    try? FileManager.default.removeItem(at: paths.root)
}

/// Reads a JSON file back as a `[String: Any]` so tests can assert on raw keys.
func rawJSON(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
