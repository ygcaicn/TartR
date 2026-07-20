import Darwin
import XCTest

@testable import TartRCore

final class TartRCoreTests: XCTestCase {
  func testVMSelectionCapabilitiesResolveMixedBatchSafely() {
    let stopped = VMConfiguration(name: "stopped")
    let suspended = VMConfiguration(name: "suspended")
    let running = VMConfiguration(name: "running")
    let starting = VMConfiguration(name: "starting")
    let stopping = VMConfiguration(name: "stopping")
    let missing = VMConfiguration(name: "missing")
    let failed = VMConfiguration(name: "failed")
    let configurations = [stopped, suspended, running, starting, stopping, missing, failed]
    let capabilities = VMSelectionCapabilities.resolve(
      configurations: configurations,
      states: [
        stopped.id: .stopped,
        suspended.id: .suspended,
        running.id: .running,
        starting.id: .starting,
        stopping.id: .stopping,
        missing.id: .missing,
        failed.id: .failed(1),
      ],
      discoveredNames: ["stopped", "suspended", "running", "starting", "stopping"])

    XCTAssertEqual(capabilities.selectionCount, 7)
    XCTAssertEqual(capabilities.startableIDs, [stopped.id, suspended.id, failed.id])
    XCTAssertEqual(capabilities.stoppableIDs, [running.id, starting.id])
    XCTAssertFalse(capabilities.canRemoveRecords)
    XCTAssertFalse(capabilities.hasSingleSelection)
  }

  func testVMSelectionCapabilitiesAllowRemovingOnlyMissingRecords() {
    let first = VMConfiguration(name: "first")
    let second = VMConfiguration(name: "second")
    let capabilities = VMSelectionCapabilities.resolve(
      configurations: [first, second],
      states: [first.id: .missing, second.id: .unknown],
      discoveredNames: [])

    XCTAssertTrue(capabilities.canRemoveRecords)
    XCTAssertTrue(capabilities.startableIDs.isEmpty)
    XCTAssertTrue(capabilities.stoppableIDs.isEmpty)
  }

  func testProcessDetachmentLeavesChildRunning() throws {
    let logURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartr-detach-test-\(UUID().uuidString).log")
    XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: logURL) }

    func launchDetachedProcess() throws -> pid_t {
      let handle = try FileHandle(forWritingTo: logURL)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sleep")
      process.arguments = ["5"]
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      let pid = process.processIdentifier
      ProcessDetachment.detach(process, closing: [handle])
      return pid
    }

    let pid = try launchDetachedProcess()
    defer { kill(pid, SIGTERM) }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(kill(pid, 0), 0)
  }

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

  func testVMResourceValidation() {
    XCTAssertEqual(
      VMResourceValidation.validate(
        cpu: "4", memory: "8192", display: "1920x1080px", diskSize: "80"),
      .valid)
    XCTAssertEqual(
      VMResourceValidation.validate(cpu: "0", memory: "", display: "", diskSize: ""),
      .invalidCPU)
    XCTAssertEqual(
      VMResourceValidation.validate(cpu: "", memory: "eight", display: "", diskSize: ""),
      .invalidMemory)
    XCTAssertEqual(
      VMResourceValidation.validate(cpu: "", memory: "", display: "1920*1080", diskSize: ""),
      .invalidDisplay)
    XCTAssertEqual(
      VMResourceValidation.validate(cpu: "", memory: "", display: "", diskSize: "-1"),
      .invalidDiskSize)
  }

  func testCommandArgumentsAreNotShellInterpolated() {
    XCTAssertEqual(TartCommand.version.arguments, ["--version"])
    XCTAssertEqual(
      TartCommand.run(name: "vm name", options: VMRunOptions()).arguments, ["run", "vm name"])
    XCTAssertEqual(
      TartCommand.run(
        name: "vm",
        options: VMRunOptions(
          headless: true, noAudio: true, noClipboard: true, suspendable: true)
      ).arguments,
      ["run", "--no-graphics", "--no-audio", "--no-clipboard", "--suspendable", "vm"])
    XCTAssertEqual(
      TartCommand.stop(name: "vm", timeout: 8).arguments, ["stop", "vm", "--timeout", "8"])
    XCTAssertEqual(
      TartCommand.clone(source: "ghcr.io/example/image:latest", name: "local").arguments,
      ["clone", "ghcr.io/example/image:latest", "local"])
    XCTAssertEqual(
      TartCommand.get(name: "vm").arguments, ["get", "vm", "--format", "json"])
    XCTAssertEqual(
      TartCommand.push(name: "vm", remoteName: "ghcr.io/acme/vm:latest").arguments,
      ["push", "vm", "ghcr.io/acme/vm:latest"])
    XCTAssertEqual(
      TartCommand.exportArchive(name: "vm", path: "/tmp/vm backup.tvm").arguments,
      ["export", "vm", "/tmp/vm backup.tvm"])
    XCTAssertEqual(
      TartCommand.importArchive(path: "/tmp/vm backup.tvm", name: "restored-vm").arguments,
      ["import", "/tmp/vm backup.tvm", "restored-vm"])
    XCTAssertEqual(
      TartCommand.pruneCaches(olderThan: "30", spaceBudget: "100").arguments,
      ["prune", "--entries", "caches", "--older-than", "30", "--space-budget", "100"])
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

  func testVMListProjectionFiltersAndSorts() {
    let alpha = VMConfiguration(name: "alpha")
    let beta = VMConfiguration(name: "beta")
    let infos = [
      "alpha": TartVMInfo(
        source: "local", name: "alpha", disk: 50, size: 20, running: false, state: "Stopped"),
      "beta": TartVMInfo(
        source: "local", name: "beta", disk: 80, size: 10, running: false, state: "Stopped"),
    ]
    XCTAssertEqual(
      VMListProjection.make(
        configurations: [beta, alpha], states: [:], infoByName: infos, query: "ALP",
        sortKey: .name, ascending: true
      ).map(\.name),
      ["alpha"])
    XCTAssertEqual(
      VMListProjection.make(
        configurations: [alpha, beta], states: [:], infoByName: infos, query: "",
        sortKey: .disk, ascending: false
      ).map(\.name),
      ["beta", "alpha"])
  }

  func testProcessDeadlineAllowsNormalExit() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    XCTAssertTrue(ProcessDeadline.waitForExit(process, timeout: 1, cancellationGrace: 0.1))
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testProcessDeadlineTerminatesHungProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]
    try process.run()
    XCTAssertFalse(ProcessDeadline.waitForExit(process, timeout: 0.05, cancellationGrace: 0.1))
    XCTAssertFalse(process.isRunning)
  }

  func testLegacyVMConfigurationDecodesWithDefaultRunOptions() throws {
    let id = UUID()
    let data = #"[{"id":"\#(id.uuidString)","name":"legacy-vm","autoStart":true}]"#
      .data(using: .utf8)!
    let decoded = try JSONDecoder().decode([VMConfiguration].self, from: data)
    XCTAssertEqual(decoded.first?.name, "legacy-vm")
    XCTAssertEqual(decoded.first?.autoStart, true)
    XCTAssertEqual(decoded.first?.runOptions, VMRunOptions())
  }

  func testPartialRunOptionsDecodeWithForwardCompatibleDefaults() throws {
    let id = UUID()
    let data =
      #"[{"id":"\#(id.uuidString)","name":"worker","runOptions":{"headless":true}}]"#
      .data(using: .utf8)!
    let decoded = try JSONDecoder().decode([VMConfiguration].self, from: data)
    XCTAssertEqual(decoded.first?.runOptions, VMRunOptions(headless: true))
  }

  func testVMConfigurationRecoveryFallsBackWithoutLosingBackup() throws {
    let expected = [
      VMConfiguration(
        name: "worker", autoStart: true,
        runOptions: VMRunOptions(headless: true, noAudio: true))
    ]
    let backup = try JSONEncoder().encode(expected)
    let result = VMConfigurationRecovery.resolve(
      current: Data("not-json".utf8), backup: backup, legacy: [])
    XCTAssertEqual(result.source, .backup)
    XCTAssertEqual(result.configurations, expected)
  }

  func testVMConfigurationRecoveryUsesLegacyThenEmpty() throws {
    let legacy = try JSONEncoder().encode([VMConfiguration(name: "legacy")])
    XCTAssertEqual(
      VMConfigurationRecovery.resolve(current: nil, backup: nil, legacy: [legacy]).source,
      .legacy)
    XCTAssertEqual(
      VMConfigurationRecovery.resolve(
        current: Data("bad".utf8), backup: Data("bad".utf8), legacy: [Data("bad".utf8)]
      ).source,
      .empty)
  }

  func testTemporaryFileCleanupOnlyRemovesOwnedStaleFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartr-cleanup-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldOwned = directory.appendingPathComponent("tartr-command-old.log")
    let newOwned = directory.appendingPathComponent("tartr-command-new.log")
    let unrelated = directory.appendingPathComponent("other-old.log")
    for url in [oldOwned, newOwned, unrelated] {
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
    }
    let now = Date()
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
      ofItemAtPath: oldOwned.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
      ofItemAtPath: unrelated.path)

    let removed = TemporaryFileCleanup.removeStaleFiles(
      in: directory, namePrefix: "tartr-command-", olderThan: 24 * 60 * 60, now: now)
    XCTAssertEqual(removed.map(\.lastPathComponent), ["tartr-command-old.log"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldOwned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newOwned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testSettingsDocumentRoundTripAndValidation() throws {
    let document = TartRSettingsDocument(
      exportedByVersion: "4.5.0",
      configurations: [
        VMConfiguration(
          name: "worker", autoStart: true,
          runOptions: VMRunOptions(headless: true, noClipboard: true))
      ])
    let decoded = try JSONDecoder().decode(
      TartRSettingsDocument.self, from: JSONEncoder().encode(document))
    XCTAssertEqual(decoded, document)
    XCTAssertEqual(TartRSettingsValidation.validate(decoded), .valid)
  }

  func testSettingsDocumentRejectsUnsupportedAndAmbiguousData() {
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(schemaVersion: 99, exportedByVersion: "future", configurations: [])),
      .unsupportedSchema(99))
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(
          exportedByVersion: "test",
          configurations: [VMConfiguration(name: "VM"), VMConfiguration(name: "vm")])),
      .duplicateName)
    let id = UUID()
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(
          exportedByVersion: "test",
          configurations: [
            VMConfiguration(id: id, name: "one"), VMConfiguration(id: id, name: "two"),
          ])),
      .duplicateID)
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(
          exportedByVersion: "test", configurations: [VMConfiguration(name: "bad/name")])),
      .invalidName)
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(
          exportedByVersion: "test", configurations: [VMConfiguration(name: " padded ")])),
      .invalidName)
  }
}
