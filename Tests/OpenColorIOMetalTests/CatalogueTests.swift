import Foundation
import XCTest
@testable import OpenColorIOMetal

final class CatalogueTests: XCTestCase {
    func testPinnedCompleteArchive() throws {
        let catalogue = try OCIOCatalogue.bundled()
        XCTAssertEqual(catalogue.upstream.commit, "5a808fb57a94c7229640a97835c420c9a1fbd1fe")
        XCTAssertEqual(catalogue.configurations.count, 8)
        XCTAssertGreaterThan(catalogue.builtins.count, 50)
        try catalogue.validateResources()
        for config in catalogue.configurations {
            XCTAssertEqual(config.conversions.count, config.colorSpaces.count * config.colorSpaces.count, config.id)
            for source in config.colorSpaces {
                for destination in config.colorSpaces {
                    let conversion = try config.conversion(source: source.name, destination: destination.name)
                    for transform in conversion.pipeline { _ = try catalogue.transform(transform) }
                }
                for alias in source.aliases { XCTAssertEqual(try config.colorSpace(named: alias).name, source.name) }
            }
            for (role, target) in config.roleAliases { XCTAssertEqual(try config.colorSpace(named: role).name, target) }
        }
    }
}
