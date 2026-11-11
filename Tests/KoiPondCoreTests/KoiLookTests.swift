import XCTest
@testable import KoiPondCore

final class KoiLookTests: XCTestCase {
    func testOnlyTheOgonIsMetallic() {
        for variety in KoiVariety.allCases {
            for (i, design) in variety.designs.enumerated() {
                XCTAssertEqual(design.metallic, variety == .ogon ? 1 : 0, "\(variety) design \(i)")
            }
        }
    }

    func testFinMarkingsFollowTheVarieties() {
        for design in KoiVariety.showa.designs { XCTAssertEqual(design.fins, .blackRoots) }
        for design in KoiVariety.sanke.designs { XCTAssertEqual(design.fins, .blackStripes) }
        XCTAssertEqual(KoiVariety.shiroUtsuri.look.fins, .blackRoots)
        XCTAssertEqual(KoiVariety.asagi.look.fins, .redRoots)
        XCTAssertEqual(KoiVariety.kohaku.look.fins, .plain)
    }

    func testYellowKoiStayWarm() {
        // Gold and lemon need little blue, or they shade towards olive on the teal water.
        for variety in [KoiVariety.ogon, .kigoi] {
            let c = variety.look.base
            XCTAssertGreaterThan(c.x - c.z, 0.6, "\(variety)")
            XCTAssertGreaterThanOrEqual(c.x, c.y, "\(variety)")
        }
        XCTAssertTrue(KoiVariety.kigoi.look.redEyes)
    }

    func testEveryVarietyHasADesignAndTheBigOnesSeveral() {
        for variety in KoiVariety.allCases { XCTAssertFalse(variety.designs.isEmpty, "\(variety)") }
        XCTAssertEqual(KoiVariety.kohaku.designs.count, 7)
        for variety in [KoiVariety.ogon, .kigoi, .chagoi] { XCTAssertEqual(variety.designs.count, 4, "\(variety)") }
        XCTAssertEqual(KoiVariety.benigoi.designs.count, 3)
    }

    func testNoKoiIsOneFlatColour() {
        // One-coloured koi are the plain ones: every design needs patches, a marking or a scale finish.
        for variety in KoiVariety.allCases {
            for (i, d) in variety.designs.enumerated() {
                let patterned = d.patchThreshold < 1 || d.accentThreshold < 1 || d.special > 0 || d.pattern != .noise
                XCTAssertTrue(patterned || d.scales != .plain, "\(variety) design \(i) is a single flat colour")
            }
        }
    }

    func testAPondDealsEachVarietysDesignsInTurn() {
        let pond = Pond(size: [1512, 982], seed: 11)
        pond.configure(PondConfig(koiCount: 60))
        for variety in KoiVariety.allCases {
            let worn = pond.koi.filter { $0.variety == variety }.map(\.design)
            let count = variety.designs.count
            XCTAssertTrue(worn.allSatisfy { $0 < count }, "\(variety)")
            // The first fish of a variety each wear a different design, until the designs run out.
            XCTAssertEqual(Set(worn.prefix(count)).count, min(worn.count, count), "\(variety)")
            for (a, b) in zip(worn, worn.dropFirst()) { XCTAssertEqual(b, (a + 1) % count, "\(variety)") }
        }
    }

    func testABorrowedKoiKeepsItsDesign() {
        let pond = Pond(size: [1512, 982], seed: 4)
        pond.configure(PondConfig(koiCount: 12))
        guard let borrowed = pond.borrowKoi(near: [756, 491]), let fish = pond.koi.first(where: \.away)
        else { return XCTFail("no koi borrowed") }
        XCTAssertEqual(borrowed.look.scales, fish.look.scales)
        XCTAssertEqual(borrowed.look.pattern, fish.look.pattern)
        XCTAssertEqual(borrowed.look.base, fish.look.base)
    }
}
