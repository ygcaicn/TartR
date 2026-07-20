import AppKit
import Darwin
import Foundation
import TartRCore

private let appTitle = "TartR"
private let defaultsKey = "vmConfigurations.v2"
private let selectedVMKey = "selectedVM.v2"
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
  NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
  private var window: NSWindow!
  private var tableView: NSTableView!
  private var nameField: NSTextField!
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

  private var configurations: [VMConfiguration] = []
  private var states: [UUID: VMState] = [:]
  private var runtimes: [UUID: VMRuntime] = [:]
  private var discoveredNames: Set<String> = []
  private var infoByName: [String: TartVMInfo] = [:]
  private var syncTimer: Timer?
  private var syncInProgress = false
  private var syncCompletions: [() -> Void] = []
  private var tartSyncError: String?
  private var tartInstalled = true
  private var operationProcess: Process?
  private var isQuitting = false

  private lazy var logsDirectory: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/TartR", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  private lazy var applicationLogURL = logsDirectory.appendingPathComponent("TartR.log")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    loadConfigurations()
    buildMenu()
    buildWindow()
    restoreSelection()
    for configuration in configurations { states[configuration.id] = .unknown }
    refreshUI()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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
    syncTartState()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    syncTartState()
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    syncTimer?.invalidate()
    var runningProcesses = runtimes.values.map(\.process).filter(\.isRunning)
    if let operationProcess, operationProcess.isRunning {
      runningProcesses.append(operationProcess)
    }
    guard !runningProcesses.isEmpty else { return .terminateNow }
    guard !isQuitting else { return .terminateLater }
    isQuitting = true

    for (id, runtime) in runtimes where runtime.process.isRunning {
      runtime.expectedStop = true
      states[id] = .stopping
      runtime.process.terminate()
    }
    operationProcess?.terminate()
    refreshUI()

    DispatchQueue.global(qos: .userInitiated).async {
      let deadline = Date().addingTimeInterval(8)
      while runningProcesses.contains(where: \.isRunning) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
      }
      for process in runningProcesses where process.isRunning {
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

  func numberOfRows(in tableView: NSTableView) -> Int {
    configurations.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard configurations.indices.contains(row), let identifier = tableColumn?.identifier else {
      return nil
    }
    let configuration = configurations[row]

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
    refreshControls()
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
    tableView.reloadData()
    tableView.selectRowIndexes(
      IndexSet(integer: configurations.count - 1), byExtendingSelection: false)
    tableView.scrollRowToVisible(configurations.count - 1)
    refreshUI()
  }

  @objc private func deleteSelectedVM() {
    guard let row = selectedRow, configurations.indices.contains(row) else { return }
    let configuration = configurations[row]
    guard !discoveredNames.contains(configuration.name) else {
      showAlert(
        title: "无法移除本地虚拟机", message: "这是 Tart 已创建的本地虚拟机。TartR 只移除手动保存但本地不存在的记录，不会直接删除虚拟机磁盘。")
      return
    }
    guard states[configuration.id]?.isRunning != true else {
      showAlert(title: "请先停止虚拟机", message: "停止“\(configuration.name)”后才能从列表中删除。")
      return
    }

    configurations.remove(at: row)
    states.removeValue(forKey: configuration.id)
    saveConfigurations()
    tableView.reloadData()
    if !configurations.isEmpty {
      tableView.selectRowIndexes(
        IndexSet(integer: min(row, configurations.count - 1)), byExtendingSelection: false)
    }
    refreshUI()
  }

  @objc private func startSelectedVM() {
    guard let id = selectedConfiguration?.id else { return }
    startVM(id: id, verifyFirst: true)
  }

  @objc private func stopSelectedVM() {
    guard let id = selectedConfiguration?.id else { return }
    stopVM(id: id)
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
    guard configurations.indices.contains(sender.tag) else { return }
    configurations[sender.tag].autoStart = sender.state == .on
    saveConfigurations()
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

  @objc private func cancelOperation() {
    operationProcess?.terminate()
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
    alert.messageText = "下载并克隆官方镜像"
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
      "复制虚拟机…", #selector(cloneSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "重命名…", #selector(renameSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "调整配置…", #selector(configureSelectedVM), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    addMenuItem(
      "以可挂起模式启动", #selector(startSelectedVMSuspendable), to: menu,
      enabled: selectedConfiguration != nil && !state.isRunning)
    menu.addItem(.separator())
    addMenuItem("复制 IP 地址", #selector(copySelectedIP), to: menu, enabled: state.isRunning)
    addMenuItem("挂起虚拟机", #selector(suspendSelectedVM), to: menu, enabled: state.isRunning)
    menu.addItem(.separator())
    addMenuItem("从最新 IPSW 创建 macOS VM…", #selector(createMacVM), to: menu)
    addMenuItem("创建空白 Linux VM…", #selector(createLinuxVM), to: menu)
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

    var arguments = ["set", configuration.name]
    let optionNames = ["--cpu", "--memory", "--display", "--disk-size"]
    for (index, value) in values.enumerated() where !value.isEmpty {
      arguments += [optionNames[index], value]
    }
    guard arguments.count > 2 else { return }
    runManagedTartCommand(arguments, title: "正在更新虚拟机配置…") { [weak self] success, _ in
      if success { self?.syncTartState() }
    }
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
    guard validNewVMName(values[0]), Int(values[1]) != nil else {
      showAlert(title: "输入无效", message: "请填写有效名称和磁盘大小。")
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

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func startVM(id: UUID, verifyFirst: Bool, suspendable: Bool = false) {
    guard let configuration = configurations.first(where: { $0.id == id }) else { return }
    guard runtimes[id]?.process.isRunning != true else { return }
    guard states[id]?.isRunning != true else { return }

    if verifyFirst {
      states[id] = .unknown
      refreshUI()
      syncTartState { [weak self] in
        guard let self else { return }
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
      let displayedCommand =
        suspendable
        ? "tart run --suspendable \(configuration.name)"
        : "tart run \(configuration.name)"
      handle.write(Data("\n[\(stamp)] Starting: \(displayedCommand)\n".utf8))

      let process = Process()
      configureTartProcess(
        process,
        arguments: TartCommand.run(name: configuration.name, suspendable: suspendable).arguments)
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
    if let executable = TartExecutableLocator.locate() {
      process.executableURL = executable
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = TartShellBridge.arguments(for: arguments)
    }
  }

  private func stopVM(id: UUID) {
    guard let configuration = configurations.first(where: { $0.id == id }) else { return }
    guard states[id]?.isRunning == true else { return }
    states[id] = .stopping
    refreshUI()

    if let runtime = runtimes[id], runtime.process.isRunning {
      runtime.expectedStop = true
      runtime.process.terminate()
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

    DispatchQueue.global(qos: .utility).async { [weak self] in
      do {
        try process.run()
        process.waitUntilExit()
        try? outputHandle.close()
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        DispatchQueue.main.async {
          guard let self else { return }
          if process.terminationStatus == 0,
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
      } catch {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
        DispatchQueue.main.async {
          self?.tartSyncError = error.localizedDescription
          self?.finishSync()
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
    completion: @escaping (Bool, String) -> Void
  ) {
    guard operationProcess?.isRunning != true else {
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
    operationProcess = process
    showOperation(title)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try process.run()
        process.waitUntilExit()
        try? outputHandle.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        let output = String(data: data, encoding: .utf8) ?? ""
        DispatchQueue.main.async {
          guard let self else { return }
          self.operationProcess = nil
          self.hideOperation()
          let success = process.terminationStatus == 0
          self.appendApplicationLog(
            "tart \(arguments.joined(separator: " "))\nstatus=\(process.terminationStatus)\n\(output)"
          )
          if success {
            if showsSuccessAlert {
              self.showAlert(
                title: "操作完成", message: title.replacingOccurrences(of: "正在", with: "已"))
            }
          } else if process.terminationReason != .uncaughtSignal {
            let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.showAlert(
              title: "Tart 操作失败",
              message: details.isEmpty
                ? "退出状态码 \(process.terminationStatus)" : String(details.suffix(3000)))
          }
          completion(success, output)
          self.syncTartState()
        }
      } catch {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
        DispatchQueue.main.async {
          guard let self else { return }
          self.operationProcess = nil
          self.hideOperation()
          self.showAlert(title: "无法运行 Tart", message: error.localizedDescription)
          completion(false, error.localizedDescription)
        }
      }
    }
  }

  private func showOperation(_ title: String) {
    operationLabel?.stringValue = title
    operationLabel?.isHidden = false
    operationSpinner?.isHidden = false
    operationSpinner?.startAnimation(nil)
    cancelOperationButton?.isHidden = false
    imageButton?.isEnabled = false
    moreButton?.isEnabled = false
  }

  private func hideOperation() {
    operationLabel?.isHidden = true
    operationSpinner?.stopAnimation(nil)
    operationSpinner?.isHidden = true
    cancelOperationButton?.isHidden = true
    imageButton?.isEnabled = tartInstalled
    moreButton?.isEnabled = true
  }

  private func syncAndSelect(name: String) {
    syncTartState { [weak self] in
      guard let self, let row = self.configurations.firstIndex(where: { $0.name == name }) else {
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

  private var selectedRow: Int? {
    guard let tableView, tableView.selectedRow >= 0 else { return nil }
    return tableView.selectedRow
  }

  private var selectedConfiguration: VMConfiguration? {
    guard let row = selectedRow, configurations.indices.contains(row) else { return nil }
    return configurations[row]
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

  private func loadConfigurations() {
    if let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([VMConfiguration].self, from: data)
    {
      configurations = decoded
    } else if let data = legacyPreferenceData(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([VMConfiguration].self, from: data)
    {
      configurations = decoded
      saveConfigurations()
    } else {
      configurations = []
      saveConfigurations()
    }
    if UserDefaults.standard.string(forKey: selectedVMKey) == nil,
      let legacySelection = legacyPreferenceString(forKey: selectedVMKey)
    {
      UserDefaults.standard.set(legacySelection, forKey: selectedVMKey)
    }
    for configuration in configurations { states[configuration.id] = .unknown }
  }

  private func legacyPreferenceData(forKey key: String) -> Data? {
    for appID in legacyAppIDs {
      if let data = CFPreferencesCopyAppValue(key as CFString, appID as CFString) as? Data {
        return data
      }
    }
    return nil
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
    if let data = try? JSONEncoder().encode(configurations) {
      UserDefaults.standard.set(data, forKey: defaultsKey)
    }
  }

  private func restoreSelection() {
    guard !configurations.isEmpty else { return }
    let savedID = UserDefaults.standard.string(forKey: selectedVMKey).flatMap(
      UUID.init(uuidString:))
    let row = savedID.flatMap { id in configurations.firstIndex(where: { $0.id == id }) } ?? 0
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  }

  private func refreshUI() {
    tableView?.reloadData()
    refreshControls()
    let runningCount = states.values.filter { state in
      if case .running = state { return true }
      return false
    }.count
    let total = configurations.count
    if let tartSyncError, !tartSyncError.isEmpty {
      summaryLabel?.stringValue = "无法同步 Tart：\(tartSyncError)"
      summaryLabel?.textColor = .systemRed
    } else {
      summaryLabel?.stringValue =
        runningCount == 0
        ? "已发现/保存 \(total) 台虚拟机，没有正在运行的实例。"
        : "已发现/保存 \(total) 台虚拟机，\(runningCount) 台正在运行。"
      summaryLabel?.textColor = .secondaryLabelColor
    }
  }

  private func refreshControls() {
    let operationBusy = operationProcess?.isRunning == true
    imageButton?.isEnabled = tartInstalled && !operationBusy
    moreButton?.isEnabled = tartInstalled && !operationBusy
    guard let selected = selectedConfiguration else {
      startButton?.isEnabled = false
      stopButton?.isEnabled = false
      deleteButton?.isEnabled = false
      logButton?.isEnabled = false
      return
    }
    let state = states[selected.id] ?? .unknown
    if case .unknown = state {
      startButton?.isEnabled = false
    } else {
      startButton?.isEnabled = !state.isRunning
    }
    stopButton?.isEnabled = state.isRunning
    deleteButton?.isEnabled = !state.isRunning && !discoveredNames.contains(selected.name)
    logButton?.isEnabled = true
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
    window.minSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.delegate = self

    let heading = NSTextField(labelWithString: "TartR")
    heading.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

    imageButton = makeButton("下载官方镜像…", action: #selector(downloadImage))
    let headingRow = NSStackView(views: [heading, NSView(), imageButton])
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
    let docsButton = NSButton(title: "安装文档", target: self, action: #selector(openQuickStart))
    let installRow = NSStackView(views: [installLabel, NSView(), installButton, docsButton])
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
    tableView.doubleAction = #selector(toggleSelectedVM)
    tableView.target = self

    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    nameColumn.title = "虚拟机名称"
    nameColumn.minWidth = 230
    let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
    statusColumn.title = "状态"
    statusColumn.width = 125
    statusColumn.minWidth = 110
    let diskColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
    diskColumn.title = "磁盘"
    diskColumn.width = 80
    diskColumn.minWidth = 70
    let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    sizeColumn.title = "实际占用"
    sizeColumn.width = 90
    sizeColumn.minWidth = 80
    let autoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("autostart"))
    autoColumn.title = "打开 App 时启动"
    autoColumn.width = 125
    autoColumn.minWidth = 110
    tableView.addTableColumn(nameColumn)
    tableView.addTableColumn(statusColumn)
    tableView.addTableColumn(diskColumn)
    tableView.addTableColumn(sizeColumn)
    tableView.addTableColumn(autoColumn)

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

    let hint = NSTextField(labelWithString: "状态每 5 秒及窗口激活时与 Tart 同步。退出 TartR 只停止由 TartR 启动的虚拟机。")
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
    let log = NSMenuItem(title: "打开所选日志", action: #selector(openSelectedLog), keyEquivalent: "l")
    log.target = self
    appMenu.addItem(log)
    let appLog = NSMenuItem(
      title: "打开 TartR 日志", action: #selector(openApplicationLog), keyEquivalent: "")
    appLog.target = self
    appMenu.addItem(appLog)
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
