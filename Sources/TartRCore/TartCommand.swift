import Foundation

public enum TartCommand: Equatable, Sendable {
  case listLocalJSON
  case run(name: String, suspendable: Bool)
  case stop(name: String, timeout: Int)
  case clone(source: String, name: String)
  case rename(name: String, newName: String)
  case delete(name: String)
  case ip(name: String, wait: Int)
  case suspend(name: String)
  case get(name: String)
  case push(name: String, remoteName: String)
  case pruneCaches(olderThan: String?, spaceBudget: String?)
  case set(name: String, cpu: String?, memory: String?, display: String?, diskSize: String?)
  case createMac(name: String, diskSize: String)
  case createLinux(name: String, diskSize: String)

  public var arguments: [String] {
    switch self {
    case .listLocalJSON:
      return ["list", "--source", "local", "--format", "json"]
    case .run(let name, let suspendable):
      return ["run"] + (suspendable ? ["--suspendable"] : []) + [name]
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
    case .get(let name):
      return ["get", name, "--format", "json"]
    case .push(let name, let remoteName):
      return ["push", name, remoteName]
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
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String] {
    var paths: [String] = []
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
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    candidatePaths(environment: environment, homeDirectory: homeDirectory)
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
