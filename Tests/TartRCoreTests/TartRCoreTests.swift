import Darwin
import XCTest

@testable import TartRCore

final class TartRCoreTests: XCTestCase {
  func testBoundedProcessOutputCapturesSmallOutput() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
    process.arguments = ["hello"]
    let capture = BoundedProcessOutput(maximumBytes: 64)
    capture.attach(to: process)
    try process.run()
    capture.processDidStart()
    process.waitUntilExit()

    let result = capture.finish()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(result, BoundedOutputSnapshot(data: Data("hello".utf8), wasTruncated: false))
    XCTAssertEqual(result.text, "hello")
  }

  func testBoundedProcessOutputDrainsAndTruncatesLargeOutput() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/dd")
    process.arguments = ["if=/dev/zero", "bs=1048576", "count=2"]
    let capture = BoundedProcessOutput(maximumBytes: 1_024)
    capture.attach(to: process)
    try process.run()
    capture.processDidStart()
    XCTAssertTrue(ProcessDeadline.waitForExit(process, timeout: 5))

    let result = capture.finish()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(result.wasTruncated)
    XCTAssertEqual(result.data.count, 1_024)
    XCTAssertTrue(
      result.text.hasPrefix("[\(TartRLocalization.string("Earlier output omitted"))]\n"))
  }

  func testAppVersionComparisonAndUpdateManifestValidation() {
    XCTAssertTrue(SecureURLValidation.isSecureHTTPS(URL(string: "https://example.com/file")))
    XCTAssertFalse(SecureURLValidation.isSecureHTTPS(URL(string: "http://example.com/file")))
    XCTAssertFalse(
      SecureURLValidation.isSecureHTTPS(URL(string: "https://user:secret@example.com/file")))
    XCTAssertLessThan(AppVersion("4.10.0")!, AppVersion("4.11")!)
    XCTAssertEqual(AppVersion("v4.11.0"), AppVersion("4.11"))
    XCTAssertNil(AppVersion("4.11-beta"))
    XCTAssertNil(AppVersion("4..11"))

    let manifest = UpdateManifest(
      schemaVersion: 1,
      version: "4.11.0",
      minimumSystemVersion: "13.0",
      downloadURL: "https://example.com/TartR-4.11.0-macos.dmg",
      releaseNotesURL: "https://example.com/releases/v4.11.0",
      sha256: String(repeating: "a", count: 64),
      fileSize: 1_234_567)
    let validated = UpdateManifestValidation.validate(manifest)
    XCTAssertEqual(validated?.version, AppVersion("4.11.0"))
    XCTAssertEqual(validated?.minimumSystemVersion, AppVersion("13"))
    XCTAssertEqual(validated?.sha256, String(repeating: "a", count: 64))
    XCTAssertEqual(validated?.fileSize, 1_234_567)

    XCTAssertNil(
      UpdateManifestValidation.validate(
        UpdateManifest(
          schemaVersion: 1,
          version: "4.11.0",
          minimumSystemVersion: "13.0",
          downloadURL: "http://example.com/TartR.dmg",
          releaseNotesURL: "https://user:password@example.com/release",
          sha256: "bad")))
    XCTAssertNil(
      UpdateManifestValidation.validate(
        UpdateManifest(
          schemaVersion: 1,
          version: "4.11.0",
          minimumSystemVersion: "13.0",
          downloadURL: "https://example.com/TartR.dmg",
          releaseNotesURL: "https://example.com/release",
          sha256: String(repeating: "a", count: 64),
          fileSize: UpdateManifestValidation.maximumPackageBytes + 1)))
  }

  func testUpdatePackageVerificationStreamsAndValidatesPackage() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartr-update-verify-\(UUID().uuidString).dmg")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("hello".utf8).write(to: url)
    let expectedHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    XCTAssertEqual(
      UpdatePackageVerification.verify(
        fileURL: url, expectedSize: 5, expectedSHA256: expectedHash),
      .valid(size: 5))
    XCTAssertEqual(
      UpdatePackageVerification.verify(
        fileURL: url, expectedSize: 6, expectedSHA256: expectedHash),
      .sizeMismatch(expected: 6, actual: 5))
    XCTAssertEqual(
      UpdatePackageVerification.verify(
        fileURL: url, expectedSize: 5, expectedSHA256: String(repeating: "0", count: 64)),
      .checksumMismatch(actual: expectedHash))
    XCTAssertEqual(
      UpdatePackageVerification.verify(
        fileURL: url, expectedSize: 4, expectedSHA256: expectedHash, maximumBytes: 4),
      .tooLarge(actual: 5, maximum: 4))
  }

  func testStorageCapacityPreflightKeepsReserveAndHandlesUnknownCapacity() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    XCTAssertEqual(
      StorageCapacityPreflight.assess(
        availableBytes: Int64(35 * gib), operationBytes: 30 * gib),
      .sufficient(availableBytes: 35 * gib, requiredBytes: 35 * gib))
    XCTAssertEqual(
      StorageCapacityPreflight.assess(
        availableBytes: Int64(34 * gib), operationBytes: 30 * gib),
      .insufficient(availableBytes: 34 * gib, requiredBytes: 35 * gib))
    XCTAssertEqual(
      StorageCapacityPreflight.assess(availableBytes: nil, operationBytes: 30 * gib),
      .unavailable)
    XCTAssertEqual(
      StorageCapacityPreflight.assess(availableBytes: -1, operationBytes: 30 * gib),
      .unavailable)
    XCTAssertEqual(
      StorageCapacityPreflight.assess(
        availableBytes: Int64.max, operationBytes: UInt64.max, reserveBytes: 1),
      .insufficient(availableBytes: UInt64(Int64.max), requiredBytes: UInt64.max))
  }

  func testTartVersionValidationRejectsUnrelatedExecutables() {
    XCTAssertTrue(TartVersionValidation.isPlausible("2.32.1"))
    XCTAssertTrue(TartVersionValidation.isPlausible("tart 2.33.0-beta.1"))
    XCTAssertTrue(TartVersionValidation.isPlausible("Tart v3.0"))
    XCTAssertFalse(TartVersionValidation.isPlausible(""))
    XCTAssertFalse(TartVersionValidation.isPlausible("Python 3.12.1"))
    XCTAssertFalse(TartVersionValidation.isPlausible("Darwin Kernel Version 25"))
    XCTAssertFalse(TartVersionValidation.isPlausible(String(repeating: "1", count: 300)))
  }

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
    XCTAssertEqual(GuestShellCommandValidation.validate("uname -a"), .valid)
    XCTAssertEqual(GuestShellCommandValidation.validate(" \n"), .empty)
    XCTAssertEqual(GuestShellCommandValidation.validate("echo \0"), .containsNull)
    XCTAssertEqual(
      GuestShellCommandValidation.validate(String(repeating: "x", count: 4_097)), .tooLong)
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
    let guestCommand = "printf '%s\\n' \"$(uname)\"; id"
    XCTAssertEqual(
      TartCommand.execShell(name: "vm name", command: guestCommand).arguments,
      ["exec", "vm name", "/bin/zsh", "-lc", guestCommand])
    let auditLog = TartCommandAuditLog.format(
      arguments: TartCommand.execShell(name: "vm", command: "echo secret-token").arguments,
      terminationStatus: 0,
      cancelled: false,
      output: "secret-output")
    XCTAssertFalse(auditLog.contains("secret-token"))
    XCTAssertFalse(auditLog.contains("secret-output"))
    XCTAssertTrue(auditLog.contains("guest command and output redacted"))
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

  func testExecutableLocatorPrefersPersistedPathOverEnvironment() {
    let candidates = TartExecutableLocator.candidatePaths(
      explicitPath: "/selected/tart",
      environment: ["TART_EXECUTABLE": "/environment/tart"],
      homeDirectory: URL(fileURLWithPath: "/home/test"))
    XCTAssertEqual(
      candidates,
      [
        "/selected/tart", "/environment/tart", "/opt/homebrew/bin/tart", "/usr/local/bin/tart",
        "/home/test/.local/bin/tart",
      ])
    let located = TartExecutableLocator.locate(
      explicitPath: "/selected/tart",
      environment: ["TART_EXECUTABLE": "/environment/tart"],
      homeDirectory: URL(fileURLWithPath: "/home/test"),
      isExecutable: { ["/selected/tart", "/environment/tart"].contains($0) })
    XCTAssertEqual(located?.path, "/selected/tart")
  }

  func testTartHomeResolverUsesAppSettingThenEnvironmentThenDefault() {
    XCTAssertEqual(
      TartHomeResolver.resolve(
        configuredPath: "/Volumes/mini/home/tart_data",
        environment: ["TART_HOME": "/environment/tart"]),
      ResolvedTartHome(path: "/Volumes/mini/home/tart_data", source: .appSetting))
    XCTAssertEqual(
      TartHomeResolver.resolve(
        configuredPath: nil,
        environment: ["TART_HOME": "/environment/tart"]),
      ResolvedTartHome(path: "/environment/tart", source: .environment))
    XCTAssertEqual(
      TartHomeResolver.resolve(configuredPath: nil, environment: [:]),
      ResolvedTartHome(path: nil, source: .tartDefault))
  }

  func testTartHomeResolverAppliesAndClearsEnvironment() {
    XCTAssertEqual(
      TartHomeResolver.applying(
        configuredPath: "/Volumes/mini/home/tart_data",
        to: ["PATH": "/usr/bin", "TART_HOME": "/old"]),
      ["PATH": "/usr/bin", "TART_HOME": "/Volumes/mini/home/tart_data"])
    XCTAssertEqual(
      TartHomeResolver.applying(configuredPath: nil, to: ["PATH": "/usr/bin"]),
      ["PATH": "/usr/bin"])
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
    XCTAssertEqual(decoded.first?.sshUsername, SSHConnectionCommand.defaultUsername)
  }

  func testPartialRunOptionsDecodeWithForwardCompatibleDefaults() throws {
    let id = UUID()
    let data =
      #"[{"id":"\#(id.uuidString)","name":"worker","runOptions":{"headless":true}}]"#
      .data(using: .utf8)!
    let decoded = try JSONDecoder().decode([VMConfiguration].self, from: data)
    XCTAssertEqual(decoded.first?.runOptions, VMRunOptions(headless: true))
  }

  func testSSHConnectionCommandAcceptsSafeTargets() {
    XCTAssertEqual(
      SSHConnectionCommand.make(username: "admin", host: "192.0.2.10"),
      "ssh admin@192.0.2.10")
    XCTAssertEqual(
      SSHConnectionCommand.make(username: "ci_runner-1", host: "vm-1.example.test"),
      "ssh ci_runner-1@vm-1.example.test")
    XCTAssertEqual(
      SSHConnectionCommand.make(username: "admin", host: "2001:db8::10"),
      "ssh -l admin 2001:db8::10")
  }

  func testSSHConnectionCommandRejectsInjectionAndMalformedTargets() {
    for username in [
      "", " admin", "admin user", "admin;id", "$(id)", "`id`", "-oProxyCommand=id",
      "admin@host", String(repeating: "a", count: 65),
    ] {
      XCTAssertFalse(SSHConnectionCommand.isValidUsername(username), username)
      XCTAssertNil(SSHConnectionCommand.make(username: username, host: "192.0.2.10"), username)
    }

    for host in [
      "", " 192.0.2.10", "192.0.2.10;id", "$(id)", "`id`", "-oProxyCommand=id",
      "example.com -p 22", "999.0.0.1", "1.2.3", "2001:db8::zz", "host..example",
      "host.example\nrm -rf /",
    ] {
      XCTAssertNil(SSHConnectionCommand.make(username: "admin", host: host), host)
    }
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
          runOptions: VMRunOptions(headless: true, noClipboard: true), sshUsername: "runner")
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
    XCTAssertEqual(
      TartRSettingsValidation.validate(
        TartRSettingsDocument(
          exportedByVersion: "test",
          configurations: [VMConfiguration(name: "worker", sshUsername: "admin;id")])),
      .invalidSSHUsername)
  }
}
