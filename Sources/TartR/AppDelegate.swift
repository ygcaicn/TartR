import AppKit
import Darwin
import Foundation
import ServiceManagement
import TartRCore
import UniformTypeIdentifiers

private let appTitle = "TartR"
private func localized(_ key: String, _ arguments: CVarArg...) -> String {
  TartRLocalization.string(key, arguments: arguments)
}
private let defaultsKey = "vmConfigurations.v2"
private let defaultsBackupKey = "vmConfigurations.v2.backup"
private let defaultsCorruptKey = "vmConfigurations.v2.corruptBackup"
private let selectedVMKey = "selectedVM.v2"
private let tartExecutablePathKey = "tartExecutablePath.v1"
private let tartHomePathKey = "tartHomePath.v1"
private let automaticUpdateChecksKey = "automaticUpdateChecks.v1"
private let lastUpdateCheckKey = "lastUpdateCheck.v1"
private let maximumCommandOutputBytes = 1_024 * 1_024
private let legacyAppIDs = [
  "local.caiyagang.tartr",
  "local.caiyagang.tart-vm-manager",
]

private let imageCatalog: [ImageCatalogItem] = {
  #if arch(x86_64)
    return officialImageCatalog.filter { !$0.requiresAppleSilicon }
  #else
    return officialImageCatalog
  #endif
}()

private final class VMRuntime {
  let process: Process
  let logHandle: FileHandle
  let startedAt: Date
  var expectedStop = false

  init(process: Process, logHandle: FileHandle, startedAt: Date = Date()) {
    self.process = process
    self.logHandle = logHandle
    self.startedAt = startedAt
  }
}

private final class LimitedHTTPDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let maximumBytes: Int
  private let completion: (Data?, URLResponse?, Error?) -> Void
  private var receivedData = Data()
  private var receivedResponse: URLResponse?
  private var limitError: Error?
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(maximumBytes: Int, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
    self.maximumBytes = maximumBytes
    self.completion = completion
  }

  func start(request: URLRequest, configuration: URLSessionConfiguration) {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    receivedResponse = response
    if response.expectedContentLength > Int64(maximumBytes) {
      limitError = CocoaError(.fileReadTooLarge)
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(SecureURLValidation.isSecureHTTPS(request.url) ? request : nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard data.count <= maximumBytes - receivedData.count else {
      limitError = CocoaError(.fileReadTooLarge)
      dataTask.cancel()
      return
    }
    receivedData.append(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    self.task = nil
    self.session = nil
    session.finishTasksAndInvalidate()
    completion(limitError == nil ? receivedData : nil, receivedResponse, limitError ?? error)
  }
}

private enum SecureUpdateDownloadError: LocalizedError {
  case invalidResponse
  case insecureRedirect
  case sizeLimitExceeded
  case verificationFailed
  case cannotStore(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return localized("The update server returned an invalid download response.")
    case .insecureRedirect:
      return localized("The update download was redirected to an insecure address.")
    case .sizeLimitExceeded:
      return localized(
        "The update package size does not match the manifest or exceeds the 512 MB limit.")
    case .verificationFailed:
      return localized("The update package failed size or SHA-256 verification and was not saved.")
    case .cannotStore(let detail):
      return localized("Unable to save the verified update package: %@", detail)
    }
  }
}

private final class SecureUpdateDownloader: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let expectedSize: UInt64
  private let expectedSHA256: String
  private let destinationURL: URL
  private let progress: (UInt64, UInt64) -> Void
  private let completion: (Result<URL, Error>) -> Void
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var pendingError: Error?
  private var completed = false

  init(
    expectedSize: UInt64,
    expectedSHA256: String,
    destinationURL: URL,
    progress: @escaping (UInt64, UInt64) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    self.expectedSize = expectedSize
    self.expectedSHA256 = expectedSHA256
    self.destinationURL = destinationURL
    self.progress = progress
    self.completion = completion
  }

  func start(request: URLRequest) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30 * 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    let task = session.downloadTask(with: request)
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard SecureURLValidation.isSecureHTTPS(request.url) else {
      pendingError = SecureUpdateDownloadError.insecureRedirect
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard validateResponse(downloadTask), totalBytesWritten >= 0 else {
      downloadTask.cancel()
      return
    }
    let received = UInt64(totalBytesWritten)
    guard received <= expectedSize,
      received <= UpdateManifestValidation.maximumPackageBytes
    else {
      pendingError = SecureUpdateDownloadError.sizeLimitExceeded
      downloadTask.cancel()
      return
    }
    let total = expectedSize
    DispatchQueue.main.async { [progress] in progress(received, total) }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard validateResponse(downloadTask) else { return }
    guard
      UpdatePackageVerification.verify(
        fileURL: location,
        expectedSize: expectedSize,
        expectedSHA256: expectedSHA256) == .valid(size: expectedSize)
    else {
      pendingError = SecureUpdateDownloadError.verificationFailed
      return
    }

    let fileManager = FileManager.default
    let stagingURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).download")
    do {
      try fileManager.copyItem(at: location, to: stagingURL)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
      guard
        UpdatePackageVerification.verify(
          fileURL: stagingURL,
          expectedSize: expectedSize,
          expectedSHA256: expectedSHA256) == .valid(size: expectedSize)
      else {
        try? fileManager.removeItem(at: stagingURL)
        pendingError = SecureUpdateDownloadError.verificationFailed
        return
      }
      if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
      } else {
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
      }
      finish(.success(destinationURL))
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      pendingError = SecureUpdateDownloadError.cannotStore(error.localizedDescription)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard !completed else { return }
    finish(.failure(pendingError ?? error ?? SecureUpdateDownloadError.invalidResponse))
  }

  private func validateResponse(_ task: URLSessionTask) -> Bool {
    guard pendingError == nil,
      let response = task.response as? HTTPURLResponse,
      response.statusCode == 200,
      SecureURLValidation.isSecureHTTPS(response.url),
      response.expectedContentLength < 0
        || UInt64(response.expectedContentLength) == expectedSize
    else {
      if pendingError == nil { pendingError = SecureUpdateDownloadError.invalidResponse }
      return false
    }
    return true
  }

  private func finish(_ result: Result<URL, Error>) {
    guard !completed else { return }
    completed = true
    task = nil
    session?.finishTasksAndInvalidate()
    session = nil
    DispatchQueue.main.async { [completion] in completion(result) }
  }

}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
  private var window: NSWindow!
  private var tableView: NSTableView!
  private var nameField: NSTextField!
  private var searchField: NSSearchField!
  private var addButton: NSButton!
  private var startButton: NSButton!
  private var stopButton: NSButton!
  private var deleteButton: NSButton!
  private var logButton: NSButton!
  private var imageButton: NSButton!
  private var moreButton: NSButton!
  private var summaryLabel: NSTextField!
  private var tartHomeLabel: NSTextField!
  private var installBox: NSBox!
  private var operationLabel: NSTextField!
  private var operationSpinner: NSProgressIndicator!
  private var cancelOperationButton: NSButton!
  private var catalogTargetField: NSTextField?
  private var catalogSourceField: NSTextField?
  private var pendingReplacementDiskField: NSTextField?
  private var launchAtLoginMenuItem: NSMenuItem?
  private var automaticUpdateMenuItem: NSMenuItem?

  private var configurations: [VMConfiguration] = []
  private var states: [UUID: VMState] = [:]
  private var runtimes: [UUID: VMRuntime] = [:]
  private var discoveredNames: Set<String> = []
  private var infoByName: [String: TartVMInfo] = [:]
  private var syncTimer: Timer?
  private var syncInProgress = false
  private var syncProcess: Process?
  private var syncCompletions: [() -> Void] = []
  private var tartSyncError: String?
  private var tartInstalled = true
  private var operationProcess: Process?
  private var operationOutputCapture: BoundedProcessOutput?
  private var operationBaseTitle: String?
  private var operationProgressTimer: Timer?
  private var operationWasCancelled = false
  private var lastTableSignature: String?
  private var isQuitting = false
  private var configurationRecoveryNotice: String?
  private var updateLoader: LimitedHTTPDataLoader?
  private var updateDownloader: SecureUpdateDownloader?

  private lazy var logsDirectory: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/TartR", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  private lazy var applicationLogURL = logsDirectory.appendingPathComponent("TartR.log")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    UserDefaults.standard.register(defaults: [automaticUpdateChecksKey: true])
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil)
    TemporaryFileCleanup.removeStaleFiles(
      in: FileManager.default.temporaryDirectory,
      namePrefix: "tartr-command-",
      olderThan: 24 * 60 * 60)
    loadConfigurations()
    buildMenu()
    buildWindow()
    restoreSelection()
    for configuration in configurations { states[configuration.id] = .unknown }
    refreshUI()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let configurationRecoveryNotice {
      DispatchQueue.main.async { [weak self] in
        self?.showAlert(title: localized("VM list restored"), message: configurationRecoveryNotice)
      }
    }
    syncTartState { [weak self] in
      guard let self else { return }
      for configuration in self.configurations where configuration.autoStart {
        if self.states[configuration.id]?.isRunning != true,
          !self.discoveredNames.isEmpty,
          self.discoveredNames.contains(configuration.name)
        {
          self.startVM(id: configuration.id, verifyFirst: false)
        }
      }
    }
    syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.syncTartState()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      self?.checkForUpdatesIfDue()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    isQuitting = true
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    updateLoader?.cancel()
    updateDownloader?.cancel()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    updateLaunchAtLoginMenuItem()
    updateAutomaticUpdateMenuItem()
    syncTartState()
  }

  @objc private func workspaceDidWake(_ notification: Notification) {
    syncTartState()
    checkForUpdatesIfDue()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    syncTartState()
    return true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isQuitting else { return .terminateLater }
    let managedRuntimes = runtimes.values.filter { $0.process.isRunning }
    let backgroundProcesses = [operationProcess, syncProcess].compactMap { process in
      process?.isRunning == true ? process : nil
    }
    guard !managedRuntimes.isEmpty || !backgroundProcesses.isEmpty else {
      syncTimer?.invalidate()
      return .terminateNow
    }

    var keepVMsRunning = false
    if !managedRuntimes.isEmpty {
      showWindow()
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = localized("TartR is still managing %d VM(s)", managedRuntimes.count)
      alert.informativeText =
        localized(
          "You can keep the VMs running in the background. TartR will synchronize and resume management when reopened."
        )
        + (backgroundProcesses.isEmpty
          ? "" : localized(" Other active Tart operations will be cancelled."))
      alert.addButton(withTitle: localized("Keep VMs Running and Quit"))
      alert.addButton(withTitle: localized("Stop VMs and Quit"))
      alert.addButton(withTitle: localized("Cancel"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        keepVMsRunning = true
      case .alertSecondButtonReturn:
        break
      default:
        return .terminateCancel
      }
    } else {
      showWindow()
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = localized("A Tart operation is still in progress")
      alert.informativeText = localized("Quitting now will cancel the active operation.")
      alert.addButton(withTitle: localized("Cancel Operation and Quit"))
      alert.addButton(withTitle: localized("Keep Waiting"))
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }

    syncTimer?.invalidate()
    isQuitting = true
    var processesToTerminate = backgroundProcesses

    if keepVMsRunning {
      appendApplicationLog(
        localized("TartR quit while leaving %d managed VM(s) running.", managedRuntimes.count))
      for runtime in managedRuntimes {
        ProcessDetachment.detach(runtime.process, closing: [runtime.logHandle])
      }
      runtimes.removeAll()
    } else {
      processesToTerminate.append(contentsOf: managedRuntimes.map(\.process))
      for (id, runtime) in runtimes where runtime.process.isRunning {
        runtime.expectedStop = true
        states[id] = .stopping
        kill(runtime.process.processIdentifier, SIGINT)
      }
    }
    if let operationProcess, operationProcess.isRunning {
      operationWasCancelled = true
      operationProcess.interrupt()
    }
    syncProcess?.interrupt()
    refreshUI()

    guard !processesToTerminate.isEmpty else { return .terminateNow }
    let terminationProcesses = processesToTerminate
    DispatchQueue.global(qos: .userInitiated).async {
      let deadline = Date().addingTimeInterval(8)
      while terminationProcesses.contains(where: \.isRunning) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
      }
      for process in terminationProcesses where process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(openSelectedLog):
      return selectedConfiguration != nil
    case #selector(refreshNow):
      return !syncInProgress && !isQuitting
    case #selector(chooseTartExecutable):
      return operationProcess == nil && updateDownloader == nil && !syncInProgress
    case #selector(resetTartExecutable):
      return configuredTartExecutablePath != nil && operationProcess == nil
        && updateDownloader == nil && !syncInProgress
    case #selector(chooseTartHome):
      return canChangeTartHome
    case #selector(resetTartHome):
      return configuredTartHomePath != nil && canChangeTartHome
    case #selector(checkForUpdates):
      return updateLoader == nil && updateDownloader == nil
    case #selector(toggleAutomaticUpdateChecks):
      return configuredUpdateManifestURL != nil
    default:
      return true
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    visibleConfigurations.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let visible = visibleConfigurations
    guard visible.indices.contains(row), let identifier = tableColumn?.identifier else {
      return nil
    }
    let configuration = visible[row]

    switch identifier.rawValue {
    case "name":
      return iconTextCell(
        identifier: identifier, text: configuration.name, symbolName: "desktopcomputer")
    case "status":
      let state = states[configuration.id] ?? .unknown
      return statusCell(identifier: identifier, state: state)
    case "disk":
      let cell = reusableTextCell(identifier: identifier)
      cell.textField?.stringValue = infoByName[configuration.name]?.disk.map { "\($0) GB" } ?? "—"
      cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      cell.textField?.textColor = .secondaryLabelColor
      return cell
    case "size":
      let cell = reusableTextCell(identifier: identifier)
      cell.textField?.stringValue = infoByName[configuration.name]?.size.map { "\($0) GB" } ?? "—"
      cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      cell.textField?.textColor = .secondaryLabelColor
      return cell
    case "autostart":
      let cell = NSTableCellView()
      cell.identifier = identifier
      let toggle = NSSwitch()
      toggle.target = self
      toggle.action = #selector(toggleAutoStart(_:))
      toggle.state = configuration.autoStart ? .on : .off
      toggle.controlSize = .small
      toggle.tag = row
      toggle.setAccessibilityLabel(
        localized("Start %@ automatically when TartR opens", configuration.name))
      toggle.setAccessibilityValue(configuration.autoStart)
      toggle.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(toggle)
      NSLayoutConstraint.activate([
        toggle.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
        toggle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    default:
      return nil
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if let selected = selectedConfiguration {
      UserDefaults.standard.set(selected.id.uuidString, forKey: activeSelectedVMKey)
    }
    refreshUI()
  }

  func tableView(
    _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
  ) {
    refreshUI(forceTableReload: true)
  }

  func controlTextDidChange(_ obj: Notification) {
    addButton.isEnabled = !normalizedInputName.isEmpty
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      addVM()
      return true
    }
    return false
  }

  @objc private func addVM() {
    let name = normalizedInputName
    guard !name.isEmpty else { return }
    guard !configurations.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    else {
      showAlert(
        title: localized("Name already exists"),
        message: localized("“%@” is already in the VM list.", name))
      return
    }

    let configuration = VMConfiguration(name: name)
    configurations.append(configuration)
    states[configuration.id] = .unknown
    saveConfigurations()
    nameField.stringValue = ""
    searchField.stringValue = ""
    tableView.reloadData()
    if let row = visibleConfigurations.firstIndex(where: { $0.id == configuration.id }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      tableView.scrollRowToVisible(row)
    }
    refreshUI()
  }

  @objc private func deleteSelectedVM() {
    let selected = selectedConfigurations
    let capabilities = selectionCapabilities
    guard !selected.isEmpty else { return }
    guard capabilities.canRemoveRecords else {
      showAlert(
        title: localized("Unable to remove selected records"),
        message: localized(
          "Only saved records that are missing locally and not running can be removed. This button never deletes VM disks."
        ))
      return
    }
    if selected.count > 1 {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = localized("Remove %d VM record(s)?", selected.count)
      alert.informativeText = localized(
        "Only the records saved by TartR will be removed. No VM disks will be deleted.")
      alert.addButton(withTitle: localized("Remove Records"))
      alert.addButton(withTitle: localized("Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    let row = selectedRow ?? 0
    let selectedIDs = Set(selected.map(\.id))
    configurations.removeAll { selectedIDs.contains($0.id) }
    for id in selectedIDs { states.removeValue(forKey: id) }
    saveConfigurations()
    tableView.reloadData()
    if !visibleConfigurations.isEmpty {
      tableView.selectRowIndexes(
        IndexSet(integer: min(row, visibleConfigurations.count - 1)), byExtendingSelection: false)
    }
    refreshUI()
  }

  @objc private func startSelectedVM() {
    let ids = selectionCapabilities.startableIDs
    for id in ids { startVM(id: id, verifyFirst: true) }
  }

  @objc private func stopSelectedVM() {
    let ids = selectionCapabilities.stoppableIDs
    for id in ids { stopVM(id: id) }
  }

  @objc private func toggleSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    if states[configuration.id]?.isRunning == true {
      stopVM(id: configuration.id)
    } else {
      startVM(id: configuration.id, verifyFirst: true)
    }
  }

  @objc private func toggleAutoStart(_ sender: NSSwitch) {
    let visible = visibleConfigurations
    guard visible.indices.contains(sender.tag),
      let index = configurations.firstIndex(where: { $0.id == visible[sender.tag].id })
    else { return }
    configurations[index].autoStart = sender.state == .on
    saveConfigurations()
  }

  @objc private func searchChanged() {
    refreshUI(forceTableReload: true)
  }

  @objc private func openSelectedLog() {
    guard let configuration = selectedConfiguration else { return }
    let url = logURL(for: configuration)
    ensureLogExists(at: url)
    NSWorkspace.shared.open(url)
  }

  @objc private func copyInstallCommandAndOpenTerminal() {
    let command =
      "if brew help trust >/dev/null 2>&1; then brew trust --formula cirruslabs/cli/softnet; fi && brew install cirruslabs/cli/tart"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    showAlert(
      title: localized("Installation command copied"),
      message: localized(
        "Press ⌘V in Terminal, then press Return:\n\n%@\n\nTartR will detect the installation automatically.",
        command))
  }

  @objc private func openQuickStart() {
    NSWorkspace.shared.open(URL(string: "https://tart.run/quick-start/")!)
  }

  @objc private func checkForUpdates() {
    performUpdateCheck(manual: true)
  }

  @objc private func toggleAutomaticUpdateChecks() {
    let defaults = UserDefaults.standard
    defaults.set(!defaults.bool(forKey: automaticUpdateChecksKey), forKey: automaticUpdateChecksKey)
    updateAutomaticUpdateMenuItem()
    checkForUpdatesIfDue()
  }

  private func updateAutomaticUpdateMenuItem() {
    let isConfigured = configuredUpdateManifestURL != nil
    automaticUpdateMenuItem?.isEnabled = isConfigured
    automaticUpdateMenuItem?.state =
      isConfigured && UserDefaults.standard.bool(forKey: automaticUpdateChecksKey) ? .on : .off
  }

  private func checkForUpdatesIfDue() {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: automaticUpdateChecksKey), configuredUpdateManifestURL != nil else {
      return
    }
    if let lastCheck = defaults.object(forKey: lastUpdateCheckKey) as? Date,
      Date().timeIntervalSince(lastCheck) < 24 * 60 * 60
    {
      return
    }
    performUpdateCheck(manual: false)
  }

  private func performUpdateCheck(manual: Bool) {
    guard updateLoader == nil, updateDownloader == nil else { return }
    guard let manifestURL = configuredUpdateManifestURL else {
      if manual {
        showAlert(
          title: localized("No update source is configured for this build"),
          message: localized(
            "Local development builds do not connect to the network by default. Release builds can configure an HTTPS update source with UPDATE_MANIFEST_URL."
          ))
      }
      return
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    var request = URLRequest(url: manifestURL)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    request.setValue("TartR/\(version)", forHTTPHeaderField: "User-Agent")
    let loader = LimitedHTTPDataLoader(maximumBytes: 1_024 * 1_024) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        self?.handleUpdateResponse(data: data, response: response, error: error, manual: manual)
      }
    }
    updateLoader = loader
    loader.start(request: request, configuration: configuration)
  }

  private func handleUpdateResponse(
    data: Data?, response: URLResponse?, error: Error?, manual: Bool
  ) {
    updateLoader = nil
    guard !isQuitting else { return }

    guard error == nil,
      let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode == 200,
      SecureURLValidation.isSecureHTTPS(httpResponse.url),
      let data, data.count <= 1_024 * 1_024,
      let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
      let validated = UpdateManifestValidation.validate(manifest)
    else {
      if manual {
        showAlert(
          title: localized("Unable to check for updates"),
          message: error?.localizedDescription
            ?? localized("The update server returned an invalid response."))
      }
      return
    }
    UserDefaults.standard.set(Date(), forKey: lastUpdateCheckKey)

    let currentVersionString =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    guard let currentVersion = AppVersion(currentVersionString) else {
      if manual {
        showAlert(
          title: localized("Unable to check for updates"),
          message: localized("The current app version is invalid.")
        )
      }
      return
    }
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let systemVersion = AppVersion(
      "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
    guard systemVersion >= validated.minimumSystemVersion else {
      if manual {
        showAlert(
          title: localized("The latest version requires a newer macOS"),
          message: localized(
            "The latest TartR requires macOS %@ or later.", manifest.minimumSystemVersion))
      }
      return
    }
    guard validated.version > currentVersion else {
      if manual {
        showAlert(
          title: localized("TartR is up to date"),
          message: localized("Current version: %@", currentVersionString))
      }
      return
    }

    showWindow()
    let alert = NSAlert()
    alert.messageText = localized("TartR %@ is available", manifest.version)
    let sizeDescription =
      validated.fileSize.map {
        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
      } ?? localized("Not provided by the manifest")
    alert.informativeText =
      localized(
        "Current version: %@\nDMG size: %@\nSHA-256:\n%@", currentVersionString, sizeDescription,
        validated.sha256)
    alert.addButton(
      withTitle: validated.fileSize == nil
        ? localized("Download in Browser") : localized("Securely Download DMG"))
    alert.addButton(withTitle: localized("View Release Notes"))
    alert.addButton(withTitle: localized("Later"))
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      if let expectedSize = validated.fileSize {
        beginSecureUpdateDownload(
          manifest: validated, expectedSize: expectedSize, version: manifest.version)
      } else {
        NSWorkspace.shared.open(validated.downloadURL)
      }
    case .alertSecondButtonReturn:
      NSWorkspace.shared.open(validated.releaseNotesURL)
    default:
      break
    }
  }

  private func beginSecureUpdateDownload(
    manifest: ValidatedUpdateManifest, expectedSize: UInt64, version: String
  ) {
    guard updateDownloader == nil, operationProcess == nil else {
      showAlert(
        title: localized("An operation is already in progress"),
        message: localized("Wait for the current operation to finish or cancel it first."))
      return
    }
    let panel = NSSavePanel()
    panel.title = localized("Download and Verify TartR Update")
    panel.message = localized(
      "TartR will save the DMG only after both file size and SHA-256 verification succeed.")
    panel.prompt = localized("Download")
    panel.allowedContentTypes = [.diskImage]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = manifest.downloadURL.lastPathComponent
    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    {
      panel.directoryURL = downloads
    }
    guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
    guard
      confirmStorageCapacity(
        operation: localized("Download TartR %@ update", version),
        operationBytes: expectedSize,
        at: destinationURL.deletingLastPathComponent(),
        offersCacheCleanup: false)
    else { return }

    var request = URLRequest(url: manifest.downloadURL)
    request.setValue(
      "application/x-apple-diskimage, application/octet-stream", forHTTPHeaderField: "Accept")
    request.setValue("TartR/\(currentAppVersionString)", forHTTPHeaderField: "User-Agent")
    var downloader: SecureUpdateDownloader!
    downloader = SecureUpdateDownloader(
      expectedSize: expectedSize,
      expectedSHA256: manifest.sha256,
      destinationURL: destinationURL,
      progress: { [weak self] received, total in
        guard let self else { return }
        let percent = total == 0 ? 0 : min(100, Int(received * 100 / total))
        self.operationLabel?.stringValue =
          localized(
            "Securely downloading TartR %@… %d%% (%@ / %@)", version, percent,
            self.storageByteString(received), self.storageByteString(total))
      },
      completion: { [weak self, weak downloader] result in
        guard let self, let downloader, self.updateDownloader === downloader else { return }
        self.updateDownloader = nil
        self.hideOperation()
        guard !self.isQuitting else { return }
        switch result {
        case .success(let url):
          self.presentVerifiedUpdate(at: url, version: version)
        case .failure(let error):
          if (error as? URLError)?.code != .cancelled {
            self.showAlert(
              title: localized("Update download failed"), message: error.localizedDescription)
          }
        }
        self.refreshUI()
      })
    updateDownloader = downloader
    showOperation(localized("Securely downloading TartR %@…", version))
    downloader.start(request: request)
  }

  private func presentVerifiedUpdate(at url: URL, version: String) {
    showWindow()
    let alert = NSAlert()
    alert.messageText = localized("TartR %@ was securely downloaded", version)
    alert.informativeText = localized(
      "The DMG passed file size and SHA-256 verification. TartR will not install or run the update automatically."
    )
    alert.addButton(withTitle: localized("Open DMG"))
    alert.addButton(withTitle: localized("Show in Finder"))
    alert.addButton(withTitle: localized("Close"))
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      NSWorkspace.shared.open(url)
    case .alertSecondButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([url])
    default:
      break
    }
  }

  @objc private func chooseTartExecutable() {
    guard operationProcess == nil, updateDownloader == nil, !syncInProgress else {
      showAlert(
        title: localized("Choose Tart later"),
        message: localized(
          "Wait for the current Tart operation or state synchronization to finish before changing the executable."
        ))
      return
    }
    let panel = NSOpenPanel()
    panel.title = localized("Choose Tart Executable")
    panel.message = localized(
      "Choose an executable tart file from a trusted source. The path is stored only on this Mac.")
    panel.prompt = localized("Use This Tart")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let current = tartExecutableURL {
      panel.directoryURL = current.deletingLastPathComponent()
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      showAlert(
        title: localized("Unable to use the selected file"),
        message: localized("The file does not exist or is not executable."))
      return
    }
    validateAndSaveTartExecutable(url.standardizedFileURL)
  }

  @objc private func resetTartExecutable() {
    guard operationProcess == nil, updateDownloader == nil, !syncInProgress else {
      showAlert(
        title: localized("Restore automatic detection later"),
        message: localized(
          "Wait for the current Tart operation or state synchronization to finish before changing the executable."
        ))
      return
    }
    UserDefaults.standard.removeObject(forKey: tartExecutablePathKey)
    appendApplicationLog(localized("Restored automatic Tart executable detection."))
    resyncAfterTartExecutableChange()
  }

  @objc private func chooseTartHome() {
    guard canChangeTartHome else {
      showAlert(
        title: localized("Change Tart Home Later"),
        message: localized(
          "Stop all VMs started by TartR and wait for active operations and synchronization to finish before changing TART_HOME."
        ))
      return
    }
    let panel = NSOpenPanel()
    panel.title = localized("Choose Tart Home Directory")
    panel.message = localized(
      "TartR will set TART_HOME for every Tart command and remember this directory. VM settings are stored separately for each Tart home."
    )
    panel.prompt = localized("Use This Directory")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if let path = resolvedTartHome.path {
      panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let path = url.standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      showAlert(
        title: localized("Unable to Use Tart Home"),
        message: localized("The selected directory does not exist or is not accessible."))
      return
    }
    switchTartHome(configuredPath: path)
  }

  @objc private func resetTartHome() {
    guard canChangeTartHome else {
      showAlert(
        title: localized("Change Tart Home Later"),
        message: localized(
          "Stop all VMs started by TartR and wait for active operations and synchronization to finish before changing TART_HOME."
        ))
      return
    }
    switchTartHome(configuredPath: nil)
  }

  private func switchTartHome(configuredPath: String?) {
    saveConfigurations()
    if let configuredPath {
      UserDefaults.standard.set(configuredPath, forKey: tartHomePathKey)
      appendApplicationLog(localized("Selected Tart home directory: %@", configuredPath))
    } else {
      UserDefaults.standard.removeObject(forKey: tartHomePathKey)
      appendApplicationLog(localized("Restored TART_HOME environment or Tart default directory."))
    }
    configurations.removeAll()
    states.removeAll()
    discoveredNames.removeAll()
    infoByName.removeAll()
    tartSyncError = nil
    configurationRecoveryNotice = nil
    lastTableSignature = nil
    searchField.stringValue = ""
    loadConfigurations()
    refreshUI(forceTableReload: true)
    restoreSelection()
    syncTartState()
  }

  private func validateAndSaveTartExecutable(_ url: URL) {
    let process = Process()
    process.executableURL = url
    process.arguments = TartCommand.version.arguments
    let outputCapture = BoundedProcessOutput(maximumBytes: maximumCommandOutputBytes)
    outputCapture.attach(to: process)
    do {
      try process.run()
      outputCapture.processDidStart()
    } catch {
      _ = outputCapture.finish()
      showAlert(
        title: localized("Unable to run the selected file"), message: error.localizedDescription)
      return
    }
    operationProcess = process
    operationOutputCapture = outputCapture
    operationWasCancelled = false
    showOperation(localized("Validating Tart executable…"))

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let completed = ProcessDeadline.waitForExit(process, timeout: 5)
      let captured = outputCapture.finish()
      let output = captured.text
      DispatchQueue.main.async {
        guard let self else { return }
        let wasCancelled = self.operationWasCancelled
        if self.operationProcess === process { self.operationProcess = nil }
        self.operationWasCancelled = false
        self.hideOperation()
        guard !self.isQuitting, !wasCancelled else { return }
        guard !captured.wasTruncated, completed, process.terminationStatus == 0,
          TartVersionValidation.isPlausible(output)
        else {
          let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
          let reason =
            captured.wasTruncated
            ? localized("The selected file's version output exceeds the 1 MB safety limit.")
            : completed
              ? (detail.isEmpty
                ? localized("The selected file did not return a recognizable Tart version.")
                : String(detail.suffix(1000)))
              : localized(
                "The selected file took more than 5 seconds to run --version and was terminated.")
          self.showAlert(
            title: localized("The selected file is not a usable Tart executable"), message: reason)
          return
        }
        UserDefaults.standard.set(url.path, forKey: tartExecutablePathKey)
        self.appendApplicationLog(
          localized(
            "Validated and selected custom Tart executable: %@ (%@)", url.path,
            output.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        self.resyncAfterTartExecutableChange()
      }
    }
  }

  @objc private func cancelOperation() {
    if let updateDownloader {
      operationLabel?.stringValue = localized("Cancelling update download…")
      cancelOperationButton?.isEnabled = false
      updateDownloader.cancel()
      return
    }
    guard let process = operationProcess else { return }
    operationWasCancelled = true
    operationLabel?.stringValue = localized("Cancelling operation…")
    cancelOperationButton?.isEnabled = false
    process.interrupt()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak process] in
      guard let self, let process,
        self.operationProcess === process, process.isRunning
      else { return }
      kill(process.processIdentifier, SIGKILL)
    }
  }

  @objc private func downloadImage() {
    guard tartInstalled else {
      showAlert(
        title: localized("Install Tart first"),
        message: localized("Use the installation guide above before downloading an image."))
      return
    }

    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    for item in imageCatalog { popup.addItem(withTitle: "\(item.os) · \(item.kind)") }
    popup.selectItem(at: 1)
    popup.target = self
    popup.action = #selector(catalogSelectionChanged(_:))
    let target = NSTextField(string: imageCatalog[1].suggestedName)
    let source = NSTextField(string: imageCatalog[1].source)
    source.isEditable = true
    catalogTargetField = target
    catalogSourceField = source

    let accessory = labeledForm(
      [
        (localized("Official Image"), popup),
        (localized("Local Name"), target),
        (localized("Image Address (Editable)"), source),
      ], width: 470)
    let alert = NSAlert()
    alert.messageText = localized("Download and Clone Image")
    alert.informativeText = localized(
      "Images are typically about 25 GB. Download time depends on network speed. The default username and password are both admin."
    )
    alert.accessoryView = accessory
    alert.addButton(withTitle: localized("Start Download"))
    alert.addButton(withTitle: localized("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else {
      catalogTargetField = nil
      catalogSourceField = nil
      return
    }

    let item = imageCatalog[max(0, popup.indexOfSelectedItem)]
    let name = target.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedSource = source.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    catalogTargetField = nil
    catalogSourceField = nil
    guard validNewVMName(name) else { return }
    guard !selectedSource.isEmpty else {
      showAlert(
        title: localized("Invalid image address"),
        message: localized("Enter an OCI image address or the name of a local source VM."))
      return
    }
    guard
      confirmStorageCapacity(
        operation: localized("Download and clone image"),
        operationBytes: 30 * 1_024 * 1_024 * 1_024,
        at: tartStorageURL,
        offersCacheCleanup: true)
    else { return }
    runManagedTartCommand(
      TartCommand.clone(source: selectedSource, name: name).arguments,
      title: localized("Downloading %@ · %@…", item.os, item.kind)
    ) { [weak self] success, _ in
      if success { self?.syncAndSelect(name: name) }
    }
  }

  @objc private func catalogSelectionChanged(_ sender: NSPopUpButton) {
    let index = max(0, sender.indexOfSelectedItem)
    guard imageCatalog.indices.contains(index) else { return }
    catalogTargetField?.stringValue = imageCatalog[index].suggestedName
    catalogSourceField?.stringValue = imageCatalog[index].source
  }

  @objc private func showMoreMenu(_ sender: NSButton) {
    let menu = NSMenu()
    let state = selectedConfiguration.flatMap { states[$0.id] } ?? .unknown
    addMenuItem(
      localized("View Details…"), #selector(showSelectedDetails), to: menu,
      enabled: selectedConfiguration != nil)
    menu.addItem(.separator())
    addMenuItem(localized("Import .tvm Archive…"), #selector(importVMArchive), to: menu)
    addMenuItem(
      localized("Export as .tvm Archive…"), #selector(exportSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning
        && selectedConfiguration.map { discoveredNames.contains($0.name) } == true)
    addMenuItem(
      localized("Clone VM…"), #selector(cloneSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      localized("Rename…"), #selector(renameSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      localized("Configure…"), #selector(configureSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      localized("Run Options…"), #selector(configureSelectedVMRunOptions), to: menu,
      enabled: selectedConfiguration != nil)
    addMenuItem(
      localized("Push to OCI Registry…"), #selector(pushSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    #if arch(arm64)
      addMenuItem(
        localized("Run Once in Suspendable Mode"), #selector(startSelectedVMSuspendable), to: menu,
        enabled: selectedConfiguration != nil && !state.isRunning)
    #endif
    menu.addItem(.separator())
    addMenuItem(
      localized("Copy IP Address"), #selector(copySelectedIP), to: menu, enabled: state.isRunning)
    addMenuItem(
      localized("Copy SSH Command and Open Terminal…"), #selector(copySSHCommandAndOpenTerminal),
      to: menu,
      enabled: selectedConfiguration != nil && state.isRunning)
    addMenuItem(
      localized("Execute Command in VM…"), #selector(executeCommandInSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && state.isRunning)
    addMenuItem(
      localized("Suspend VM"), #selector(suspendSelectedVM), to: menu, enabled: state.isRunning)
    menu.addItem(.separator())
    addMenuItem(localized("Create macOS VM from Latest IPSW…"), #selector(createMacVM), to: menu)
    addMenuItem(localized("Create Blank Linux VM…"), #selector(createLinuxVM), to: menu)
    addMenuItem(localized("Prune Tart Download Cache…"), #selector(pruneCaches), to: menu)
    menu.addItem(.separator())
    addMenuItem(
      localized("Delete VM and Disk…"), #selector(deleteVMAndDisk), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning
        && selectedConfiguration.map { discoveredNames.contains($0.name) } == true)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func cloneSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      let values = promptForValues(
        title: localized("Clone VM"),
        message: localized("Create a local copy using APFS copy-on-write."),
        fields: [
          (localized("Source VM"), configuration.name, false),
          (localized("New Name"), "\(configuration.name)-copy", true),
        ])
    else { return }
    let newName = values[1]
    guard validNewVMName(newName) else { return }
    runManagedTartCommand(
      TartCommand.clone(source: configuration.name, name: newName).arguments,
      title: localized("Cloning %@…", configuration.name)
    ) { [weak self] success, _ in
      if success { self?.syncAndSelect(name: newName) }
    }
  }

  @objc private func importVMArchive() {
    let panel = NSOpenPanel()
    panel.title = localized("Import Tart VM Archive")
    panel.message = localized("Choose a .tvm file created by tart export.")
    panel.allowedContentTypes = [UTType(filenameExtension: "tvm") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

    let suggestedName = archiveURL.deletingPathExtension().lastPathComponent
    guard
      let values = promptForValues(
        title: localized("Import VM"),
        message: localized("Archive: %@", archiveURL.lastPathComponent),
        fields: [(localized("Local Name"), suggestedName, true)])
    else { return }
    let name = values[0]
    guard validNewVMName(name) else { return }
    let archiveSize =
      (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    let doubledArchiveSize = archiveSize.multipliedReportingOverflow(by: 2)
    let estimatedImportBytes = max(
      doubledArchiveSize.overflow ? UInt64.max : doubledArchiveSize.partialValue,
      20 * 1_024 * 1_024 * 1_024)
    guard
      confirmStorageCapacity(
        operation: localized("Import VM archive"),
        operationBytes: estimatedImportBytes,
        at: tartStorageURL,
        offersCacheCleanup: true)
    else { return }
    runManagedTartCommand(
      TartCommand.importArchive(path: archiveURL.path, name: name).arguments,
      title: localized("Importing %@…", archiveURL.lastPathComponent)
    ) { [weak self] success, _ in
      if success { self?.syncAndSelect(name: name) }
    }
  }

  @objc private func exportSelectedVM() {
    guard let configuration = selectedConfiguration,
      discoveredNames.contains(configuration.name),
      states[configuration.id]?.isRunning != true
    else { return }

    let panel = NSSavePanel()
    panel.title = localized("Export Tart VM Archive")
    panel.message = localized(
      "Exporting may take a long time and use disk space close to the VM's actual size.")
    panel.allowedContentTypes = [UTType(filenameExtension: "tvm") ?? .data]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(configuration.name).tvm"
    guard panel.runModal() == .OK, let archiveURL = panel.url else { return }
    let estimatedGB = max(infoByName[configuration.name]?.size ?? 20, 1)
    guard
      confirmStorageCapacity(
        operation: localized("Export VM archive"),
        operationBytes: UInt64(estimatedGB) * 1_024 * 1_024 * 1_024,
        at: archiveURL.deletingLastPathComponent(),
        offersCacheCleanup: false)
    else { return }

    runManagedTartCommand(
      TartCommand.exportArchive(name: configuration.name, path: archiveURL.path).arguments,
      title: localized("Exporting %@…", configuration.name)
    ) { success, _ in
      if success { NSWorkspace.shared.activateFileViewerSelecting([archiveURL]) }
    }
  }

  @objc private func showSelectedDetails() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.get(name: configuration.name).arguments,
      title: localized("Reading %@ configuration…", configuration.name), showsSuccessAlert: false
    ) { [weak self] success, output in
      guard success, let self else { return }
      var details = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = details.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let prettyData = try? JSONSerialization.data(
          withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
        let pretty = String(data: prettyData, encoding: .utf8)
      {
        details = pretty
      }
      self.showTextViewer(
        title: configuration.name,
        text: details.isEmpty ? localized("Tart returned no configuration details.") : details)
    }
  }

  @objc private func renameSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      let values = promptForValues(
        title: localized("Rename VM"), message: localized("The VM must be stopped."),
        fields: [
          (localized("Current Name"), configuration.name, false),
          (localized("New Name"), configuration.name, true),
        ])
    else { return }
    let newName = values[1]
    guard newName != configuration.name, validNewVMName(newName) else { return }
    runManagedTartCommand(
      TartCommand.rename(name: configuration.name, newName: newName).arguments,
      title: localized("Renaming…")
    ) { [weak self] success, _ in
      guard success, let self,
        let index = self.configurations.firstIndex(where: { $0.id == configuration.id })
      else { return }
      self.configurations[index].name = newName
      self.saveConfigurations()
      self.syncAndSelect(name: newName)
    }
  }

  @objc private func configureSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    let cpuField = configurationField(placeholder: localized("Unchanged"))
    let memoryField = configurationField(placeholder: localized("Unchanged"))
    let displayField = configurationField(placeholder: localized("e.g. 1920x1080px"))
    let diskSizeField = configurationField(placeholder: localized("Grow only"))
    let displayRefit = NSPopUpButton(frame: .zero, pullsDown: false)
    displayRefit.addItems(withTitles: [
      localized("Keep Current"), localized("Enable"), localized("Disable"),
    ])

    let diskPathField = configurationField(placeholder: localized("No replacement selected"))
    diskPathField.isEditable = false
    diskPathField.isSelectable = true
    let chooseDiskButton = NSButton(
      title: localized("Choose…"), target: self, action: #selector(chooseReplacementDisk))
    chooseDiskButton.bezelStyle = .rounded
    let diskRow = NSStackView(views: [diskPathField, chooseDiskButton])
    diskRow.orientation = .horizontal
    diskRow.spacing = 8

    let form = labeledForm(
      [
        (localized("CPU Cores"), cpuField),
        (localized("Memory (MB)"), memoryField),
        (localized("Display Resolution"), displayField),
        (localized("Display Refit"), displayRefit),
        (localized("Disk Size (GB)"), diskSizeField),
        (localized("Replacement Disk"), diskRow),
      ], width: 520)

    let randomMAC = NSButton(
      checkboxWithTitle: localized("Generate a new random MAC address"), target: nil, action: nil)
    let randomSerial = NSButton(
      checkboxWithTitle: localized("Generate a new random macOS serial number"), target: nil,
      action: nil)
    let identityOptions = NSStackView(views: [randomMAC, randomSerial])
    identityOptions.orientation = .vertical
    identityOptions.alignment = .leading
    identityOptions.spacing = 7

    let sectionTitle = NSTextField(labelWithString: localized("Identity Options"))
    sectionTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let warning = NSTextField(
      wrappingLabelWithString: localized(
        "Leave fields unchanged unless needed. Replacing disk contents is destructive; disk size can only increase."
      ))
    warning.textColor = .secondaryLabelColor
    warning.font = NSFont.systemFont(ofSize: 11)

    let accessory = NSStackView(views: [form, sectionTitle, identityOptions, warning])
    accessory.orientation = .vertical
    accessory.alignment = .leading
    accessory.spacing = 10
    accessory.frame = NSRect(x: 0, y: 0, width: 520, height: 290)
    pendingReplacementDiskField = diskPathField
    defer { pendingReplacementDiskField = nil }

    let alert = NSAlert()
    alert.messageText = localized("Hardware & Identity · %@", configuration.name)
    alert.informativeText = localized("Modify the stopped VM using tart set.")
    alert.accessoryView = accessory
    alert.addButton(withTitle: localized("Apply Changes"))
    alert.addButton(withTitle: localized("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let values = [cpuField, memoryField, displayField, diskSizeField].map {
      $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    switch VMResourceValidation.validate(
      cpu: values[0], memory: values[1], display: values[2], diskSize: values[3])
    {
    case .valid:
      break
    case .invalidCPU:
      showAlert(
        title: localized("Invalid CPU configuration"),
        message: localized("CPU cores must be an integer from 1 to 65535."))
      return
    case .invalidMemory:
      showAlert(
        title: localized("Invalid memory configuration"),
        message: localized("Memory must be a positive integer in MB."))
      return
    case .invalidDisplay:
      showAlert(
        title: localized("Invalid display configuration"),
        message: localized("Enter WIDTHxHEIGHT, WIDTHxHEIGHTpt, or WIDTHxHEIGHTpx."))
      return
    case .invalidDiskSize:
      showAlert(
        title: localized("Invalid disk configuration"),
        message: localized("Disk size must be an integer from 1 to 65535 GB."))
      return
    }

    let diskPath = diskPathField.stringValue.isEmpty ? nil : diskPathField.stringValue
    if let diskPath {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: diskPath, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        showAlert(
          title: localized("Invalid replacement disk"),
          message: localized("The selected disk image no longer exists or is not a file."))
        return
      }
      let confirmation = NSAlert()
      confirmation.alertStyle = .critical
      confirmation.messageText = localized("Replace %@ disk contents?", configuration.name)
      confirmation.informativeText = localized(
        "This overwrites the VM disk with %@ and cannot be undone. The VM must remain stopped.",
        URL(fileURLWithPath: diskPath).lastPathComponent)
      confirmation.addButton(withTitle: localized("Replace Disk Contents"))
      confirmation.addButton(withTitle: localized("Cancel"))
      guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    }

    let arguments = TartCommand.set(
      name: configuration.name,
      cpu: values[0].isEmpty ? nil : values[0],
      memory: values[1].isEmpty ? nil : values[1],
      display: values[2].isEmpty ? nil : values[2],
      displayRefit: displayRefit.indexOfSelectedItem == 0
        ? nil : displayRefit.indexOfSelectedItem == 1,
      randomMAC: randomMAC.state == .on,
      randomSerial: randomSerial.state == .on,
      diskPath: diskPath,
      diskSize: values[3].isEmpty ? nil : values[3]
    ).arguments
    guard arguments.count > 2 else { return }
    runManagedTartCommand(arguments, title: localized("Updating VM configuration…")) {
      [weak self] success, _ in
      if success { self?.syncTartState() }
    }
  }

  private func configurationField(placeholder: String) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = placeholder
    field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    return field
  }

  @objc private func chooseReplacementDisk() {
    let panel = NSOpenPanel()
    panel.title = localized("Choose Replacement Disk")
    panel.message = localized(
      "Choose a disk image whose contents will replace the VM's current disk. No shell command is used."
    )
    panel.prompt = localized("Choose Disk")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    pendingReplacementDiskField?.stringValue = url.standardizedFileURL.path
  }

  @objc private func configureSelectedVMRunOptions() {
    guard let configuration = selectedConfiguration else { return }
    let options = configuration.runOptions
    let headless = NSButton(
      checkboxWithTitle: localized("Headless (--no-graphics)"), target: nil, action: nil)
    headless.state = options.headless ? .on : .off
    let noAudio = NSButton(
      checkboxWithTitle: localized("Disable Audio Passthrough (--no-audio)"), target: nil,
      action: nil)
    noAudio.state = options.noAudio ? .on : .off
    let noClipboard = NSButton(
      checkboxWithTitle: localized("Disable Host–VM Clipboard Sharing (--no-clipboard)"),
      target: nil,
      action: nil)
    noClipboard.state = options.noClipboard ? .on : .off
    let suspendable = NSButton(
      checkboxWithTitle: localized("Use Suspendable Mode (--suspendable)"), target: nil, action: nil
    )
    #if arch(arm64)
      suspendable.state = options.suspendable ? .on : .off
    #else
      suspendable.state = .off
      suspendable.isEnabled = false
      suspendable.toolTip = localized("Suspendable mode is available only on Apple Silicon")
    #endif

    let stack = NSStackView(views: [headless, noAudio, noClipboard, suspendable])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 410, height: 112)
    let alert = NSAlert()
    alert.messageText = localized("Run Options for %@", configuration.name)
    alert.informativeText = localized(
      "These options apply to Run, double-clicking, and automatic startup when TartR opens.")
    alert.accessoryView = stack
    alert.addButton(withTitle: localized("Save"))
    alert.addButton(withTitle: localized("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn,
      let index = configurations.firstIndex(where: { $0.id == configuration.id })
    else { return }
    #if arch(arm64)
      let usesSuspendableMode = suspendable.state == .on
    #else
      let usesSuspendableMode = false
    #endif
    configurations[index].runOptions = VMRunOptions(
      headless: headless.state == .on,
      noAudio: noAudio.state == .on,
      noClipboard: noClipboard.state == .on,
      suspendable: usesSuspendableMode)
    saveConfigurations()
  }

  @objc private func pushSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      let values = promptForValues(
        title: localized("Push to OCI Registry"),
        message: localized(
          "Registry credentials are managed by Tart, Docker credential helpers, or environment variables. TartR does not store passwords."
        ),
        fields: [
          (localized("Local VM"), configuration.name, false),
          (localized("Remote Address"), localized("ghcr.io/organization/image:latest"), true),
        ])
    else { return }
    let remoteName = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remoteName.isEmpty, remoteName.contains("/") else {
      showAlert(
        title: localized("Invalid remote address"),
        message: localized("Enter a complete OCI address, such as ghcr.io/acme/macos:latest."))
      return
    }
    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = localized("Push %@?", configuration.name)
    confirmation.informativeText = localized(
      "The VM image will be uploaded to %@. This may take significant time and network bandwidth.",
      remoteName)
    confirmation.addButton(withTitle: localized("Start Push"))
    confirmation.addButton(withTitle: localized("Cancel"))
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    runManagedTartCommand(
      TartCommand.push(name: configuration.name, remoteName: remoteName).arguments,
      title: localized("Pushing %@…", configuration.name)
    ) { _, _ in }
  }

  @objc private func pruneCaches() {
    guard
      let values = promptForValues(
        title: localized("Prune Tart Download Cache"),
        message: localized(
          "Only re-downloadable OCI/IPSW cache data is removed. Local VMs are not deleted. Enter at least one condition."
        ),
        fields: [
          (localized("Older Than (Days)"), "30", true),
          (localized("Cache Limit (GB)"), "", true),
        ])
    else { return }
    let olderThan = values[0]
    let spaceBudget = values[1]
    guard olderThan.isEmpty || UInt(olderThan) != nil,
      spaceBudget.isEmpty || UInt(spaceBudget) != nil,
      !olderThan.isEmpty || !spaceBudget.isEmpty
    else {
      showAlert(
        title: localized("Invalid prune conditions"),
        message: localized("Enter at least one non-negative integer condition."))
      return
    }
    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = localized("Prune Tart cache?")
    confirmation.informativeText = localized(
      "Removed OCI image layers or IPSW files must be downloaded again when next used.")
    confirmation.addButton(withTitle: localized("Start Pruning"))
    confirmation.addButton(withTitle: localized("Cancel"))
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    runManagedTartCommand(
      TartCommand.pruneCaches(
        olderThan: olderThan.isEmpty ? nil : olderThan,
        spaceBudget: spaceBudget.isEmpty ? nil : spaceBudget
      ).arguments,
      title: localized("Pruning Tart cache…")
    ) { _, _ in }
  }

  @objc private func copySelectedIP() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.ip(name: configuration.name, wait: 5).arguments,
      title: localized("Getting IP address…"),
      showsSuccessAlert: false
    ) { success, output in
      guard success else { return }
      let ip = output.trimmingCharacters(in: .whitespacesAndNewlines)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(ip, forType: .string)
      self.showAlert(title: localized("IP address copied"), message: ip)
    }
  }

  @objc private func copySSHCommandAndOpenTerminal() {
    guard let configuration = selectedConfiguration,
      let values = promptForValues(
        title: localized("Connect to %@", configuration.name),
        message: localized(
          "TartR remembers this VM's username, copies a safe SSH command, and opens Terminal without executing the command."
        ),
        fields: [(localized("SSH Username"), configuration.sshUsername, true)])
    else { return }
    let username = values[0]
    guard SSHConnectionCommand.isValidUsername(username) else {
      showAlert(
        title: localized("Invalid SSH username"),
        message: localized(
          "Enter 1–64 ASCII characters, starting with a letter or underscore, followed only by letters, digits, underscores, hyphens, or periods."
        ))
      return
    }
    guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
      return
    }
    configurations[index].sshUsername = username
    saveConfigurations()

    runManagedTartCommand(
      TartCommand.ip(name: configuration.name, wait: 5).arguments,
      title: localized("Getting IP address…"),
      showsSuccessAlert: false
    ) { success, output in
      guard success else { return }
      let host = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let command = SSHConnectionCommand.make(username: username, host: host) else {
        self.showAlert(
          title: localized("Unable to create SSH command"),
          message: localized(
            "Tart returned an address that could not be safely recognized. Refresh the status and try again."
          ))
        return
      }
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(command, forType: .string) else {
        self.showAlert(
          title: localized("Unable to copy SSH command"),
          message: localized("The system clipboard is unavailable. Try again later."))
        return
      }
      self.showAlert(
        title: localized("SSH command copied"),
        message: localized("Press ⌘V in Terminal, then press Return:\n\n%@", command))
      guard
        NSWorkspace.shared.open(
          URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
      else {
        self.showAlert(
          title: localized("Unable to open Terminal"),
          message: localized(
            "The SSH command is still on the clipboard. Open Terminal manually and paste it."))
        return
      }
    }
  }

  @objc private func suspendSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.suspend(name: configuration.name).arguments,
      title: localized("Suspending %@…", configuration.name)
    ) { [weak self] success, _ in
      if success { self?.syncTartState() }
    }
  }

  @objc private func executeCommandInSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
    else {
      showAlert(
        title: localized("macOS 14 or later is required"),
        message: localized("tart exec is available on host macOS 14 Sonoma or later."))
      return
    }
    guard
      let values = promptForValues(
        title: localized("Execute Command in %@", configuration.name),
        message: localized(
          "Tart Guest Agent must be running in the VM. The command runs only in the guest VM's /bin/zsh and never through the host shell."
        ),
        fields: [(localized("Shell Command"), "uname -a", true)])
    else { return }
    let command = values[0]
    guard GuestShellCommandValidation.validate(command) == .valid else {
      showAlert(
        title: localized("Invalid command"),
        message: localized(
          "The command cannot be empty, contain a null character, or exceed 4096 bytes."))
      return
    }
    runManagedTartCommand(
      TartCommand.execShell(name: configuration.name, command: command).arguments,
      title: localized("Executing command in %@…", configuration.name),
      showsSuccessAlert: false,
      showsFailureAlert: false
    ) { [weak self] success, output in
      guard let self else { return }
      let content = output.isEmpty ? localized("(The command produced no output)") : output
      self.showTextViewer(
        title: success ? localized("Command Completed") : localized("Command Failed"),
        text: "$ \(command)\n\n\(content)")
    }
  }

  @objc private func startSelectedVMSuspendable() {
    guard let id = selectedConfiguration?.id else { return }
    startVM(id: id, verifyFirst: true, suspendable: true)
  }

  @objc private func createMacVM() {
    createBlankVM(macOS: true)
  }

  @objc private func createLinuxVM() {
    createBlankVM(macOS: false)
  }

  private func createBlankVM(macOS: Bool) {
    #if arch(x86_64)
      if macOS {
        showAlert(
          title: localized("Apple Silicon is required"),
          message: localized("Tart can create macOS VMs only on Apple Silicon Macs."))
        return
      }
    #endif
    let defaultName = macOS ? "macos-vanilla" : "linux-vm"
    guard
      let values = promptForValues(
        title: macOS
          ? localized("Create macOS VM from Latest IPSW") : localized("Create Blank Linux VM"),
        message: macOS
          ? localized(
            "Tart will download Apple's latest supported IPSW. You must then complete system installation manually."
          ) : localized("After creation, mount an installation image with tart run --disk."),
        fields: [
          (localized("VM Name"), defaultName, true), (localized("Disk Size (GB)"), "50", true),
        ]
      )
    else { return }
    guard validNewVMName(values[0]) else { return }
    guard
      VMResourceValidation.validate(cpu: "", memory: "", display: "", diskSize: values[1])
        == .valid
    else {
      showAlert(
        title: localized("Invalid disk size"),
        message: localized("Enter an integer from 1 to 65535 GB."))
      return
    }
    guard
      confirmStorageCapacity(
        operation: macOS
          ? localized("Download IPSW and create macOS VM") : localized("Create Linux VM"),
        operationBytes: UInt64(macOS ? 30 : 5) * 1_024 * 1_024 * 1_024,
        at: tartStorageURL,
        offersCacheCleanup: true)
    else { return }
    let arguments =
      macOS
      ? TartCommand.createMac(name: values[0], diskSize: values[1]).arguments
      : TartCommand.createLinux(name: values[0], diskSize: values[1]).arguments
    runManagedTartCommand(
      arguments,
      title: macOS
        ? localized("Downloading IPSW and creating VM…") : localized("Creating Linux VM…")
    ) {
      [weak self] success, _ in
      if success { self?.syncAndSelect(name: values[0]) }
    }
  }

  @objc private func deleteVMAndDisk() {
    guard let configuration = selectedConfiguration else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = localized("Permanently delete %@?", configuration.name)
    alert.informativeText = localized(
      "This runs tart delete. The VM configuration and disk data cannot be recovered. Enter the VM name to confirm."
    )
    let confirmationField = NSTextField()
    confirmationField.placeholderString = configuration.name
    confirmationField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = confirmationField
    alert.addButton(withTitle: localized("Delete Permanently"))
    alert.addButton(withTitle: localized("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard confirmationField.stringValue == configuration.name else {
      showAlert(title: localized("Name does not match"), message: localized("No data was deleted."))
      return
    }
    runManagedTartCommand(
      TartCommand.delete(name: configuration.name).arguments,
      title: localized("Deleting %@…", configuration.name)
    ) { [weak self] success, _ in
      guard success, let self else { return }
      self.configurations.removeAll { $0.id == configuration.id }
      self.states.removeValue(forKey: configuration.id)
      self.saveConfigurations()
      self.syncTartState()
    }
  }

  @objc private func showWindow() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showAbout() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "TartR",
      .credits: NSAttributedString(
        string: localized("A native macOS manager for Tart virtual machines.\nhttps://tart.run/")),
    ])
  }

  @objc private func refreshNow() {
    syncTartState()
  }

  @objc private func openApplicationLog() {
    ensureLogExists(at: applicationLogURL)
    NSWorkspace.shared.open(applicationLogURL)
  }

  @objc private func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.title = localized("Export TartR Diagnostics")
    panel.message = localized(
      "The report does not contain VM names, log contents, or registry credentials.")
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = "TartR-Diagnostics-\(stamp).txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let report = diagnosticsReport()
    do {
      try Data(report.utf8).write(to: url, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      showAlert(
        title: localized("Unable to export diagnostics"), message: error.localizedDescription)
    }
  }

  @objc private func exportSettings() {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let document = TartRSettingsDocument(
      exportedByVersion: version, configurations: configurations)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(document) else {
      showAlert(
        title: localized("Unable to export settings"),
        message: localized("The VM settings could not be encoded."))
      return
    }

    let panel = NSSavePanel()
    panel.title = localized("Export TartR Settings")
    panel.message = localized(
      "The settings file contains VM names, run options, and SSH usernames, but no logs or registry credentials."
    )
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "TartR-Settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data.write(to: url, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      showAlert(title: localized("Unable to export settings"), message: error.localizedDescription)
    }
  }

  @objc private func importSettings() {
    guard operationProcess == nil, updateDownloader == nil,
      !runtimes.values.contains(where: { $0.process.isRunning })
    else {
      showAlert(
        title: localized("Unable to import settings right now"),
        message: localized("Wait for active tasks to finish and stop all VMs started by TartR."))
      return
    }
    let panel = NSOpenPanel()
    panel.title = localized("Import TartR Settings")
    panel.message = localized("Choose a JSON settings file exported by TartR.")
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024,
      let document = try? JSONDecoder().decode(TartRSettingsDocument.self, from: data)
    else {
      showAlert(
        title: localized("Invalid settings file"),
        message: localized(
          "The file cannot be read, exceeds 5 MB, or is not a valid TartR settings file."))
      return
    }
    switch TartRSettingsValidation.validate(document) {
    case .valid:
      break
    case .unsupportedSchema(let version):
      showAlert(
        title: localized("Unsupported settings version"),
        message: localized(
          "The file uses settings format version %d, which this TartR cannot import.", version))
      return
    case .duplicateID, .duplicateName:
      showAlert(
        title: localized("Conflicting settings"),
        message: localized("The file contains duplicate VM identifiers or names."))
      return
    case .invalidName:
      showAlert(
        title: localized("Invalid VM name in settings"),
        message: localized(
          "VM names cannot be empty, contain /, or have leading or trailing whitespace."))
      return
    case .invalidSSHUsername:
      showAlert(
        title: localized("Invalid SSH username in settings"),
        message: localized("An SSH username contains unsafe characters or has an invalid length."))
      return
    }

    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = localized(
      "Import settings for %d VM(s)?", document.configurations.count)
    confirmation.informativeText =
      localized(
        "This replaces %d currently saved setting(s). TartR will back up the current valid configuration and rediscover local VMs.",
        configurations.count)
    confirmation.addButton(withTitle: localized("Import and Replace"))
    confirmation.addButton(withTitle: localized("Cancel"))
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }

    configurations = document.configurations
    states = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, VMState.unknown) })
    searchField.stringValue = ""
    lastTableSignature = nil
    UserDefaults.standard.removeObject(forKey: activeSelectedVMKey)
    saveConfigurations()
    refreshUI(forceTableReload: true)
    restoreSelection()
    syncTartState()
  }

  @objc private func showEnvironmentInfo() {
    if !tartInstalled {
      showTextViewer(
        title: localized("Runtime Environment"),
        text: environmentReport(tartVersion: localized("Not installed")))
      return
    }
    runManagedTartCommand(
      TartCommand.version.arguments,
      title: localized("Reading Tart version…"),
      showsSuccessAlert: false,
      showsFailureAlert: false
    ) { [weak self] success, output in
      guard let self else { return }
      let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
      self.showTextViewer(
        title: localized("Runtime Environment"),
        text: self.environmentReport(
          tartVersion: success && !value.isEmpty ? value : localized("Unable to read")))
    }
  }

  @objc private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      switch service.status {
      case .enabled:
        try service.unregister()
      case .requiresApproval:
        SMAppService.openSystemSettingsLoginItems()
      case .notRegistered, .notFound:
        try service.register()
        if service.status == .requiresApproval {
          showAlert(
            title: localized("User approval is required"),
            message: localized(
              "Allow TartR in System Settings > General > Login Items & Extensions."))
          SMAppService.openSystemSettingsLoginItems()
        }
      @unknown default:
        showAlert(
          title: localized("Unable to change login item"),
          message: localized("macOS returned an unknown login item status."))
      }
    } catch {
      showAlert(
        title: localized("Unable to change login item"), message: error.localizedDescription)
    }
    updateLaunchAtLoginMenuItem()
  }

  private func updateLaunchAtLoginMenuItem() {
    guard let item = launchAtLoginMenuItem else { return }
    switch SMAppService.mainApp.status {
    case .enabled:
      item.state = .on
      item.title = localized("Launch TartR at Login")
    case .requiresApproval:
      item.state = .mixed
      item.title = localized("Launch TartR at Login (Approval Required)")
    case .notRegistered, .notFound:
      item.state = .off
      item.title = localized("Launch TartR at Login")
    @unknown default:
      item.state = .off
      item.title = localized("Launch TartR at Login")
    }
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func startVM(id: UUID, verifyFirst: Bool, suspendable: Bool? = nil) {
    guard !isQuitting else { return }
    guard let configuration = configurations.first(where: { $0.id == id }) else { return }
    guard runtimes[id]?.process.isRunning != true else { return }
    guard states[id]?.isRunning != true else { return }

    if verifyFirst {
      states[id] = .unknown
      refreshUI()
      syncTartState { [weak self] in
        guard let self else { return }
        guard self.tartSyncError == nil else {
          self.states[id] = .unknown
          self.refreshUI()
          return
        }
        if self.states[id]?.isRunning != true {
          self.startVM(id: id, verifyFirst: false, suspendable: suspendable)
        }
      }
      return
    }

    let logURL = logURL(for: configuration)
    rotateLogIfNeeded(at: logURL, maximumBytes: 5 * 1024 * 1024)
    ensureLogExists(at: logURL)
    var openedHandle: FileHandle?

    do {
      let handle = try FileHandle(forWritingTo: logURL)
      openedHandle = handle
      try handle.seekToEnd()
      let stamp = ISO8601DateFormatter().string(from: Date())
      var runOptions = configuration.runOptions
      if let suspendable { runOptions.suspendable = suspendable }
      #if arch(x86_64)
        runOptions.suspendable = false
      #endif
      let runArguments = TartCommand.run(name: configuration.name, options: runOptions).arguments
      let displayedCommand = "tart \(runArguments.joined(separator: " "))"
      handle.write(Data("\n[\(stamp)] Starting: \(displayedCommand)\n".utf8))

      let process = Process()
      configureTartProcess(
        process,
        arguments: runArguments)
      process.standardOutput = handle
      process.standardError = handle
      process.terminationHandler = { [weak self] finished in
        DispatchQueue.main.async { self?.processDidExit(id: id, process: finished) }
      }

      states[id] = .starting
      refreshUI()
      try process.run()
      runtimes[id] = VMRuntime(process: process, logHandle: handle)
      states[id] = .running
      refreshUI()
    } catch {
      try? openedHandle?.close()
      runtimes.removeValue(forKey: id)
      states[id] = .failed(-1)
      refreshUI()
      showAlert(
        title: localized("Unable to start %@", configuration.name),
        message: error.localizedDescription)
    }
  }

  private func configureTartProcess(_ process: Process, arguments: [String]) {
    process.environment = TartHomeResolver.applying(
      configuredPath: configuredTartHomePath,
      to: process.environment ?? ProcessInfo.processInfo.environment)
    if let executable = tartExecutableURL {
      process.executableURL = executable
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = TartShellBridge.arguments(for: arguments)
    }
  }

  private func resyncAfterTartExecutableChange() {
    tartInstalled = true
    tartSyncError = nil
    for configuration in configurations { states[configuration.id] = .unknown }
    refreshUI()
    syncTartState()
  }

  private func stopVM(id: UUID) {
    guard let configuration = configurations.first(where: { $0.id == id }) else { return }
    guard states[id]?.isRunning == true else { return }
    states[id] = .stopping
    refreshUI()

    if let runtime = runtimes[id], runtime.process.isRunning {
      runtime.expectedStop = true
      kill(runtime.process.processIdentifier, SIGINT)
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
        [weak process = runtime.process] in
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
      }
      return
    }

    let process = Process()
    let outputCapture = BoundedProcessOutput(maximumBytes: maximumCommandOutputBytes)
    configureTartProcess(
      process, arguments: TartCommand.stop(name: configuration.name, timeout: 8).arguments)
    outputCapture.attach(to: process)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try process.run()
        outputCapture.processDidStart()
        process.waitUntilExit()
        let output = outputCapture.finish().text
        DispatchQueue.main.async {
          guard let self else { return }
          self.syncTartState {
            if process.terminationStatus != 0, self.states[id]?.isRunning == true {
              let details = output.isEmpty ? localized("tart stop failed") : output
              self.showAlert(
                title: localized("Unable to stop %@", configuration.name), message: details)
            }
          }
        }
      } catch {
        _ = outputCapture.finish()
        DispatchQueue.main.async {
          self?.states[id] = .failed(-1)
          self?.refreshUI()
          self?.showAlert(
            title: localized("Unable to stop %@", configuration.name),
            message: error.localizedDescription)
        }
      }
    }
  }

  private func processDidExit(id: UUID, process: Process) {
    guard let runtime = runtimes[id], runtime.process === process else { return }
    let expected = runtime.expectedStop || isQuitting
    let runtimeDuration = Date().timeIntervalSince(runtime.startedAt)
    try? runtime.logHandle.synchronize()
    try? runtime.logHandle.close()
    runtimes.removeValue(forKey: id)

    guard !isQuitting else { return }
    states[id] = expected ? .stopped : .unknown
    refreshUI()
    syncTartState { [weak self] in
      guard let self,
        VMExitAssessment.shouldReportFailure(
          expectedStop: expected,
          terminationStatus: process.terminationStatus,
          runtimeDuration: runtimeDuration,
          synchronizedState: self.states[id] ?? .unknown),
        let configuration = self.configurations.first(where: { $0.id == id })
      else { return }
      let message =
        process.terminationStatus == 127
        ? localized(
          "The tart command was not found. Check that Tart is installed and review the VM log.")
        : localized("Tart exited with status %d. Review the VM log.", process.terminationStatus)
      self.states[id] = .failed(process.terminationStatus)
      self.refreshUI()
      self.showAlert(title: localized("%@ failed to run", configuration.name), message: message)
    }
  }

  private func syncTartState(completion: (() -> Void)? = nil) {
    guard !isQuitting else { return }
    if let completion { syncCompletions.append(completion) }
    guard !syncInProgress else { return }
    syncInProgress = true

    let process = Process()
    configureTartProcess(process, arguments: TartCommand.listLocalJSON.arguments)
    let outputCapture = BoundedProcessOutput(maximumBytes: maximumCommandOutputBytes)
    outputCapture.attach(to: process)

    do {
      try process.run()
      outputCapture.processDidStart()
    } catch {
      _ = outputCapture.finish()
      tartSyncError = error.localizedDescription
      finishSync()
      return
    }
    syncProcess = process
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let completedBeforeTimeout = ProcessDeadline.waitForExit(process, timeout: 15)
      let captured = outputCapture.finish()
      let output = captured.data
      DispatchQueue.main.async {
        guard let self else { return }
        if self.syncProcess === process { self.syncProcess = nil }
        if !completedBeforeTimeout {
          self.tartSyncError = localized(
            "tart list did not respond within 15 seconds. This synchronization was terminated.")
          self.finishSync()
        } else if captured.wasTruncated {
          self.tartSyncError = localized(
            "tart list output exceeded the 1 MB safety limit. This synchronization was ignored.")
          self.finishSync()
        } else if process.terminationStatus == 0,
          let infos = try? TartListParser.parse(output)
        {
          self.applyTartState(infos)
        } else {
          self.tartInstalled = process.terminationStatus != 127
          self.tartSyncError = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if process.terminationStatus == 127 {
            self.tartSyncError = localized("Tart is not installed")
          }
          self.finishSync()
        }
      }
    }
  }

  private func applyTartState(_ infos: [TartVMInfo]) {
    tartInstalled = true
    let localInfos = infos.filter { $0.source.lowercased() == "local" }
    infoByName = Dictionary(uniqueKeysWithValues: localInfos.map { ($0.name, $0) })
    discoveredNames = Set(localInfos.map(\.name))
    var changed = false
    for info in localInfos where !configurations.contains(where: { $0.name == info.name }) {
      configurations.append(VMConfiguration(name: info.name))
      changed = true
    }
    if changed {
      configurations.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      saveConfigurations()
    }

    let byName = Dictionary(uniqueKeysWithValues: localInfos.map { ($0.name, $0) })
    for configuration in configurations {
      if let runtime = runtimes[configuration.id], runtime.process.isRunning {
        if byName[configuration.name]?.running == true { states[configuration.id] = .running }
        continue
      }
      guard let info = byName[configuration.name] else {
        states[configuration.id] = .missing
        continue
      }
      states[configuration.id] = VMState.resolved(from: info)
    }
    tartSyncError = nil
    finishSync()
  }

  private func finishSync() {
    syncInProgress = false
    installBox?.isHidden = tartInstalled
    refreshUI()
    let completions = syncCompletions
    syncCompletions.removeAll()
    for completion in completions { completion() }
  }

  private func runManagedTartCommand(
    _ arguments: [String], title: String,
    showsSuccessAlert: Bool = true,
    showsFailureAlert: Bool = true,
    completion: @escaping (Bool, String) -> Void
  ) {
    guard operationProcess == nil, updateDownloader == nil else {
      showAlert(
        title: localized("An operation is already in progress"),
        message: localized("Wait for the current Tart operation to finish or cancel it first."))
      return
    }

    let process = Process()
    let outputCapture = BoundedProcessOutput(maximumBytes: maximumCommandOutputBytes)
    configureTartProcess(process, arguments: arguments)
    outputCapture.attach(to: process)
    do {
      try process.run()
      outputCapture.processDidStart()
    } catch {
      _ = outputCapture.finish()
      showAlert(title: localized("Unable to run Tart"), message: error.localizedDescription)
      completion(false, error.localizedDescription)
      return
    }
    operationProcess = process
    operationOutputCapture = outputCapture
    operationWasCancelled = false
    showOperation(title)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      process.waitUntilExit()
      let captured = outputCapture.finish()
      let output = captured.text
      DispatchQueue.main.async {
        guard let self else { return }
        let wasCancelled = self.operationWasCancelled
        self.operationProcess = nil
        self.operationWasCancelled = false
        self.hideOperation()
        let success = !wasCancelled && process.terminationStatus == 0
        self.appendApplicationLog(
          TartCommandAuditLog.format(
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            cancelled: wasCancelled,
            output: output))
        if wasCancelled {
          // User cancellation is an expected outcome, not a success or failure alert.
        } else if success {
          if showsSuccessAlert {
            self.showAlert(title: localized("Operation Completed"), message: title)
          }
        } else if showsFailureAlert {
          let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
          let fallback =
            process.terminationReason == .uncaughtSignal
            ? localized(
              "The operation was interrupted unexpectedly by signal %d.", process.terminationStatus)
            : localized("Exit status %d", process.terminationStatus)
          self.showAlert(
            title: localized("Tart Operation Failed"),
            message: details.isEmpty ? fallback : String(details.suffix(3000)))
        }
        guard !self.isQuitting else { return }
        completion(success, output)
        self.syncTartState()
      }
    }
  }

  private func showOperation(_ title: String) {
    operationBaseTitle = title
    operationLabel?.stringValue = title
    operationLabel?.isHidden = false
    operationSpinner?.isHidden = false
    operationSpinner?.startAnimation(nil)
    cancelOperationButton?.isHidden = false
    cancelOperationButton?.isEnabled = true
    imageButton?.isEnabled = false
    moreButton?.isEnabled = false
    operationProgressTimer?.invalidate()
    operationProgressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
      [weak self] _ in
      self?.refreshOperationProgress()
    }
  }

  private func hideOperation() {
    operationProgressTimer?.invalidate()
    operationProgressTimer = nil
    operationOutputCapture = nil
    operationBaseTitle = nil
    operationLabel?.isHidden = true
    operationSpinner?.stopAnimation(nil)
    operationSpinner?.isHidden = true
    cancelOperationButton?.isHidden = true
    cancelOperationButton?.isEnabled = true
    imageButton?.isEnabled = tartInstalled
    moreButton?.isEnabled = tartInstalled
  }

  private func refreshOperationProgress() {
    guard let outputCapture = operationOutputCapture,
      let baseTitle = operationBaseTitle
    else { return }
    let snapshot = outputCapture.snapshot()
    guard !snapshot.data.isEmpty else { return }
    let text = String(decoding: snapshot.data.suffix(4096), as: UTF8.self)

    let lines = text.components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: "\r")))
    guard
      var lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return }
    if let expression = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]") {
      lastLine = expression.stringByReplacingMatches(
        in: lastLine, range: NSRange(lastLine.startIndex..., in: lastLine), withTemplate: "")
    }
    operationLabel?.stringValue = "\(baseTitle) · \(String(lastLine.suffix(140)))"
  }

  private func syncAndSelect(name: String) {
    syncTartState { [weak self] in
      guard let self, let row = self.visibleConfigurations.firstIndex(where: { $0.name == name })
      else {
        return
      }
      self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      self.tableView.scrollRowToVisible(row)
    }
  }

  private func validNewVMName(_ name: String) -> Bool {
    switch VMNameValidation.validate(name, existingNames: configurations.map(\.name)) {
    case .valid:
      return true
    case .empty, .containsSlash:
      showAlert(
        title: localized("Invalid name"),
        message: localized("A VM name cannot be empty or contain /."))
      return false
    case .duplicate:
      showAlert(
        title: localized("Name already exists"), message: localized("“%@” already exists.", name))
      return false
    }
  }

  private func addMenuItem(
    _ title: String, _ action: Selector, to menu: NSMenu, enabled: Bool = true
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    menu.addItem(item)
  }

  private func promptForValues(
    title: String, message: String,
    fields: [(String, String, Bool)]
  ) -> [String]? {
    let controls: [(String, NSView)] = fields.map { label, value, editable in
      let field = NSTextField(string: value)
      field.isEditable = editable
      if !editable { field.textColor = .secondaryLabelColor }
      return (label, field)
    }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = labeledForm(controls, width: 410)
    alert.addButton(withTitle: localized("OK"))
    alert.addButton(withTitle: localized("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return controls.compactMap {
      ($0.1 as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func labeledForm(_ rows: [(String, NSView)], width: CGFloat) -> NSView {
    let grid = NSGridView(numberOfColumns: 2, rows: rows.count)
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.column(at: 1).width = width - 125
    grid.rowSpacing = 10
    grid.columnSpacing = 10
    for (index, row) in rows.enumerated() {
      let label = NSTextField(labelWithString: row.0)
      label.alignment = .right
      grid.cell(atColumnIndex: 0, rowIndex: index).contentView = label
      grid.cell(atColumnIndex: 1, rowIndex: index).contentView = row.1
    }
    grid.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count * 34))
    return grid
  }

  private func availableStorageBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  private func storageByteString(_ bytes: UInt64) -> String {
    guard bytes <= UInt64(Int64.max) else { return localized("More than 8 EB") }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private var hostAvailableStorageDescription: String {
    guard
      let bytes = availableStorageBytes(at: tartStorageURL),
      bytes >= 0
    else { return "unknown" }
    return storageByteString(UInt64(bytes))
  }

  private func confirmStorageCapacity(
    operation: String,
    operationBytes: UInt64,
    at volumeURL: URL,
    offersCacheCleanup: Bool
  ) -> Bool {
    let assessment = StorageCapacityPreflight.assess(
      availableBytes: availableStorageBytes(at: volumeURL),
      operationBytes: operationBytes)
    guard case .insufficient(let availableBytes, let requiredBytes) = assessment else {
      return true
    }

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = localized("Available disk space may be insufficient")
    alert.informativeText =
      localized(
        "%@ requires approximately %@ including a 5 GB safety margin. The target volume currently has %@ available. Continuing may fail or exhaust host disk space.",
        operation, storageByteString(requiredBytes), storageByteString(availableBytes))
    alert.addButton(withTitle: localized("Cancel"))
    alert.addButton(withTitle: localized("Continue Anyway"))
    if offersCacheCleanup { alert.addButton(withTitle: localized("Prune Tart Cache…")) }
    switch alert.runModal() {
    case .alertSecondButtonReturn:
      return true
    case .alertThirdButtonReturn where offersCacheCleanup:
      pruneCaches()
      return false
    default:
      return false
    }
  }

  private var normalizedInputName: String {
    nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private var configuredTartExecutablePath: String? {
    guard
      let path = UserDefaults.standard.string(forKey: tartExecutablePathKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { return nil }
    return path
  }

  private var configuredTartHomePath: String? {
    guard let path = UserDefaults.standard.string(forKey: tartHomePathKey), !path.isEmpty else {
      return nil
    }
    return path
  }

  private var resolvedTartHome: ResolvedTartHome {
    TartHomeResolver.resolve(configuredPath: configuredTartHomePath)
  }

  private var canChangeTartHome: Bool {
    operationProcess == nil && updateDownloader == nil && !syncInProgress
      && !runtimes.values.contains(where: { $0.process.isRunning })
  }

  private var tartStorageURL: URL {
    resolvedTartHome.path.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  private var tartHomeDescription: String {
    switch resolvedTartHome.source {
    case .appSetting:
      return localized("%@ (TartR setting)", resolvedTartHome.path ?? "")
    case .environment:
      return localized("%@ (TART_HOME environment)", resolvedTartHome.path ?? "")
    case .tartDefault:
      return localized("Tart default directory")
    }
  }

  private var preferencesNamespaceSuffix: String {
    guard let path = resolvedTartHome.path else { return "" }
    let encoded = Data(path.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    return ".home.\(encoded)"
  }

  private var activeDefaultsKey: String { defaultsKey + preferencesNamespaceSuffix }
  private var activeDefaultsBackupKey: String { defaultsBackupKey + preferencesNamespaceSuffix }
  private var activeDefaultsCorruptKey: String { defaultsCorruptKey + preferencesNamespaceSuffix }
  private var activeSelectedVMKey: String { selectedVMKey + preferencesNamespaceSuffix }

  private var currentAppVersionString: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }

  private var configuredUpdateManifestURL: URL? {
    guard
      let rawValue = Bundle.main.object(forInfoDictionaryKey: "TartRUpdateManifestURL") as? String,
      !rawValue.isEmpty,
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil
    else { return nil }
    return components.url
  }

  private var tartExecutableURL: URL? {
    TartExecutableLocator.locate(explicitPath: configuredTartExecutablePath)
  }

  private var tartExecutableDescription: String {
    let locatedPath = tartExecutableURL?.path
    guard let configuredPath = configuredTartExecutablePath else {
      return locatedPath ?? localized("Login shell PATH (no standard installation found)")
    }
    if locatedPath == configuredPath { return localized("%@ (custom)", configuredPath) }
    if let locatedPath {
      return localized("%@ (custom path unavailable; automatically using fallback)", locatedPath)
    }
    return localized("%@ (custom path unavailable; trying login shell PATH)", configuredPath)
  }

  private var diagnosticTartExecutableDescription: String {
    tartExecutableDescription.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
  }

  private var diagnosticTartHomeDescription: String {
    tartHomeDescription.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
  }

  private var selectedRow: Int? {
    guard let tableView, tableView.selectedRow >= 0 else { return nil }
    return tableView.selectedRow
  }

  private var selectedConfiguration: VMConfiguration? {
    let selected = selectedConfigurations
    return selected.count == 1 ? selected[0] : nil
  }

  private var selectedConfigurations: [VMConfiguration] {
    guard let tableView else { return [] }
    let visible = visibleConfigurations
    return tableView.selectedRowIndexes.compactMap { row in
      visible.indices.contains(row) ? visible[row] : nil
    }
  }

  private var selectionCapabilities: VMSelectionCapabilities {
    VMSelectionCapabilities.resolve(
      configurations: selectedConfigurations,
      states: states,
      discoveredNames: discoveredNames)
  }

  private var visibleConfigurations: [VMConfiguration] {
    let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let descriptor = tableView?.sortDescriptors.first
    let sortKey = descriptor?.key.flatMap(VMListSortKey.init(rawValue:)) ?? .name
    return VMListProjection.make(
      configurations: configurations,
      states: states,
      infoByName: infoByName,
      query: query,
      sortKey: sortKey,
      ascending: descriptor?.ascending ?? true)
  }

  private func logURL(for configuration: VMConfiguration) -> URL {
    let safeName = configuration.name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    return logsDirectory.appendingPathComponent(
      "\(safeName)-\(configuration.id.uuidString.prefix(8)).log")
  }

  private func ensureLogExists(at url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
  }

  private func rotateLogIfNeeded(at url: URL, maximumBytes: UInt64) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      size.uint64Value >= maximumBytes
    else { return }
    let backup = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
  }

  private func appendApplicationLog(_ message: String) {
    rotateLogIfNeeded(at: applicationLogURL, maximumBytes: 2 * 1024 * 1024)
    ensureLogExists(at: applicationLogURL)
    guard let handle = try? FileHandle(forWritingTo: applicationLogURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    let stamp = ISO8601DateFormatter().string(from: Date())
    handle.write(Data("\n[\(stamp)] \(message)\n".utf8))
  }

  private func diagnosticsReport() -> String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "unknown"
    #endif
    let tartPath = diagnosticTartExecutableDescription
    let tartStatus: String
    if !tartInstalled {
      tartStatus = localized("Not installed")
    } else if tartSyncError != nil {
      tartStatus = localized("State synchronization error")
    } else {
      tartStatus = localized("Available")
    }
    let runningCount = states.values.filter { $0 == .running }.count
    let suspendedCount = states.values.filter { $0 == .suspended }.count
    let missingCount = states.values.filter { $0 == .missing }.count

    return """
      TartR diagnostics
      Generated: \(ISO8601DateFormatter().string(from: Date()))
      TartR: \(version) (\(build))
      Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
      macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      Architecture: \(architecture)
      Tart executable: \(tartPath)
      Tart home: \(diagnosticTartHomeDescription)
      Tart status: \(tartStatus)
      Host volume available: \(hostAvailableStorageDescription)
      Saved/local VMs: \(configurations.count)/\(discoveredNames.count)
      Running/suspended/missing: \(runningCount)/\(suspendedCount)/\(missingCount)
      Headless/suspendable profiles: \(configurations.filter { $0.runOptions.headless }.count)/\(configurations.filter { $0.runOptions.suspendable }.count)
      TartR-owned running processes: \(runtimes.values.filter { $0.process.isRunning }.count)
      Managed operation active: \(operationProcess?.isRunning == true ? "yes" : "no")
      Configuration recovery performed: \(configurationRecoveryNotice == nil ? "no" : "yes")

      Privacy: VM names, command output, logs, and registry credentials are intentionally omitted.
      """
  }

  private func environmentReport(tartVersion: String) -> String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "unknown"
    #endif
    return """
      TartR: \(version) (\(build))
      Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
      macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      Architecture: \(architecture)
      Tart: \(tartVersion)
      Tart executable: \(tartExecutableDescription)
      Tart home: \(tartHomeDescription)
      Host volume available: \(hostAvailableStorageDescription)
      State synchronization: \(tartSyncError == nil ? localized("Normal") : localized("Error"))
      """
  }

  private func loadConfigurations() {
    let defaults = UserDefaults.standard
    let current = defaults.data(forKey: activeDefaultsKey)
    let result = VMConfigurationRecovery.resolve(
      current: current,
      backup: defaults.data(forKey: activeDefaultsBackupKey),
      legacy: preferencesNamespaceSuffix.isEmpty
        ? legacyPreferenceDataValues(forKey: defaultsKey) : [])
    configurations = result.configurations
    switch result.source {
    case .current:
      break
    case .backup:
      if let current { defaults.set(current, forKey: activeDefaultsCorruptKey) }
      configurationRecoveryNotice = localized(
        "The current configuration could not be read. TartR restored the latest valid backup and preserved the corrupted data for diagnostics."
      )
      saveConfigurations()
    case .legacy:
      saveConfigurations()
    case .empty:
      if let current {
        defaults.set(current, forKey: activeDefaultsCorruptKey)
        configurationRecoveryNotice = localized(
          "Neither the current configuration nor its backup could be read. TartR preserved the corrupted data and created an empty VM list; local VMs will be rediscovered after synchronization."
        )
      }
      saveConfigurations()
    }
    if defaults.string(forKey: activeSelectedVMKey) == nil, preferencesNamespaceSuffix.isEmpty,
      let legacySelection = legacyPreferenceString(forKey: selectedVMKey)
    {
      defaults.set(legacySelection, forKey: activeSelectedVMKey)
    }
    for configuration in configurations { states[configuration.id] = .unknown }
  }

  private func legacyPreferenceDataValues(forKey key: String) -> [Data] {
    legacyAppIDs.compactMap { appID in
      CFPreferencesCopyAppValue(key as CFString, appID as CFString) as? Data
    }
  }

  private func legacyPreferenceString(forKey key: String) -> String? {
    for appID in legacyAppIDs {
      if let value = CFPreferencesCopyAppValue(key as CFString, appID as CFString) as? String {
        return value
      }
    }
    return nil
  }

  private func saveConfigurations() {
    guard let data = try? JSONEncoder().encode(configurations) else { return }
    let defaults = UserDefaults.standard
    if let current = defaults.data(forKey: activeDefaultsKey), current != data,
      (try? JSONDecoder().decode([VMConfiguration].self, from: current)) != nil
    {
      defaults.set(current, forKey: activeDefaultsBackupKey)
    }
    defaults.set(data, forKey: activeDefaultsKey)
  }

  private func restoreSelection() {
    guard !visibleConfigurations.isEmpty else { return }
    let savedID = UserDefaults.standard.string(forKey: activeSelectedVMKey).flatMap(
      UUID.init(uuidString:))
    let row =
      savedID.flatMap { id in visibleConfigurations.firstIndex(where: { $0.id == id }) } ?? 0
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  }

  private func refreshUI(forceTableReload: Bool = false) {
    tartHomeLabel?.stringValue = tartHomeDescription
    tartHomeLabel?.toolTip = tartHomeDescription
    let visible = visibleConfigurations
    let selectedIDs = Set(selectedConfigurations.map(\.id))
    let signature = visible.map { configuration in
      [
        configuration.id.uuidString,
        configuration.name,
        configuration.autoStart.description,
        states[configuration.id]?.label ?? "",
        String(infoByName[configuration.name]?.disk ?? -1),
        String(infoByName[configuration.name]?.size ?? -1),
      ].joined(separator: "|")
    }.joined(separator: "\n")
    if forceTableReload || signature != lastTableSignature {
      let selectedID = UserDefaults.standard.string(forKey: activeSelectedVMKey).flatMap(
        UUID.init(uuidString:))
      tableView?.reloadData()
      lastTableSignature = signature
      let idsToRestore =
        selectedIDs.isEmpty ? selectedID.map { Set([$0]) } ?? [] : selectedIDs
      let rows = IndexSet(
        visible.enumerated().compactMap { idsToRestore.contains($0.element.id) ? $0.offset : nil })
      if !rows.isEmpty {
        tableView?.selectRowIndexes(rows, byExtendingSelection: false)
      }
    }
    refreshControls()
    let runningCount = states.values.filter { state in
      if case .running = state { return true }
      return false
    }.count
    let total = configurations.count
    let isFiltering =
      !(searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ?? true)
    if let tartSyncError, !tartSyncError.isEmpty {
      summaryLabel?.stringValue = localized("Unable to synchronize Tart: %@", tartSyncError)
      summaryLabel?.textColor = .systemRed
    } else {
      let selectedCount = selectedConfigurations.count
      let selectionSuffix = selectedCount > 1 ? localized(" %d selected.", selectedCount) : ""
      let availableStorage = availableStorageBytes(
        at: tartStorageURL)
      let storageSuffix =
        availableStorage.map {
          localized(" %@ available on the host volume.", storageByteString(UInt64(max($0, 0))))
        } ?? ""
      if isFiltering {
        summaryLabel?.stringValue =
          localized("Showing %d of %d VM(s); %d running.", visible.count, total, runningCount)
          + selectionSuffix + storageSuffix
      } else {
        summaryLabel?.stringValue =
          runningCount == 0
          ? localized("%d VM(s) discovered/saved; none running.", total) + selectionSuffix
            + storageSuffix
          : localized("%d VM(s) discovered/saved; %d running.", total, runningCount)
            + selectionSuffix
            + storageSuffix
      }
      let lowStorageThreshold: Int64 = 15 * 1_024 * 1_024 * 1_024
      summaryLabel?.textColor =
        availableStorage.map { $0 < lowStorageThreshold } == true
        ? .systemOrange : .secondaryLabelColor
    }
  }

  private func refreshControls() {
    let operationBusy = operationProcess != nil || updateDownloader != nil
    imageButton?.isEnabled = tartInstalled && !operationBusy
    moreButton?.isEnabled = tartInstalled && !operationBusy
    let capabilities = selectionCapabilities
    let count = capabilities.selectionCount
    startButton?.title =
      count > 1 ? localized("Run %d", capabilities.startableIDs.count) : localized("Run")
    stopButton?.title =
      count > 1 ? localized("Stop %d", capabilities.stoppableIDs.count) : localized("Stop")
    deleteButton?.title =
      count > 1 ? localized("Remove Records (%d)", count) : localized("Remove Record")
    startButton?.toolTip =
      count > 1 ? localized("Run only selected VMs that can currently be started") : nil
    stopButton?.toolTip =
      count > 1 ? localized("Stop only selected VMs that are starting or running") : nil
    deleteButton?.toolTip =
      count > 1
      ? localized(
        "Bulk removal applies only to saved records missing locally and never deletes disks")
      : nil
    startButton?.isEnabled = tartInstalled && !capabilities.startableIDs.isEmpty
    stopButton?.isEnabled = tartInstalled && !capabilities.stoppableIDs.isEmpty
    deleteButton?.isEnabled = capabilities.canRemoveRecords
    logButton?.isEnabled = capabilities.hasSingleSelection
  }

  private func showAlert(title: String, message: String) {
    showWindow()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: localized("OK"))
    alert.runModal()
  }

  private func showTextViewer(title: String, text: String) {
    showWindow()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
    textView.string = text
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.minSize = NSSize(width: 0, height: 300)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: 560, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .bezelBorder

    let alert = NSAlert()
    alert.messageText = title
    alert.accessoryView = scrollView
    alert.addButton(withTitle: localized("Close"))
    alert.addButton(withTitle: localized("Copy"))
    if alert.runModal() == .alertSecondButtonReturn {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

  private func reusableTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
      return cell
    }
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func iconTextCell(
    identifier: NSUserInterfaceItemIdentifier, text: String, symbolName: String
  ) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    icon.contentTintColor = .controlAccentColor
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    icon.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(icon)
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func statusCell(identifier: NSUserInterfaceItemIdentifier, state: VMState)
    -> NSTableCellView
  {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = statusColor(for: state).cgColor
    dot.layer?.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: state.label)
    label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    label.textColor = statusColor(for: state)
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(dot)
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func statusColor(for state: VMState) -> NSColor {
    switch state {
    case .running: return .systemGreen
    case .failed: return .systemRed
    case .starting, .stopping, .unknown: return .systemOrange
    case .suspended: return .systemBlue
    case .stopped: return .secondaryLabelColor
    case .missing: return .tertiaryLabelColor
    }
  }

  private func makeButton(
    _ title: String, action: Selector, symbolName: String? = nil, prominent: Bool = false
  ) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .large
    if let symbolName {
      button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
      button.imagePosition = .imageLeading
    }
    if prominent {
      button.bezelColor = .controlAccentColor
      button.contentTintColor = .white
    }
    return button
  }

  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = appTitle
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.center()
    window.setFrameAutosaveName("TartRMainWindow")
    window.minSize = NSSize(width: 820, height: 560)
    window.isReleasedWhenClosed = false
    window.delegate = self

    let background = NSVisualEffectView()
    background.material = .underWindowBackground
    background.blendingMode = .behindWindow
    background.state = .active
    window.contentView = background

    let appIcon = NSImageView()
    appIcon.image = NSImage(
      systemSymbolName: "shippingbox.fill", accessibilityDescription: appTitle)
    appIcon.contentTintColor = .controlAccentColor
    appIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 27, weight: .semibold)
    appIcon.widthAnchor.constraint(equalToConstant: 40).isActive = true
    appIcon.heightAnchor.constraint(equalToConstant: 40).isActive = true

    let heading = NSTextField(labelWithString: localized("Virtual Machines"))
    heading.font = NSFont.systemFont(ofSize: 25, weight: .bold)
    tartHomeLabel = NSTextField(labelWithString: tartHomeDescription)
    tartHomeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    tartHomeLabel.textColor = .secondaryLabelColor
    tartHomeLabel.lineBreakMode = .byTruncatingMiddle
    let headingLabels = NSStackView(views: [heading, tartHomeLabel])
    headingLabels.orientation = .vertical
    headingLabels.alignment = .leading
    headingLabels.spacing = 2
    let brandRow = NSStackView(views: [appIcon, headingLabels])
    brandRow.orientation = .horizontal
    brandRow.alignment = .centerY
    brandRow.spacing = 10

    searchField = NSSearchField()
    searchField.placeholderString = localized("Search VMs")
    searchField.setAccessibilityLabel(localized("Search VMs"))
    searchField.sendsSearchStringImmediately = true
    searchField.target = self
    searchField.action = #selector(searchChanged)
    searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
    imageButton = makeButton(
      localized("Download/Clone Image…"), action: #selector(downloadImage),
      symbolName: "plus.circle.fill", prominent: true)
    let headingRow = NSStackView(views: [brandRow, NSView(), searchField, imageButton])
    headingRow.orientation = .horizontal
    headingRow.alignment = .centerY
    headingRow.spacing = 12

    summaryLabel = NSTextField(labelWithString: "")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

    installBox = NSBox()
    installBox.boxType = .custom
    installBox.titlePosition = .noTitle
    installBox.cornerRadius = 12
    installBox.fillColor = NSColor.systemYellow.withAlphaComponent(0.10)
    installBox.borderColor = NSColor.systemYellow.withAlphaComponent(0.45)
    installBox.borderWidth = 1
    let installLabel = NSTextField(
      wrappingLabelWithString: localized(
        "Tart was not detected. Install it with Homebrew: brew install cirruslabs/cli/tart"))
    installLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let installButton = NSButton(
      title: localized("Copy Command and Open Terminal"), target: self,
      action: #selector(copyInstallCommandAndOpenTerminal))
    let chooseTartButton = NSButton(
      title: localized("Choose Existing Tart…"), target: self,
      action: #selector(chooseTartExecutable))
    let docsButton = NSButton(
      title: localized("Installation Guide"), target: self, action: #selector(openQuickStart))
    let installButtons = NSStackView(views: [installButton, chooseTartButton, docsButton, NSView()])
    installButtons.orientation = .horizontal
    installButtons.spacing = 10
    let installRow = NSStackView(views: [installLabel, installButtons])
    installRow.orientation = .vertical
    installRow.alignment = .leading
    installRow.spacing = 10
    installRow.translatesAutoresizingMaskIntoConstraints = false
    installBox.contentView?.addSubview(installRow)
    NSLayoutConstraint.activate([
      installRow.leadingAnchor.constraint(
        equalTo: installBox.contentView!.leadingAnchor, constant: 12),
      installRow.trailingAnchor.constraint(
        equalTo: installBox.contentView!.trailingAnchor, constant: -12),
      installRow.topAnchor.constraint(equalTo: installBox.contentView!.topAnchor, constant: 10),
      installRow.bottomAnchor.constraint(
        equalTo: installBox.contentView!.bottomAnchor, constant: -10),
    ])
    installBox.isHidden = true

    nameField = NSTextField()
    nameField.placeholderString = localized(
      "Add a VM name manually (local VMs are usually discovered automatically)")
    nameField.setAccessibilityLabel(localized("Add VM name manually"))
    nameField.delegate = self
    nameField.font = NSFont.systemFont(ofSize: 13)

    addButton = makeButton(localized("Add"), action: #selector(addVM), symbolName: "plus")
    addButton.isEnabled = false
    addButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

    let inputRow = NSStackView(views: [nameField, addButton])
    inputRow.orientation = .horizontal
    inputRow.spacing = 10

    let quickAddBox = NSBox()
    quickAddBox.boxType = .custom
    quickAddBox.titlePosition = .noTitle
    quickAddBox.cornerRadius = 10
    quickAddBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
    quickAddBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.55)
    quickAddBox.borderWidth = 1
    inputRow.translatesAutoresizingMaskIntoConstraints = false
    quickAddBox.contentView?.addSubview(inputRow)
    NSLayoutConstraint.activate([
      inputRow.leadingAnchor.constraint(
        equalTo: quickAddBox.contentView!.leadingAnchor, constant: 12),
      inputRow.trailingAnchor.constraint(
        equalTo: quickAddBox.contentView!.trailingAnchor, constant: -12),
      inputRow.topAnchor.constraint(equalTo: quickAddBox.contentView!.topAnchor, constant: 9),
      inputRow.bottomAnchor.constraint(
        equalTo: quickAddBox.contentView!.bottomAnchor, constant: -9),
    ])

    tableView = NSTableView()
    tableView.delegate = self
    tableView.dataSource = self
    tableView.rowHeight = 46
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.backgroundColor = .clear
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = true
    tableView.setAccessibilityLabel(localized("Tart VM List"))
    tableView.autosaveName = "TartRVMTable"
    tableView.autosaveTableColumns = true
    tableView.doubleAction = #selector(toggleSelectedVM)
    tableView.target = self

    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    nameColumn.title = localized("VM Name")
    nameColumn.minWidth = 230
    nameColumn.sortDescriptorPrototype = NSSortDescriptor(
      key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
    statusColumn.title = localized("Status")
    statusColumn.width = 125
    statusColumn.minWidth = 110
    statusColumn.sortDescriptorPrototype = NSSortDescriptor(key: "status", ascending: true)
    let diskColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
    diskColumn.title = localized("Disk")
    diskColumn.width = 80
    diskColumn.minWidth = 70
    diskColumn.sortDescriptorPrototype = NSSortDescriptor(key: "disk", ascending: true)
    let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    sizeColumn.title = localized("Actual Size")
    sizeColumn.width = 90
    sizeColumn.minWidth = 80
    sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
    let autoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("autostart"))
    autoColumn.title = localized("Run When App Opens")
    autoColumn.width = 145
    autoColumn.minWidth = 130
    tableView.addTableColumn(nameColumn)
    tableView.addTableColumn(statusColumn)
    tableView.addTableColumn(diskColumn)
    tableView.addTableColumn(sizeColumn)
    tableView.addTableColumn(autoColumn)
    tableView.sortDescriptors = [nameColumn.sortDescriptorPrototype!]

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    let listBox = NSBox()
    listBox.boxType = .custom
    listBox.titlePosition = .noTitle
    listBox.cornerRadius = 12
    listBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.86)
    listBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.65)
    listBox.borderWidth = 1
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    listBox.contentView?.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: listBox.contentView!.leadingAnchor, constant: 1),
      scrollView.trailingAnchor.constraint(
        equalTo: listBox.contentView!.trailingAnchor, constant: -1),
      scrollView.topAnchor.constraint(equalTo: listBox.contentView!.topAnchor, constant: 1),
      scrollView.bottomAnchor.constraint(equalTo: listBox.contentView!.bottomAnchor, constant: -1),
    ])

    startButton = makeButton(
      localized("Run"), action: #selector(startSelectedVM), symbolName: "play.fill",
      prominent: true)
    stopButton = makeButton(
      localized("Stop"), action: #selector(stopSelectedVM), symbolName: "stop.fill")
    logButton = makeButton(
      localized("Open Log"), action: #selector(openSelectedLog), symbolName: "doc.text")
    moreButton = makeButton(
      localized("More Actions…"), action: #selector(showMoreMenu(_:)),
      symbolName: "ellipsis.circle")
    deleteButton = makeButton(
      localized("Remove Record"), action: #selector(deleteSelectedVM), symbolName: "trash")
    deleteButton.contentTintColor = .systemRed

    let buttonRow = NSStackView(views: [
      startButton, stopButton, moreButton, logButton, NSView(), deleteButton,
    ])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 10

    operationSpinner = NSProgressIndicator()
    operationSpinner.style = .spinning
    operationSpinner.controlSize = .small
    operationSpinner.isDisplayedWhenStopped = false
    operationSpinner.isHidden = true
    operationLabel = NSTextField(labelWithString: "")
    operationLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    operationLabel.textColor = .systemBlue
    operationLabel.isHidden = true
    cancelOperationButton = NSButton(
      title: localized("Cancel Operation"), target: self, action: #selector(cancelOperation))
    cancelOperationButton.bezelStyle = .inline
    cancelOperationButton.isHidden = true
    let operationRow = NSStackView(views: [
      operationSpinner, operationLabel, NSView(), cancelOperationButton,
    ])
    operationRow.orientation = .horizontal
    operationRow.spacing = 8

    let hint = NSTextField(
      labelWithString: localized(
        "Status synchronizes with Tart every 5 seconds and when the window activates. When quitting, you can stop VMs or keep them running in the background."
      ))
    hint.textColor = .tertiaryLabelColor
    hint.font = NSFont.systemFont(ofSize: 11)

    let stack = NSStackView(views: [
      headingRow, summaryLabel, installBox, quickAddBox, listBox, buttonRow, operationRow, hint,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)

    headingRow.translatesAutoresizingMaskIntoConstraints = false
    installBox.translatesAutoresizingMaskIntoConstraints = false
    quickAddBox.translatesAutoresizingMaskIntoConstraints = false
    listBox.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    operationRow.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
      headingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      installBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
      quickAddBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
      listBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
      listBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      operationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  private func buildMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()

    let about = NSMenuItem(
      title: localized("About TartR"), action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    appMenu.addItem(about)
    let checkUpdates = NSMenuItem(
      title: localized("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
    checkUpdates.target = self
    appMenu.addItem(checkUpdates)
    let automaticUpdates = NSMenuItem(
      title: localized("Automatically Check for Updates"),
      action: #selector(toggleAutomaticUpdateChecks),
      keyEquivalent: "")
    automaticUpdates.target = self
    automaticUpdateMenuItem = automaticUpdates
    appMenu.addItem(automaticUpdates)
    updateAutomaticUpdateMenuItem()
    appMenu.addItem(.separator())
    let show = NSMenuItem(
      title: localized("Show Window"), action: #selector(showWindow), keyEquivalent: "1")
    show.target = self
    appMenu.addItem(show)
    let launchAtLogin = NSMenuItem(
      title: localized("Launch TartR at Login"), action: #selector(toggleLaunchAtLogin),
      keyEquivalent: "")
    launchAtLogin.target = self
    launchAtLoginMenuItem = launchAtLogin
    appMenu.addItem(launchAtLogin)
    updateLaunchAtLoginMenuItem()
    let log = NSMenuItem(
      title: localized("Open Selected Log"), action: #selector(openSelectedLog), keyEquivalent: "l")
    log.target = self
    appMenu.addItem(log)
    let appLog = NSMenuItem(
      title: localized("Open TartR Log"), action: #selector(openApplicationLog), keyEquivalent: "")
    appLog.target = self
    appMenu.addItem(appLog)
    let chooseTart = NSMenuItem(
      title: localized("Choose Tart Executable…"), action: #selector(chooseTartExecutable),
      keyEquivalent: "")
    chooseTart.target = self
    appMenu.addItem(chooseTart)
    let resetTart = NSMenuItem(
      title: localized("Restore Automatic Tart Detection"), action: #selector(resetTartExecutable),
      keyEquivalent: "")
    resetTart.target = self
    appMenu.addItem(resetTart)
    let chooseTartHome = NSMenuItem(
      title: localized("Choose Tart Home Directory…"), action: #selector(chooseTartHome),
      keyEquivalent: "")
    chooseTartHome.target = self
    appMenu.addItem(chooseTartHome)
    let resetTartHome = NSMenuItem(
      title: localized("Restore Environment/Default Tart Home"), action: #selector(resetTartHome),
      keyEquivalent: "")
    resetTartHome.target = self
    appMenu.addItem(resetTartHome)
    let environment = NSMenuItem(
      title: localized("Runtime Environment…"), action: #selector(showEnvironmentInfo),
      keyEquivalent: "")
    environment.target = self
    appMenu.addItem(environment)
    let diagnostics = NSMenuItem(
      title: localized("Export Diagnostics…"), action: #selector(exportDiagnostics),
      keyEquivalent: "")
    diagnostics.target = self
    appMenu.addItem(diagnostics)
    let exportSettingsItem = NSMenuItem(
      title: localized("Export TartR Settings…"), action: #selector(exportSettings),
      keyEquivalent: "")
    exportSettingsItem.target = self
    appMenu.addItem(exportSettingsItem)
    let importSettingsItem = NSMenuItem(
      title: localized("Import TartR Settings…"), action: #selector(importSettings),
      keyEquivalent: "")
    importSettingsItem.target = self
    appMenu.addItem(importSettingsItem)
    let refresh = NSMenuItem(
      title: localized("Refresh Status"), action: #selector(refreshNow), keyEquivalent: "r")
    refresh.target = self
    appMenu.addItem(refresh)
    let help = NSMenuItem(
      title: localized("Tart Quick Start"), action: #selector(openQuickStart), keyEquivalent: "?")
    help.target = self
    appMenu.addItem(help)
    appMenu.addItem(.separator())
    let quit = NSMenuItem(
      title: localized("Quit %@", appTitle), action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    appMenu.addItem(quit)
    appItem.submenu = appMenu
    NSApp.mainMenu = mainMenu
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
