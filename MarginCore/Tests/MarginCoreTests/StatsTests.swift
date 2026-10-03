import XCTest
@testable import MarginCore

/// Reference values computed with NumPy 2.4 / SciPy 1.17.
final class StatsTests: XCTestCase {
    let xs: [Double] = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5]

    func testQuantilesMatchNumPy() {
        XCTAssertEqual(Stats.quantile(xs, 0), 1)
        XCTAssertEqual(Stats.quantile(xs, 0.1), 1)
        XCTAssertEqual(Stats.quantile(xs, 0.25), 2.5)
        XCTAssertEqual(Stats.quantile(xs, 0.5), 4)
        XCTAssertEqual(Stats.quantile(xs, 0.9), 6)
        XCTAssertEqual(Stats.quantile(xs, 1), 9)
        XCTAssertNil(Stats.quantile([], 0.5))
        XCTAssertNil(Stats.quantile(xs, 1.1))
    }

    func testDispersion() {
        XCTAssertEqual(Stats.mad(xs), 1)
        XCTAssertEqual(Stats.standardDeviation(xs)!, 2.3664319132398464, accuracy: 1e-12)
        XCTAssertNil(Stats.variance([1]))
        XCTAssertNil(Stats.mean([]))
    }

    func testNormalCDF() {
        let cases: [(Double, Double)] = [
            (-3, 0.0013498980316300933), (-1, 0.15865525393145707), (0, 0.5),
            (0.44, 0.6700314463394064), (1, 0.8413447460685429), (2.5, 0.9937903346742238),
        ]
        for (z, p) in cases { XCTAssertEqual(Stats.normalCDF(z), p, accuracy: 1e-12) }
    }

    func testIncompleteBeta() {
        XCTAssertEqual(Stats.regularizedIncompleteBeta(0.3, a: 2.5, b: 0.5), 0.018927124071945658, accuracy: 1e-12)
        XCTAssertEqual(Stats.regularizedIncompleteBeta(0.9, a: 1, b: 3), 0.999, accuracy: 1e-12)
        XCTAssertEqual(Stats.regularizedIncompleteBeta(0.5, a: 10, b: 10), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.regularizedIncompleteBeta(0.01, a: 0.5, b: 0.5), 0.06376856085851985, accuracy: 1e-12)
    }

    func testStudentTPValues() {
        let cases: [(Double, Double, Double)] = [
            (2.0, 10, 0.07338803477074037), (1.0, 3.5, 0.3813372535634453),
            (5.0, 50, 7.4332122472325795e-06), (0.3, 7.2, 0.7726538921891086),
            (-2.5, 4, 0.06676654481198814),
        ]
        for (t, df, p) in cases {
            XCTAssertEqual(Stats.studentTTwoSidedP(t: t, df: df)!, p, accuracy: max(1e-12, p * 1e-9))
        }
        XCTAssertNil(Stats.studentTTwoSidedP(t: 1, df: 0))
    }

    func testRobustBaselineIgnoresOutliersAndFloorsScale() {
        let b = RobustBaseline(values: [50, 51, 49, 50, 50, 52, 48, 200], minCount: 5, scaleFloor: 0.1)!
        XCTAssertEqual(b.center, 50)
        XCTAssertEqual(b.scale, 1.4826, accuracy: 1e-12)
        XCTAssertNil(RobustBaseline(values: [1, 2, 3], minCount: 5, scaleFloor: 0.1))
        let flat = RobustBaseline(values: Array(repeating: 4.0, count: 20), minCount: 14, scaleFloor: 0.05)!
        XCTAssertEqual(flat.scale, 0.05)
        XCTAssertEqual(flat.z(4.1), 2, accuracy: 1e-12)
    }
}
