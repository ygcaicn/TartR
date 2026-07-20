import AppKit
import Darwin
import Foundation
import ServiceManagement
import TartRCore
import UniformTypeIdentifiers

private let appTitle = "TartR"
private let defaultsKey = "vmConfigurations.v2"
private let defaultsBackupKey = "vmConfigurations.v2.backup"
private let defaultsCorruptKey = "vmConfigurations.v2.corruptBackup"
private let selectedVMKey = "selectedVM.v2"
private let tartExecutablePathKey = "tartExecutablePath.v1"
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
  private var installBox: NSBox!
  private var operationLabel: NSTextField!
  private var operationSpinner: NSProgressIndicator!
  private var cancelOperationButton: NSButton!
  private var catalogTargetField: NSTextField?
  private var catalogSourceField: NSTextField?
  private var launchAtLoginMenuItem: NSMenuItem?

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
  private var operationOutputURL: URL?
  private var operationBaseTitle: String?
  private var operationProgressTimer: Timer?
  private var operationWasCancelled = false
  private var lastTableSignature: String?
  private var isQuitting = false
  private var configurationRecoveryNotice: String?

  private lazy var logsDirectory: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/TartR", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  private lazy var applicationLogURL = logsDirectory.appendingPathComponent("TartR.log")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
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
        self?.showAlert(title: "虚拟机列表已恢复", message: configurationRecoveryNotice)
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
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    updateLaunchAtLoginMenuItem()
    syncTartState()
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
      alert.messageText = "仍有 \(managedRuntimes.count) 台虚拟机由 TartR 启动"
      alert.informativeText =
        "可以让虚拟机继续在后台运行；稍后重新打开 TartR 会自动同步并继续管理。"
        + (backgroundProcesses.isEmpty ? "" : " 当前正在执行的其他 Tart 操作将被取消。")
      alert.addButton(withTitle: "保持 VM 运行并退出")
      alert.addButton(withTitle: "停止 VM 并退出")
      alert.addButton(withTitle: "取消")
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
      alert.messageText = "Tart 操作尚未完成"
      alert.informativeText = "现在退出会取消正在执行的操作。"
      alert.addButton(withTitle: "取消操作并退出")
      alert.addButton(withTitle: "继续等待")
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }

    syncTimer?.invalidate()
    isQuitting = true
    var processesToTerminate = backgroundProcesses

    if keepVMsRunning {
      appendApplicationLog("TartR 退出，保留 \(managedRuntimes.count) 台由 TartR 启动的虚拟机继续运行。")
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
      return operationProcess == nil && !syncInProgress
    case #selector(resetTartExecutable):
      return configuredTartExecutablePath != nil && operationProcess == nil && !syncInProgress
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
      let cell = reusableTextCell(identifier: identifier)
      cell.textField?.stringValue = configuration.name
      cell.textField?.font = NSFont.systemFont(ofSize: 13, weight: .medium)
      cell.textField?.textColor = .labelColor
      return cell
    case "status":
      let cell = reusableTextCell(identifier: identifier)
      let state = states[configuration.id] ?? .unknown
      cell.textField?.stringValue = state.label
      cell.textField?.font = NSFont.systemFont(ofSize: 12)
      switch state {
      case .running: cell.textField?.textColor = .systemGreen
      case .failed: cell.textField?.textColor = .systemRed
      case .starting, .stopping, .unknown: cell.textField?.textColor = .systemOrange
      case .stopped, .suspended: cell.textField?.textColor = .secondaryLabelColor
      case .missing: cell.textField?.textColor = .tertiaryLabelColor
      }
      return cell
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
      let checkbox = NSButton(
        checkboxWithTitle: "", target: self, action: #selector(toggleAutoStart(_:)))
      checkbox.state = configuration.autoStart ? .on : .off
      checkbox.tag = row
      checkbox.setAccessibilityLabel("打开 TartR 时自动启动 \(configuration.name)")
      checkbox.setAccessibilityValue(configuration.autoStart)
      checkbox.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(checkbox)
      NSLayoutConstraint.activate([
        checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
        checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    default:
      return nil
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if let selected = selectedConfiguration {
      UserDefaults.standard.set(selected.id.uuidString, forKey: selectedVMKey)
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
      showAlert(title: "名称已存在", message: "“\(name)”已经在虚拟机列表中。")
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
        title: "无法移除所选记录",
        message: "只能移除本地不存在且未运行的保存记录；TartR 不会通过此按钮删除虚拟机磁盘。")
      return
    }
    if selected.count > 1 {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "移除 \(selected.count) 条虚拟机记录？"
      alert.informativeText = "只会移除 TartR 保存的记录，不会删除任何虚拟机磁盘。"
      alert.addButton(withTitle: "移除记录")
      alert.addButton(withTitle: "取消")
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

  @objc private func toggleAutoStart(_ sender: NSButton) {
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
    let command = "brew install cirruslabs/cli/tart"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    showAlert(title: "安装命令已复制", message: "请在终端按 ⌘V 粘贴并回车：\n\n\(command)\n\n安装完成后 TartR 会自动检测。")
  }

  @objc private func openQuickStart() {
    NSWorkspace.shared.open(URL(string: "https://tart.run/quick-start/")!)
  }

  @objc private func chooseTartExecutable() {
    guard operationProcess == nil, !syncInProgress else {
      showAlert(title: "请稍后再选择 Tart", message: "等待当前 Tart 操作或状态同步完成后再修改可执行文件。")
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择 Tart 可执行文件"
    panel.message = "选择可信来源且具有执行权限的 tart 文件。此路径只保存在本机。"
    panel.prompt = "使用此 Tart"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let current = tartExecutableURL {
      panel.directoryURL = current.deletingLastPathComponent()
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      showAlert(title: "无法使用所选文件", message: "该文件不存在或没有执行权限。")
      return
    }
    validateAndSaveTartExecutable(url.standardizedFileURL)
  }

  @objc private func resetTartExecutable() {
    guard operationProcess == nil, !syncInProgress else {
      showAlert(title: "请稍后再恢复自动检测", message: "等待当前 Tart 操作或状态同步完成后再修改可执行文件。")
      return
    }
    UserDefaults.standard.removeObject(forKey: tartExecutablePathKey)
    appendApplicationLog("已恢复自动检测 Tart 可执行文件。")
    resyncAfterTartExecutableChange()
  }

  private func validateAndSaveTartExecutable(_ url: URL) {
    let process = Process()
    process.executableURL = url
    process.arguments = TartCommand.version.arguments
    let outputURL = temporaryCommandOutputURL()
    _ = FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
      showAlert(title: "无法验证 Tart", message: "无法创建临时验证文件。")
      return
    }
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    do {
      try process.run()
    } catch {
      try? outputHandle.close()
      try? FileManager.default.removeItem(at: outputURL)
      showAlert(title: "无法运行所选文件", message: error.localizedDescription)
      return
    }
    operationProcess = process
    operationOutputURL = outputURL
    operationWasCancelled = false
    showOperation("正在验证 Tart 可执行文件…")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let completed = ProcessDeadline.waitForExit(process, timeout: 5)
      try? outputHandle.close()
      let data = (try? Data(contentsOf: outputURL)) ?? Data()
      try? FileManager.default.removeItem(at: outputURL)
      let output = String(data: data, encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        guard let self else { return }
        let wasCancelled = self.operationWasCancelled
        if self.operationProcess === process { self.operationProcess = nil }
        self.operationWasCancelled = false
        self.hideOperation()
        guard !self.isQuitting, !wasCancelled else { return }
        guard completed, process.terminationStatus == 0,
          TartVersionValidation.isPlausible(output)
        else {
          let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
          let reason =
            completed
            ? (detail.isEmpty ? "所选文件没有返回可识别的 Tart 版本。" : String(detail.suffix(1000)))
            : "所选文件执行 --version 超过 5 秒，验证已终止。"
          self.showAlert(title: "所选文件不是可用的 Tart", message: reason)
          return
        }
        UserDefaults.standard.set(url.path, forKey: tartExecutablePathKey)
        self.appendApplicationLog(
          "已验证并选择自定义 Tart 可执行文件：\(url.path)（\(output.trimmingCharacters(in: .whitespacesAndNewlines))）"
        )
        self.resyncAfterTartExecutableChange()
      }
    }
  }

  @objc private func cancelOperation() {
    guard let process = operationProcess else { return }
    operationWasCancelled = true
    operationLabel?.stringValue = "正在取消操作…"
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
      showAlert(title: "请先安装 Tart", message: "使用上方安装引导完成 Tart 安装后再下载镜像。")
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
        ("官方镜像", popup),
        ("本地名称", target),
        ("镜像地址（可编辑）", source),
      ], width: 470)
    let alert = NSAlert()
    alert.messageText = "下载并克隆镜像"
    alert.informativeText = "镜像通常约 25 GB，下载时间取决于网络速度。默认账号和密码均为 admin。"
    alert.accessoryView = accessory
    alert.addButton(withTitle: "开始下载")
    alert.addButton(withTitle: "取消")
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
      showAlert(title: "镜像地址无效", message: "请输入 OCI 镜像地址或本地源 VM 名称。")
      return
    }
    runManagedTartCommand(
      TartCommand.clone(source: selectedSource, name: name).arguments,
      title: "正在下载 \(item.os) · \(item.kind)…"
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
      "查看详细配置…", #selector(showSelectedDetails), to: menu,
      enabled: selectedConfiguration != nil)
    menu.addItem(.separator())
    addMenuItem("导入 .tvm 归档…", #selector(importVMArchive), to: menu)
    addMenuItem(
      "导出为 .tvm 归档…", #selector(exportSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning
        && selectedConfiguration.map { discoveredNames.contains($0.name) } == true)
    addMenuItem(
      "复制虚拟机…", #selector(cloneSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "重命名…", #selector(renameSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "调整配置…", #selector(configureSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "启动选项…", #selector(configureSelectedVMRunOptions), to: menu,
      enabled: selectedConfiguration != nil)
    addMenuItem(
      "推送到 OCI Registry…", #selector(pushSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    #if arch(arm64)
      addMenuItem(
        "以可挂起模式启动一次", #selector(startSelectedVMSuspendable), to: menu,
        enabled: selectedConfiguration != nil && !state.isRunning)
    #endif
    menu.addItem(.separator())
    addMenuItem("复制 IP 地址", #selector(copySelectedIP), to: menu, enabled: state.isRunning)
    addMenuItem("挂起虚拟机", #selector(suspendSelectedVM), to: menu, enabled: state.isRunning)
    menu.addItem(.separator())
    addMenuItem("从最新 IPSW 创建 macOS VM…", #selector(createMacVM), to: menu)
    addMenuItem("创建空白 Linux VM…", #selector(createLinuxVM), to: menu)
    addMenuItem("清理 Tart 下载缓存…", #selector(pruneCaches), to: menu)
    menu.addItem(.separator())
    addMenuItem(
      "删除虚拟机和磁盘…", #selector(deleteVMAndDisk), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning
        && selectedConfiguration.map { discoveredNames.contains($0.name) } == true)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func cloneSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      let values = promptForValues(
        title: "复制虚拟机", message: "使用 APFS 写时复制创建本地副本。",
        fields: [
          ("源虚拟机", configuration.name, false),
          ("新名称", "\(configuration.name)-copy", true),
        ])
    else { return }
    let newName = values[1]
    guard validNewVMName(newName) else { return }
    runManagedTartCommand(
      TartCommand.clone(source: configuration.name, name: newName).arguments,
      title: "正在复制 \(configuration.name)…"
    ) { [weak self] success, _ in
      if success { self?.syncAndSelect(name: newName) }
    }
  }

  @objc private func importVMArchive() {
    let panel = NSOpenPanel()
    panel.title = "导入 Tart 虚拟机归档"
    panel.message = "选择由 tart export 创建的 .tvm 文件。"
    panel.allowedContentTypes = [UTType(filenameExtension: "tvm") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

    let suggestedName = archiveURL.deletingPathExtension().lastPathComponent
    guard
      let values = promptForValues(
        title: "导入虚拟机",
        message: "归档：\(archiveURL.lastPathComponent)",
        fields: [("本地名称", suggestedName, true)])
    else { return }
    let name = values[0]
    guard validNewVMName(name) else { return }
    runManagedTartCommand(
      TartCommand.importArchive(path: archiveURL.path, name: name).arguments,
      title: "正在导入 \(archiveURL.lastPathComponent)…"
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
    panel.title = "导出 Tart 虚拟机归档"
    panel.message = "导出可能需要较长时间，并占用接近虚拟机实际大小的磁盘空间。"
    panel.allowedContentTypes = [UTType(filenameExtension: "tvm") ?? .data]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(configuration.name).tvm"
    guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

    runManagedTartCommand(
      TartCommand.exportArchive(name: configuration.name, path: archiveURL.path).arguments,
      title: "正在导出 \(configuration.name)…"
    ) { success, _ in
      if success { NSWorkspace.shared.activateFileViewerSelecting([archiveURL]) }
    }
  }

  @objc private func showSelectedDetails() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.get(name: configuration.name).arguments,
      title: "正在读取 \(configuration.name) 配置…", showsSuccessAlert: false
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
        text: details.isEmpty ? "Tart 未返回配置内容。" : details)
    }
  }

  @objc private func renameSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    guard
      let values = promptForValues(
        title: "重命名虚拟机", message: "虚拟机必须处于停止状态。",
        fields: [
          ("当前名称", configuration.name, false),
          ("新名称", configuration.name, true),
        ])
    else { return }
    let newName = values[1]
    guard newName != configuration.name, validNewVMName(newName) else { return }
    runManagedTartCommand(
      TartCommand.rename(name: configuration.name, newName: newName).arguments, title: "正在重命名…"
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
    guard
      let values = promptForValues(
        title: "调整 \(configuration.name)",
        message: "只填写需要修改的项目。磁盘只能扩容，不能缩小。",
        fields: [
          ("CPU 核数", "", true), ("内存（MB）", "", true),
          ("显示分辨率", "", true), ("磁盘大小（GB）", "", true),
        ]
      )
    else { return }

    switch VMResourceValidation.validate(
      cpu: values[0], memory: values[1], display: values[2], diskSize: values[3])
    {
    case .valid:
      break
    case .invalidCPU:
      showAlert(title: "CPU 配置无效", message: "CPU 核数必须是 1 至 65535 之间的整数。")
      return
    case .invalidMemory:
      showAlert(title: "内存配置无效", message: "内存必须是以 MB 为单位的正整数。")
      return
    case .invalidDisplay:
      showAlert(title: "显示配置无效", message: "请输入 WIDTHxHEIGHT、WIDTHxHEIGHTpt 或 WIDTHxHEIGHTpx。")
      return
    case .invalidDiskSize:
      showAlert(title: "磁盘配置无效", message: "磁盘大小必须是 1 至 65535 之间的整数 GB。")
      return
    }

    let arguments = TartCommand.set(
      name: configuration.name,
      cpu: values[0].isEmpty ? nil : values[0],
      memory: values[1].isEmpty ? nil : values[1],
      display: values[2].isEmpty ? nil : values[2],
      diskSize: values[3].isEmpty ? nil : values[3]
    ).arguments
    guard arguments.count > 2 else { return }
    runManagedTartCommand(arguments, title: "正在更新虚拟机配置…") { [weak self] success, _ in
      if success { self?.syncTartState() }
    }
  }

  @objc private func configureSelectedVMRunOptions() {
    guard let configuration = selectedConfiguration else { return }
    let options = configuration.runOptions
    let headless = NSButton(
      checkboxWithTitle: "无图形界面（--no-graphics）", target: nil, action: nil)
    headless.state = options.headless ? .on : .off
    let noAudio = NSButton(
      checkboxWithTitle: "禁用音频直通（--no-audio）", target: nil, action: nil)
    noAudio.state = options.noAudio ? .on : .off
    let noClipboard = NSButton(
      checkboxWithTitle: "禁用主机与虚拟机剪贴板共享（--no-clipboard）", target: nil, action: nil)
    noClipboard.state = options.noClipboard ? .on : .off
    let suspendable = NSButton(
      checkboxWithTitle: "使用可挂起模式（--suspendable）", target: nil, action: nil)
    #if arch(arm64)
      suspendable.state = options.suspendable ? .on : .off
    #else
      suspendable.state = .off
      suspendable.isEnabled = false
      suspendable.toolTip = "可挂起模式仅适用于 Apple Silicon"
    #endif

    let stack = NSStackView(views: [headless, noAudio, noClipboard, suspendable])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 410, height: 112)
    let alert = NSAlert()
    alert.messageText = "\(configuration.name) 的启动选项"
    alert.informativeText = "这些选项会用于“启动”、双击启动和打开 TartR 时自动启动。"
    alert.accessoryView = stack
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
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
        title: "推送到 OCI Registry",
        message: "Registry 凭据由 Tart、Docker credential helper 或环境变量管理，TartR 不保存密码。",
        fields: [
          ("本地虚拟机", configuration.name, false),
          ("远程地址", "ghcr.io/组织/镜像:latest", true),
        ])
    else { return }
    let remoteName = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remoteName.isEmpty, remoteName.contains("/") else {
      showAlert(title: "远程地址无效", message: "请输入完整 OCI 地址，例如 ghcr.io/acme/macos:latest。")
      return
    }
    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = "推送 \(configuration.name)？"
    confirmation.informativeText = "将向 \(remoteName) 上传虚拟机镜像，可能消耗大量时间和网络流量。"
    confirmation.addButton(withTitle: "开始推送")
    confirmation.addButton(withTitle: "取消")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    runManagedTartCommand(
      TartCommand.push(name: configuration.name, remoteName: remoteName).arguments,
      title: "正在推送 \(configuration.name)…"
    ) { _, _ in }
  }

  @objc private func pruneCaches() {
    guard
      let values = promptForValues(
        title: "清理 Tart 下载缓存",
        message: "仅清理可重新下载的 OCI/IPSW 缓存，不删除本地虚拟机。至少填写一个条件。",
        fields: [
          ("早于天数", "30", true),
          ("缓存上限（GB）", "", true),
        ])
    else { return }
    let olderThan = values[0]
    let spaceBudget = values[1]
    guard olderThan.isEmpty || UInt(olderThan) != nil,
      spaceBudget.isEmpty || UInt(spaceBudget) != nil,
      !olderThan.isEmpty || !spaceBudget.isEmpty
    else {
      showAlert(title: "清理条件无效", message: "请至少填写一个非负整数条件。")
      return
    }
    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = "确认清理 Tart 缓存？"
    confirmation.informativeText = "被删除的 OCI 镜像层或 IPSW 需要在下次使用时重新下载。"
    confirmation.addButton(withTitle: "开始清理")
    confirmation.addButton(withTitle: "取消")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    runManagedTartCommand(
      TartCommand.pruneCaches(
        olderThan: olderThan.isEmpty ? nil : olderThan,
        spaceBudget: spaceBudget.isEmpty ? nil : spaceBudget
      ).arguments,
      title: "正在清理 Tart 缓存…"
    ) { _, _ in }
  }

  @objc private func copySelectedIP() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.ip(name: configuration.name, wait: 5).arguments, title: "正在获取 IP 地址…",
      showsSuccessAlert: false
    ) { success, output in
      guard success else { return }
      let ip = output.trimmingCharacters(in: .whitespacesAndNewlines)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(ip, forType: .string)
      self.showAlert(title: "IP 地址已复制", message: ip)
    }
  }

  @objc private func suspendSelectedVM() {
    guard let configuration = selectedConfiguration else { return }
    runManagedTartCommand(
      TartCommand.suspend(name: configuration.name).arguments, title: "正在挂起 \(configuration.name)…"
    ) { [weak self] success, _ in
      if success { self?.syncTartState() }
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
        showAlert(title: "需要 Apple Silicon", message: "Tart 只能在 Apple Silicon Mac 上创建 macOS VM。")
        return
      }
    #endif
    let defaultName = macOS ? "macos-vanilla" : "linux-vm"
    guard
      let values = promptForValues(
        title: macOS ? "从最新 IPSW 创建 macOS VM" : "创建空白 Linux VM",
        message: macOS
          ? "Tart 将下载 Apple 最新支持的 IPSW，之后需要手动完成系统安装。" : "创建后请通过 tart run --disk 挂载安装镜像。",
        fields: [("虚拟机名称", defaultName, true), ("磁盘大小（GB）", "50", true)]
      )
    else { return }
    guard validNewVMName(values[0]) else { return }
    guard
      VMResourceValidation.validate(cpu: "", memory: "", display: "", diskSize: values[1])
        == .valid
    else {
      showAlert(title: "磁盘大小无效", message: "请输入 1 至 65535 GB 之间的整数。")
      return
    }
    let arguments =
      macOS
      ? TartCommand.createMac(name: values[0], diskSize: values[1]).arguments
      : TartCommand.createLinux(name: values[0], diskSize: values[1]).arguments
    runManagedTartCommand(arguments, title: macOS ? "正在下载 IPSW 并创建 VM…" : "正在创建 Linux VM…") {
      [weak self] success, _ in
      if success { self?.syncAndSelect(name: values[0]) }
    }
  }

  @objc private func deleteVMAndDisk() {
    guard let configuration = selectedConfiguration else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "永久删除 \(configuration.name)？"
    alert.informativeText = "将执行 tart delete，虚拟机配置和磁盘数据无法恢复。请输入虚拟机名称确认。"
    let confirmationField = NSTextField()
    confirmationField.placeholderString = configuration.name
    confirmationField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = confirmationField
    alert.addButton(withTitle: "永久删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard confirmationField.stringValue == configuration.name else {
      showAlert(title: "名称不匹配", message: "未删除任何数据。")
      return
    }
    runManagedTartCommand(
      TartCommand.delete(name: configuration.name).arguments, title: "正在删除 \(configuration.name)…"
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
        string: "A native macOS manager for Tart virtual machines.\nhttps://tart.run/"),
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
    panel.title = "导出 TartR 诊断信息"
    panel.message = "报告不包含虚拟机名称、日志内容或 Registry 凭据。"
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
      showAlert(title: "无法导出诊断信息", message: error.localizedDescription)
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
      showAlert(title: "无法导出设置", message: "虚拟机设置无法编码。")
      return
    }

    let panel = NSSavePanel()
    panel.title = "导出 TartR 设置"
    panel.message = "设置文件包含 VM 名称和启动选项，但不包含日志或 Registry 凭据。"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "TartR-Settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data.write(to: url, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      showAlert(title: "无法导出设置", message: error.localizedDescription)
    }
  }

  @objc private func importSettings() {
    guard operationProcess == nil, !runtimes.values.contains(where: { $0.process.isRunning }) else {
      showAlert(title: "暂时无法导入设置", message: "请先等待任务结束并停止所有由 TartR 启动的虚拟机。")
      return
    }
    let panel = NSOpenPanel()
    panel.title = "导入 TartR 设置"
    panel.message = "选择由 TartR 导出的 JSON 设置文件。"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024,
      let document = try? JSONDecoder().decode(TartRSettingsDocument.self, from: data)
    else {
      showAlert(title: "设置文件无效", message: "文件无法读取、超过 5 MB，或不是有效的 TartR 设置。")
      return
    }
    switch TartRSettingsValidation.validate(document) {
    case .valid:
      break
    case .unsupportedSchema(let version):
      showAlert(title: "设置版本不受支持", message: "文件使用设置格式版本 \(version)，当前 TartR 无法导入。")
      return
    case .duplicateID, .duplicateName:
      showAlert(title: "设置文件有冲突", message: "文件包含重复的 VM 标识或名称。")
      return
    case .invalidName:
      showAlert(title: "设置文件有无效名称", message: "VM 名称不能为空、包含 / 或带有前后空白。")
      return
    }

    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = "导入 \(document.configurations.count) 台 VM 的设置？"
    confirmation.informativeText =
      "将替换当前保存的 \(configurations.count) 条设置。TartR 会自动保留当前有效配置作为备份，并重新发现本地 VM。"
    confirmation.addButton(withTitle: "导入并替换")
    confirmation.addButton(withTitle: "取消")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }

    configurations = document.configurations
    states = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, VMState.unknown) })
    searchField.stringValue = ""
    lastTableSignature = nil
    UserDefaults.standard.removeObject(forKey: selectedVMKey)
    saveConfigurations()
    refreshUI(forceTableReload: true)
    restoreSelection()
    syncTartState()
  }

  @objc private func showEnvironmentInfo() {
    if !tartInstalled {
      showTextViewer(title: "运行环境", text: environmentReport(tartVersion: "未安装"))
      return
    }
    runManagedTartCommand(
      TartCommand.version.arguments,
      title: "正在读取 Tart 版本…",
      showsSuccessAlert: false,
      showsFailureAlert: false
    ) { [weak self] success, output in
      guard let self else { return }
      let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
      self.showTextViewer(
        title: "运行环境",
        text: self.environmentReport(
          tartVersion: success && !value.isEmpty ? value : "无法读取"))
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
            title: "需要用户批准",
            message: "请在系统设置的“通用 > 登录项与扩展”中允许 TartR。")
          SMAppService.openSystemSettingsLoginItems()
        }
      @unknown default:
        showAlert(title: "无法修改登录项", message: "当前 macOS 返回了未知的登录项状态。")
      }
    } catch {
      showAlert(title: "无法修改登录项", message: error.localizedDescription)
    }
    updateLaunchAtLoginMenuItem()
  }

  private func updateLaunchAtLoginMenuItem() {
    guard let item = launchAtLoginMenuItem else { return }
    switch SMAppService.mainApp.status {
    case .enabled:
      item.state = .on
      item.title = "登录时启动 TartR"
    case .requiresApproval:
      item.state = .mixed
      item.title = "登录时启动 TartR（需要批准）"
    case .notRegistered, .notFound:
      item.state = .off
      item.title = "登录时启动 TartR"
    @unknown default:
      item.state = .off
      item.title = "登录时启动 TartR"
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
      showAlert(title: "无法启动 \(configuration.name)", message: error.localizedDescription)
    }
  }

  private func configureTartProcess(_ process: Process, arguments: [String]) {
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
    let outputURL = temporaryCommandOutputURL()
    _ = FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
      showAlert(title: "无法停止 \(configuration.name)", message: "无法创建临时日志文件。")
      return
    }
    configureTartProcess(
      process, arguments: TartCommand.stop(name: configuration.name, timeout: 8).arguments)
    process.standardError = outputHandle
    process.standardOutput = outputHandle
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try process.run()
        process.waitUntilExit()
        try? outputHandle.close()
        let errorData = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        DispatchQueue.main.async {
          guard let self else { return }
          self.syncTartState {
            if process.terminationStatus != 0, self.states[id]?.isRunning == true {
              let details = String(data: errorData, encoding: .utf8) ?? "tart stop 失败"
              self.showAlert(title: "无法停止 \(configuration.name)", message: details)
            }
          }
        }
      } catch {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
        DispatchQueue.main.async {
          self?.states[id] = .failed(-1)
          self?.refreshUI()
          self?.showAlert(title: "无法停止 \(configuration.name)", message: error.localizedDescription)
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
        ? "未找到 tart 命令。请检查 Tart 是否已安装，并查看该虚拟机日志。"
        : "Tart 已退出（状态码 \(process.terminationStatus)）。请查看该虚拟机日志。"
      self.states[id] = .failed(process.terminationStatus)
      self.refreshUI()
      self.showAlert(title: "\(configuration.name) 未能运行", message: message)
    }
  }

  private func syncTartState(completion: (() -> Void)? = nil) {
    guard !isQuitting else { return }
    if let completion { syncCompletions.append(completion) }
    guard !syncInProgress else { return }
    syncInProgress = true

    let process = Process()
    configureTartProcess(process, arguments: TartCommand.listLocalJSON.arguments)
    let outputURL = temporaryCommandOutputURL()
    _ = FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
      tartSyncError = "无法创建临时状态文件"
      finishSync()
      return
    }
    process.standardOutput = outputHandle
    process.standardError = outputHandle

    do {
      try process.run()
    } catch {
      try? outputHandle.close()
      try? FileManager.default.removeItem(at: outputURL)
      tartSyncError = error.localizedDescription
      finishSync()
      return
    }
    syncProcess = process
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let completedBeforeTimeout = ProcessDeadline.waitForExit(process, timeout: 15)
      try? outputHandle.close()
      let output = (try? Data(contentsOf: outputURL)) ?? Data()
      try? FileManager.default.removeItem(at: outputURL)
      DispatchQueue.main.async {
        guard let self else { return }
        if self.syncProcess === process { self.syncProcess = nil }
        if !completedBeforeTimeout {
          self.tartSyncError = "tart list 超过 15 秒未响应，已终止本次状态同步"
          self.finishSync()
        } else if process.terminationStatus == 0,
          let infos = try? TartListParser.parse(output)
        {
          self.applyTartState(infos)
        } else {
          self.tartInstalled = process.terminationStatus != 127
          self.tartSyncError = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if self.tartSyncError?.isEmpty != false, process.terminationStatus == 127 {
            self.tartSyncError = "尚未安装 Tart"
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
    guard operationProcess == nil else {
      showAlert(title: "已有操作正在进行", message: "请等待当前 Tart 操作完成或先取消。")
      return
    }

    let process = Process()
    let outputURL = temporaryCommandOutputURL()
    _ = FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
      showAlert(title: "无法运行 Tart", message: "无法创建临时任务日志文件。")
      completion(false, "无法创建临时任务日志文件")
      return
    }
    configureTartProcess(process, arguments: arguments)
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    do {
      try process.run()
    } catch {
      try? outputHandle.close()
      try? FileManager.default.removeItem(at: outputURL)
      showAlert(title: "无法运行 Tart", message: error.localizedDescription)
      completion(false, error.localizedDescription)
      return
    }
    operationProcess = process
    operationOutputURL = outputURL
    operationWasCancelled = false
    showOperation(title)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      process.waitUntilExit()
      try? outputHandle.close()
      let data = (try? Data(contentsOf: outputURL)) ?? Data()
      try? FileManager.default.removeItem(at: outputURL)
      let output = String(data: data, encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        guard let self else { return }
        let wasCancelled = self.operationWasCancelled
        self.operationProcess = nil
        self.operationWasCancelled = false
        self.hideOperation()
        let success = !wasCancelled && process.terminationStatus == 0
        self.appendApplicationLog(
          "tart \(arguments.joined(separator: " "))\nstatus=\(process.terminationStatus) cancelled=\(wasCancelled)\n\(output)"
        )
        if wasCancelled {
          // User cancellation is an expected outcome, not a success or failure alert.
        } else if success {
          if showsSuccessAlert {
            self.showAlert(
              title: "操作完成", message: title.replacingOccurrences(of: "正在", with: "已"))
          }
        } else if showsFailureAlert {
          let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
          let fallback =
            process.terminationReason == .uncaughtSignal
            ? "操作被意外中断（信号 \(process.terminationStatus)）"
            : "退出状态码 \(process.terminationStatus)"
          self.showAlert(
            title: "Tart 操作失败",
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
    operationOutputURL = nil
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
    guard let outputURL = operationOutputURL,
      let baseTitle = operationBaseTitle,
      let handle = try? FileHandle(forReadingFrom: outputURL)
    else { return }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    guard size > 0 else { return }
    let readSize = min(UInt64(4096), size)
    try? handle.seek(toOffset: size - readSize)
    guard let data = try? handle.read(upToCount: Int(readSize)),
      let text = String(data: data, encoding: .utf8)
    else { return }

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
      showAlert(title: "名称无效", message: "虚拟机名称不能为空，也不能包含 /。")
      return false
    case .duplicate:
      showAlert(title: "名称已存在", message: "“\(name)”已经存在。")
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
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
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

  private func temporaryCommandOutputURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("tartr-command-\(UUID().uuidString).log")
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

  private var tartExecutableURL: URL? {
    TartExecutableLocator.locate(explicitPath: configuredTartExecutablePath)
  }

  private var tartExecutableDescription: String {
    let locatedPath = tartExecutableURL?.path
    guard let configuredPath = configuredTartExecutablePath else {
      return locatedPath ?? "登录 shell PATH（未发现标准安装路径）"
    }
    if locatedPath == configuredPath { return "\(configuredPath)（自定义）" }
    if let locatedPath {
      return "\(locatedPath)（自定义路径不可用，已自动回退）"
    }
    return "\(configuredPath)（自定义路径不可用，将尝试登录 shell PATH）"
  }

  private var diagnosticTartExecutableDescription: String {
    tartExecutableDescription.replacingOccurrences(
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
      tartStatus = "未安装"
    } else if tartSyncError != nil {
      tartStatus = "状态同步异常"
    } else {
      tartStatus = "可用"
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
      Tart status: \(tartStatus)
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
      State synchronization: \(tartSyncError == nil ? "正常" : "异常")
      """
  }

  private func loadConfigurations() {
    let defaults = UserDefaults.standard
    let current = defaults.data(forKey: defaultsKey)
    let result = VMConfigurationRecovery.resolve(
      current: current,
      backup: defaults.data(forKey: defaultsBackupKey),
      legacy: legacyPreferenceDataValues(forKey: defaultsKey))
    configurations = result.configurations
    switch result.source {
    case .current:
      break
    case .backup:
      if let current { defaults.set(current, forKey: defaultsCorruptKey) }
      configurationRecoveryNotice = "当前配置数据无法读取，TartR 已从最近一次有效备份恢复。损坏的原始数据已保留用于诊断。"
      saveConfigurations()
    case .legacy:
      saveConfigurations()
    case .empty:
      if let current {
        defaults.set(current, forKey: defaultsCorruptKey)
        configurationRecoveryNotice = "当前配置数据和备份均无法读取。TartR 已保留损坏数据并创建空白虚拟机列表；本地 VM 会在状态同步后重新发现。"
      }
      saveConfigurations()
    }
    if defaults.string(forKey: selectedVMKey) == nil,
      let legacySelection = legacyPreferenceString(forKey: selectedVMKey)
    {
      defaults.set(legacySelection, forKey: selectedVMKey)
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
    if let current = defaults.data(forKey: defaultsKey), current != data,
      (try? JSONDecoder().decode([VMConfiguration].self, from: current)) != nil
    {
      defaults.set(current, forKey: defaultsBackupKey)
    }
    defaults.set(data, forKey: defaultsKey)
  }

  private func restoreSelection() {
    guard !visibleConfigurations.isEmpty else { return }
    let savedID = UserDefaults.standard.string(forKey: selectedVMKey).flatMap(
      UUID.init(uuidString:))
    let row =
      savedID.flatMap { id in visibleConfigurations.firstIndex(where: { $0.id == id }) } ?? 0
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  }

  private func refreshUI(forceTableReload: Bool = false) {
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
      let selectedID = UserDefaults.standard.string(forKey: selectedVMKey).flatMap(
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
      summaryLabel?.stringValue = "无法同步 Tart：\(tartSyncError)"
      summaryLabel?.textColor = .systemRed
    } else {
      let selectedCount = selectedConfigurations.count
      let selectionSuffix = selectedCount > 1 ? " 已选择 \(selectedCount) 台。" : ""
      if isFiltering {
        summaryLabel?.stringValue =
          "显示 \(visible.count) / \(total) 台虚拟机，\(runningCount) 台正在运行。\(selectionSuffix)"
      } else {
        summaryLabel?.stringValue =
          runningCount == 0
          ? "已发现/保存 \(total) 台虚拟机，没有正在运行的实例。\(selectionSuffix)"
          : "已发现/保存 \(total) 台虚拟机，\(runningCount) 台正在运行。\(selectionSuffix)"
      }
      summaryLabel?.textColor = .secondaryLabelColor
    }
  }

  private func refreshControls() {
    let operationBusy = operationProcess != nil
    imageButton?.isEnabled = tartInstalled && !operationBusy
    moreButton?.isEnabled = tartInstalled && !operationBusy
    let capabilities = selectionCapabilities
    let count = capabilities.selectionCount
    startButton?.title = count > 1 ? "启动 \(capabilities.startableIDs.count) 台" : "启动"
    stopButton?.title = count > 1 ? "停止 \(capabilities.stoppableIDs.count) 台" : "停止"
    deleteButton?.title = count > 1 ? "移除记录 (\(count))" : "移除记录"
    startButton?.toolTip = count > 1 ? "只启动所选项目中当前可以启动的虚拟机" : nil
    stopButton?.toolTip = count > 1 ? "只停止所选项目中正在启动或运行的虚拟机" : nil
    deleteButton?.toolTip = count > 1 ? "仅可批量移除本地不存在的保存记录，不会删除磁盘" : nil
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
    alert.addButton(withTitle: "好")
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
    alert.addButton(withTitle: "关闭")
    alert.addButton(withTitle: "复制")
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

  private func makeButton(_ title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .large
    return button
  }

  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = appTitle
    window.center()
    window.setFrameAutosaveName("TartRMainWindow")
    window.minSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.delegate = self

    let heading = NSTextField(labelWithString: "TartR")
    heading.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

    searchField = NSSearchField()
    searchField.placeholderString = "搜索虚拟机"
    searchField.setAccessibilityLabel("搜索虚拟机")
    searchField.sendsSearchStringImmediately = true
    searchField.target = self
    searchField.action = #selector(searchChanged)
    searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
    imageButton = makeButton("下载/克隆镜像…", action: #selector(downloadImage))
    let headingRow = NSStackView(views: [heading, NSView(), searchField, imageButton])
    headingRow.orientation = .horizontal
    headingRow.spacing = 10

    summaryLabel = NSTextField(labelWithString: "")
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.font = NSFont.systemFont(ofSize: 12)

    installBox = NSBox()
    installBox.boxType = .custom
    installBox.titlePosition = .noTitle
    installBox.cornerRadius = 8
    installBox.fillColor = NSColor.systemYellow.withAlphaComponent(0.10)
    installBox.borderColor = NSColor.systemYellow.withAlphaComponent(0.45)
    installBox.borderWidth = 1
    let installLabel = NSTextField(
      wrappingLabelWithString: "尚未检测到 Tart。请先通过 Homebrew 安装：brew install cirruslabs/cli/tart")
    installLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let installButton = NSButton(
      title: "复制命令并打开终端", target: self, action: #selector(copyInstallCommandAndOpenTerminal))
    let chooseTartButton = NSButton(
      title: "选择已有 Tart…", target: self, action: #selector(chooseTartExecutable))
    let docsButton = NSButton(title: "安装文档", target: self, action: #selector(openQuickStart))
    let installRow = NSStackView(views: [
      installLabel, NSView(), installButton, chooseTartButton, docsButton,
    ])
    installRow.orientation = .horizontal
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
    nameField.placeholderString = "手动添加虚拟机名称（本地 VM 通常会自动发现）"
    nameField.setAccessibilityLabel("手动添加虚拟机名称")
    nameField.delegate = self
    nameField.font = NSFont.systemFont(ofSize: 13)

    addButton = makeButton("添加", action: #selector(addVM))
    addButton.isEnabled = false
    addButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

    let inputRow = NSStackView(views: [nameField, addButton])
    inputRow.orientation = .horizontal
    inputRow.spacing = 10

    tableView = NSTableView()
    tableView.delegate = self
    tableView.dataSource = self
    tableView.rowHeight = 36
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = true
    tableView.setAccessibilityLabel("Tart 虚拟机列表")
    tableView.autosaveName = "TartRVMTable"
    tableView.autosaveTableColumns = true
    tableView.doubleAction = #selector(toggleSelectedVM)
    tableView.target = self

    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    nameColumn.title = "虚拟机名称"
    nameColumn.minWidth = 230
    nameColumn.sortDescriptorPrototype = NSSortDescriptor(
      key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
    statusColumn.title = "状态"
    statusColumn.width = 125
    statusColumn.minWidth = 110
    statusColumn.sortDescriptorPrototype = NSSortDescriptor(key: "status", ascending: true)
    let diskColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
    diskColumn.title = "磁盘"
    diskColumn.width = 80
    diskColumn.minWidth = 70
    diskColumn.sortDescriptorPrototype = NSSortDescriptor(key: "disk", ascending: true)
    let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    sizeColumn.title = "实际占用"
    sizeColumn.width = 90
    sizeColumn.minWidth = 80
    sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
    let autoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("autostart"))
    autoColumn.title = "打开 App 时启动"
    autoColumn.width = 125
    autoColumn.minWidth = 110
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
    scrollView.borderType = .bezelBorder

    startButton = makeButton("启动", action: #selector(startSelectedVM))
    stopButton = makeButton("停止", action: #selector(stopSelectedVM))
    logButton = makeButton("打开日志", action: #selector(openSelectedLog))
    moreButton = makeButton("更多操作…", action: #selector(showMoreMenu(_:)))
    deleteButton = makeButton("移除记录", action: #selector(deleteSelectedVM))
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
      title: "取消操作", target: self, action: #selector(cancelOperation))
    cancelOperationButton.bezelStyle = .inline
    cancelOperationButton.isHidden = true
    let operationRow = NSStackView(views: [
      operationSpinner, operationLabel, NSView(), cancelOperationButton,
    ])
    operationRow.orientation = .horizontal
    operationRow.spacing = 8

    let hint = NSTextField(
      labelWithString: "状态每 5 秒及窗口激活时与 Tart 同步。退出时可选择停止 VM 或让它们继续在后台运行。")
    hint.textColor = .tertiaryLabelColor
    hint.font = NSFont.systemFont(ofSize: 11)

    let stack = NSStackView(views: [
      headingRow, summaryLabel, installBox, inputRow, scrollView, buttonRow, operationRow, hint,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)

    inputRow.translatesAutoresizingMaskIntoConstraints = false
    headingRow.translatesAutoresizingMaskIntoConstraints = false
    installBox.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    operationRow.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
      headingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      installBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
      inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
      buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      operationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  private func buildMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()

    let about = NSMenuItem(title: "关于 TartR", action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    appMenu.addItem(about)
    appMenu.addItem(.separator())
    let show = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "1")
    show.target = self
    appMenu.addItem(show)
    let launchAtLogin = NSMenuItem(
      title: "登录时启动 TartR", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    launchAtLogin.target = self
    launchAtLoginMenuItem = launchAtLogin
    appMenu.addItem(launchAtLogin)
    updateLaunchAtLoginMenuItem()
    let log = NSMenuItem(title: "打开所选日志", action: #selector(openSelectedLog), keyEquivalent: "l")
    log.target = self
    appMenu.addItem(log)
    let appLog = NSMenuItem(
      title: "打开 TartR 日志", action: #selector(openApplicationLog), keyEquivalent: "")
    appLog.target = self
    appMenu.addItem(appLog)
    let chooseTart = NSMenuItem(
      title: "选择 Tart 可执行文件…", action: #selector(chooseTartExecutable), keyEquivalent: "")
    chooseTart.target = self
    appMenu.addItem(chooseTart)
    let resetTart = NSMenuItem(
      title: "恢复自动检测 Tart", action: #selector(resetTartExecutable), keyEquivalent: "")
    resetTart.target = self
    appMenu.addItem(resetTart)
    let environment = NSMenuItem(
      title: "运行环境…", action: #selector(showEnvironmentInfo), keyEquivalent: "")
    environment.target = self
    appMenu.addItem(environment)
    let diagnostics = NSMenuItem(
      title: "导出诊断信息…", action: #selector(exportDiagnostics), keyEquivalent: "")
    diagnostics.target = self
    appMenu.addItem(diagnostics)
    let exportSettingsItem = NSMenuItem(
      title: "导出 TartR 设置…", action: #selector(exportSettings), keyEquivalent: "")
    exportSettingsItem.target = self
    appMenu.addItem(exportSettingsItem)
    let importSettingsItem = NSMenuItem(
      title: "导入 TartR 设置…", action: #selector(importSettings), keyEquivalent: "")
    importSettingsItem.target = self
    appMenu.addItem(importSettingsItem)
    let refresh = NSMenuItem(title: "刷新状态", action: #selector(refreshNow), keyEquivalent: "r")
    refresh.target = self
    appMenu.addItem(refresh)
    let help = NSMenuItem(title: "Tart 快速入门", action: #selector(openQuickStart), keyEquivalent: "?")
    help.target = self
    appMenu.addItem(help)
    appMenu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 \(appTitle)", action: #selector(quitApp), keyEquivalent: "q")
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
