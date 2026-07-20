import Foundation

public enum TartCommand: Equatable, Sendable {
  case version
  case listLocalJSON
  case run(name: String, options: VMRunOptions)
  case stop(name: String, timeout: Int)
  case clone(source: String, name: String)
  case rename(name: String, newName: String)
  case delete(name: String)
  case ip(name: String, wait: Int)
  case suspend(name: String)
  case execShell(name: String, command: String)
  case get(name: String)
  case push(name: String, remoteName: String)
  case exportArchive(name: String, path: String)
  case importArchive(path: String, name: String)
  case pruneCaches(olderThan: String?, spaceBudget: String?)
  case set(name: String, cpu: String?, memory: String?, display: String?, diskSize: String?)
  case createMac(name: String, diskSize: String)
  case createLinux(name: String, diskSize: String)

  public var arguments: [String] {
    switch self {
    case .version:
      return ["--version"]
    case .listLocalJSON:
      return ["list", "--source", "local", "--format", "json"]
    case .run(let name, let options):
      var result = ["run"]
      if options.headless { result.append("--no-graphics") }
      if options.noAudio { result.append("--no-audio") }
      if options.noClipboard { result.append("--no-clipboard") }
      if options.suspendable { result.append("--suspendable") }
      result.append(name)
      return result
    case .stop(let name, let timeout):
      return ["stop", name, "--timeout", String(timeout)]
    case .clone(let source, let name):
      return ["clone", source, name]
    case .rename(let name, let newName):
      return ["rename", name, newName]
    case .delete(let name):
      return ["delete", name]
    case .ip(let name, let wait):
      return ["ip", name, "--wait", String(wait)]
    case .suspend(let name):
      return ["suspend", name]
    case .execShell(let name, let command):
      return ["exec", name, "/bin/zsh", "-lc", command]
    case .get(let name):
      return ["get", name, "--format", "json"]
    case .push(let name, let remoteName):
      return ["push", name, remoteName]
    case .exportArchive(let name, let path):
      return ["export", name, path]
    case .importArchive(let path, let name):
      return ["import", path, name]
    case .pruneCaches(let olderThan, let spaceBudget):
      var result = ["prune", "--entries", "caches"]
      if let olderThan, !olderThan.isEmpty { result += ["--older-than", olderThan] }
      if let spaceBudget, !spaceBudget.isEmpty { result += ["--space-budget", spaceBudget] }
      return result
    case .set(let name, let cpu, let memory, let display, let diskSize):
      var result = ["set", name]
      for (option, value) in [
        ("--cpu", cpu), ("--memory", memory),
        ("--display", display), ("--disk-size", diskSize),
      ] {
        if let value, !value.isEmpty { result += [option, value] }
      }
      return result
    case .createMac(let name, let diskSize):
      return ["create", "--from-ipsw", "latest", "--disk-size", diskSize, name]
    case .createLinux(let name, let diskSize):
      return ["create", "--linux", "--disk-size", diskSize, name]
    }
  }
}

public enum TartExecutableLocator {
  public static func candidatePaths(
    explicitPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String] {
    var paths: [String] = []
    if let explicitPath, !explicitPath.isEmpty { paths.append(explicitPath) }
    if let override = environment["TART_EXECUTABLE"], !override.isEmpty { paths.append(override) }
    paths += [
      "/opt/homebrew/bin/tart",
      "/usr/local/bin/tart",
      homeDirectory.appendingPathComponent(".local/bin/tart").path,
    ]
    return paths.reduce(into: []) { result, path in
      if !result.contains(path) { result.append(path) }
    }
  }

  public static func locate(
    explicitPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    candidatePaths(
      explicitPath: explicitPath, environment: environment, homeDirectory: homeDirectory
    )
    .first(where: isExecutable)
    .map(URL.init(fileURLWithPath:))
  }
}

public enum TartShellBridge {
  public static let script = """
    export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
    tart_path="${TART_EXECUTABLE:-$(command -v tart 2>/dev/null)}"
    if [[ -z "$tart_path" || ! -x "$tart_path" ]]; then
      print -u2 "找不到 tart 命令。请确认 Tart 已安装，并位于 Homebrew、~/.local/bin 或登录 shell 的 PATH 中。"
      exit 127
    fi
    exec "$tart_path" "$@"
    """

  public static func arguments(for tartArguments: [String]) -> [String] {
    ["-lic", script, "TartR"] + tartArguments
  }
}

public enum TartCommandAuditLog {
  public static func format(
    arguments: [String], terminationStatus: Int32, cancelled: Bool, output: String
  ) -> String {
    if arguments.first == "exec" {
      let vmName = arguments.indices.contains(1) ? arguments[1] : "unknown"
      return
        "tart exec \(vmName) <guest command and output redacted>\nstatus=\(terminationStatus) cancelled=\(cancelled)"
    }
    return
      "tart \(arguments.joined(separator: " "))\nstatus=\(terminationStatus) cancelled=\(cancelled)\n\(output)"
  }
}
