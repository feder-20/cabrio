import XCTest

final class QuickActionTests: XCTestCase {
    var workflow: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("QuickAction/Cabrio.workflow/Contents") }

    func plist(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: workflow.appendingPathComponent(name)), format: nil) as? [String: Any])
    }

    func testWorkflowOpensSelectionInCabrioFromFinder() throws {
        let service = try XCTUnwrap((try plist("Info.plist")["NSServices"] as? [[String: Any]])?.first)
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Cabrio")
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.item"], "archivos y carpetas")
        XCTAssertEqual((service["NSRequiredContext"] as? [String: String])?["NSApplicationIdentifier"], "com.apple.finder")

        let doc = try plist("document.wflow")
        let action = try XCTUnwrap((doc["actions"] as? [[String: Any]])?.first?["action"] as? [String: Any])
        let params = try XCTUnwrap(action["ActionParameters"] as? [String: Any])
        XCTAssertEqual(params["COMMAND_STRING"] as? String, "/usr/bin/open -b com.chocolitossoft.cabrio \"$@\"")
        XCTAssertEqual(params["inputMethod"] as? Int, 1, "los archivos llegan como argumentos")
        let meta = try XCTUnwrap(doc["workflowMetaData"] as? [String: Any])
        XCTAssertEqual(meta["serviceInputTypeIdentifier"] as? String, "com.apple.Automator.fileSystemObject")
    }

    func testBundleIdentifierMatchesTheOneUsedByTheWorkflowAndEntitlements() throws {
        let root = workflow.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("make-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<string>com.chocolitossoft.cabrio</string>"))
        let ent = try String(contentsOf: root.appendingPathComponent("Distribution/Cabrio.entitlements"), encoding: .utf8)
        XCTAssertTrue(ent.contains("com.apple.security.automation.apple-events"), "con hardened runtime, AppleScript al Finder lo exige")
        XCTAssertFalse(ent.contains("app-sandbox"), "la venta directa no usa sandbox")
    }
}
