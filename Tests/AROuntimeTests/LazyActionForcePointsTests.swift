// ============================================================
// LazyActionForcePointsTests.swift
// ARO Runtime - Phase 3 force points (Issue #55)
// ============================================================
//
// Force points are the rare places where a pthread blocks waiting on
// the cooperative pool to materialise an action's result. Phase 3
// adds branch consumers (compare / validate / accept) to the policy
// table and gives the C ABI value-accessors transparent auto-force
// so that any future stored as an AROCValue payload materialises
// before LLVM IR inspects it.

import XCTest
@testable import ARORuntime

final class LazyActionForcePointsTests: XCTestCase {

    // MARK: - Policy table

    func testBranchConsumersAreForceAtSite() {
        XCTAssertTrue(LazyActionPolicy.forceAtSite("compare"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("validate"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("accept"))
    }

    func testNonForceAtSiteVerbsRemainLazy() {
        XCTAssertFalse(LazyActionPolicy.forceAtSite("retrieve"))
        XCTAssertFalse(LazyActionPolicy.forceAtSite("compute"))
        XCTAssertFalse(LazyActionPolicy.forceAtSite("transform"))
    }

    // MARK: - Value-accessor auto-force

    func testMaterializedValueForcesAFutureBox() throws {
        let future = AROFuture(resolved: "deferred-result" as String, bindingName: "x")
        let box = AROCValue(value: future)

        XCTAssertTrue(box.value is AROFuture, "box.value must remain the future itself")
        XCTAssertEqual(box.materializedValue as? String, "deferred-result")
    }

    func testMaterializedValuePassesThroughPlainValue() throws {
        let box = AROCValue(value: 42 as Int)
        XCTAssertEqual(box.materializedValue as? Int, 42)
    }

    func testValueAccessorsForceFutureBox_string() throws {
        let future = AROFuture(resolved: "hello" as String, bindingName: "s")
        let box = AROCValue(value: future)
        let ptr = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { aro_value_free(ptr) }

        guard let cstr = aro_value_as_string(ptr) else {
            XCTFail("aro_value_as_string returned NULL")
            return
        }
        defer { free(cstr) }
        XCTAssertEqual(String(cString: cstr), "hello")
    }

    func testValueAccessorsForceFutureBox_int() throws {
        let future = AROFuture(resolved: 99 as Int, bindingName: "i")
        let box = AROCValue(value: future)
        let ptr = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { aro_value_free(ptr) }

        var out: Int64 = 0
        let ok = aro_value_as_int(ptr, &out)
        XCTAssertEqual(ok, 1)
        XCTAssertEqual(out, 99)
    }

    func testValueAccessorsForceFutureBox_double() throws {
        let future = AROFuture(resolved: 1.5 as Double, bindingName: "d")
        let box = AROCValue(value: future)
        let ptr = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { aro_value_free(ptr) }

        var out: Double = 0
        let ok = aro_value_as_double(ptr, &out)
        XCTAssertEqual(ok, 1)
        XCTAssertEqual(out, 1.5)
    }

    func testValueAccessorsAlsoWorkOnDeferredFuture() throws {
        let future = AROFuture(bindingName: "later") {
            try await Task.sleep(nanoseconds: 20_000_000)
            return "soon-but-not-now" as String
        }
        let box = AROCValue(value: future)
        let ptr = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { aro_value_free(ptr) }

        guard let cstr = aro_value_as_string(ptr) else {
            XCTFail("aro_value_as_string returned NULL")
            return
        }
        defer { free(cstr) }
        XCTAssertEqual(String(cString: cstr), "soon-but-not-now")
    }
}
