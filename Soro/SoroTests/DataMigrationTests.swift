import XCTest
@testable import Soro

/// Covers the pure decision logic for the first-launch Whispaa → Soro data
/// migration. `shouldMigrate` must return true only when the old directory
/// exists and the new one does not.
final class DataMigrationTests: XCTestCase {
    func testMigratesWhenOldExistsAndNewMissing() {
        XCTAssertTrue(DataMigration.shouldMigrate(oldExists: true, newExists: false))
    }

    func testDoesNotMigrateWhenNewAlreadyExists() {
        XCTAssertFalse(DataMigration.shouldMigrate(oldExists: true, newExists: true))
    }

    func testDoesNotMigrateWhenOldMissing() {
        XCTAssertFalse(DataMigration.shouldMigrate(oldExists: false, newExists: false))
        XCTAssertFalse(DataMigration.shouldMigrate(oldExists: false, newExists: true))
    }
}
