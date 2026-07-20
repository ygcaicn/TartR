import XCTest

@testable import TartRCore

final class TartRCoreTests: XCTestCase {
  func testOfficialCatalogIsCompleteAndUnique() {
    XCTAssertEqual(officialImageCatalog.count, 18)
    XCTAssertEqual(Set(officialImageCatalog.map(\.source)).count, 18)
    XCTAssertEqual(officialImageCatalog.filter(\.requiresAppleSilicon).count, 15)
    XCTAssertEqual(officialImageCatalog.filter { !$0.requiresAppleSilicon }.count, 3)
    XCTAssertTrue(officialImageCatalog.allSatisfy { $0.source.hasPrefix("ghcr.io/cirruslabs/") })
    XCTAssertTrue(officialImageCatalog.allSatisfy { $0.source.hasSuffix(":latest") })
  }

  func testListJSONDecodingMatchesTartSchema() throws {
    let json =
      #"[{"Source":"local","Name":"tahoe-base","Disk":50,"Size":12,"Running":true,"State":"Running"}]"#
      .data(using: .utf8)!
    let values = try JSONDecoder().decode([TartVMInfo].self, from: json)
    XCTAssertEqual(values.first?.name, "tahoe-base")
    XCTAssertEqual(values.first?.disk, 50)
    XCTAssertEqual(VMState.resolved(from: values.first), .running)
  }

  func testListParserToleratesLoginShellNoise() throws {
    let data =
      "shell banner\n[{\"Source\":\"local\",\"Name\":\"vm\",\"Running\":false,\"State\":\"Stopped\"}]\n"
      .data(using: .utf8)!
    XCTAssertEqual(try TartListParser.parse(data).map(\.name), ["vm"])
  }

  func testStateResolution() {
    XCTAssertEqual(VMState.resolved(from: nil), .missing)
    XCTAssertEqual(
      VMState.resolved(
        from: .init(source: "local", name: "vm", running: false, state: "Suspended")), .suspended)
    XCTAssertEqual(
      VMState.resolved(from: .init(source: "local", name: "vm", running: false, state: "Stopped")),
      .stopped)
  }

  func testNameValidation() {
    XCTAssertEqual(VMNameValidation.validate("  ", existingNames: []), .empty)
    XCTAssertEqual(VMNameValidation.validate("a/b", existingNames: []), .containsSlash)
    XCTAssertEqual(VMNameValidation.validate("VM", existingNames: ["vm"]), .duplicate)
    XCTAssertEqual(VMNameValidation.validate("new-vm", existingNames: ["vm"]), .valid)
  }

  func testCommandArgumentsAreNotShellInterpolated() {
    XCTAssertEqual(
      TartCommand.run(name: "vm name", suspendable: false).arguments, ["run", "vm name"])
    XCTAssertEqual(
      TartCommand.run(name: "vm", suspendable: true).arguments, ["run", "--suspendable", "vm"])
    XCTAssertEqual(
      TartCommand.stop(name: "vm", timeout: 8).arguments, ["stop", "vm", "--timeout", "8"])
    XCTAssertEqual(
      TartCommand.clone(source: "ghcr.io/example/image:latest", name: "local").arguments,
      ["clone", "ghcr.io/example/image:latest", "local"])
  }

  func testExecutableLocatorPrefersExplicitOverride() {
    let located = TartExecutableLocator.locate(
      environment: ["TART_EXECUTABLE": "/custom/tart"],
      homeDirectory: URL(fileURLWithPath: "/home/test"),
      isExecutable: { $0 == "/custom/tart" }
    )
    XCTAssertEqual(located?.path, "/custom/tart")
  }

  func testVMExitAssessmentAvoidsFalseFailureAlerts() {
    XCTAssertFalse(
      VMExitAssessment.shouldReportFailure(
        expectedStop: false, terminationStatus: 1, runtimeDuration: 1, synchronizedState: .running))
    XCTAssertFalse(
      VMExitAssessment.shouldReportFailure(
        expectedStop: false, terminationStatus: 1, runtimeDuration: 1, synchronizedState: .suspended
      ))
    XCTAssertFalse(
      VMExitAssessment.shouldReportFailure(
        expectedStop: false, terminationStatus: 1, runtimeDuration: 30, synchronizedState: .stopped)
    )
    XCTAssertTrue(
      VMExitAssessment.shouldReportFailure(
        expectedStop: false, terminationStatus: 1, runtimeDuration: 1, synchronizedState: .stopped))
  }
}
