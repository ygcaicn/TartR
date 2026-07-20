import Foundation

public struct TartVMInfo: Codable, Equatable, Sendable {
  public let source: String
  public let name: String
  public let disk: Int?
  public let size: Int?
  public let running: Bool
  public let state: String

  enum CodingKeys: String, CodingKey {
    case source = "Source"
    case name = "Name"
    case disk = "Disk"
    case size = "Size"
    case running = "Running"
    case state = "State"
  }

  public init(
    source: String, name: String, disk: Int? = nil, size: Int? = nil,
    running: Bool, state: String
  ) {
    self.source = source
    self.name = name
    self.disk = disk
    self.size = size
    self.running = running
    self.state = state
  }
}

public struct VMRunOptions: Codable, Equatable, Sendable {
  public var headless: Bool
  public var noAudio: Bool
  public var noClipboard: Bool
  public var suspendable: Bool

  public init(
    headless: Bool = false,
    noAudio: Bool = false,
    noClipboard: Bool = false,
    suspendable: Bool = false
  ) {
    self.headless = headless
    self.noAudio = noAudio
    self.noClipboard = noClipboard
    self.suspendable = suspendable
  }

  private enum CodingKeys: String, CodingKey {
    case headless
    case noAudio
    case noClipboard
    case suspendable
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    headless = try container.decodeIfPresent(Bool.self, forKey: .headless) ?? false
    noAudio = try container.decodeIfPresent(Bool.self, forKey: .noAudio) ?? false
    noClipboard = try container.decodeIfPresent(Bool.self, forKey: .noClipboard) ?? false
    suspendable = try container.decodeIfPresent(Bool.self, forKey: .suspendable) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(headless, forKey: .headless)
    try container.encode(noAudio, forKey: .noAudio)
    try container.encode(noClipboard, forKey: .noClipboard)
    try container.encode(suspendable, forKey: .suspendable)
  }
}

public struct VMConfiguration: Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var autoStart: Bool
  public var runOptions: VMRunOptions

  public init(
    id: UUID = UUID(),
    name: String,
    autoStart: Bool = false,
    runOptions: VMRunOptions = VMRunOptions()
  ) {
    self.id = id
    self.name = name
    self.autoStart = autoStart
    self.runOptions = runOptions
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case autoStart
    case runOptions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    runOptions =
      try container.decodeIfPresent(VMRunOptions.self, forKey: .runOptions) ?? VMRunOptions()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(autoStart, forKey: .autoStart)
    try container.encode(runOptions, forKey: .runOptions)
  }
}

public enum VMConfigurationRecoverySource: Equatable, Sendable {
  case current
  case backup
  case legacy
  case empty
}

public struct VMConfigurationRecoveryResult: Equatable, Sendable {
  public let configurations: [VMConfiguration]
  public let source: VMConfigurationRecoverySource

  public init(configurations: [VMConfiguration], source: VMConfigurationRecoverySource) {
    self.configurations = configurations
    self.source = source
  }
}

public enum VMConfigurationRecovery {
  public static func resolve(
    current: Data?,
    backup: Data?,
    legacy: [Data]
  ) -> VMConfigurationRecoveryResult {
    let decoder = JSONDecoder()
    if let current, let decoded = try? decoder.decode([VMConfiguration].self, from: current) {
      return VMConfigurationRecoveryResult(configurations: decoded, source: .current)
    }
    if let backup, let decoded = try? decoder.decode([VMConfiguration].self, from: backup) {
      return VMConfigurationRecoveryResult(configurations: decoded, source: .backup)
    }
    for data in legacy {
      if let decoded = try? decoder.decode([VMConfiguration].self, from: data) {
        return VMConfigurationRecoveryResult(configurations: decoded, source: .legacy)
      }
    }
    return VMConfigurationRecoveryResult(configurations: [], source: .empty)
  }
}

public struct TartRSettingsDocument: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let exportedByVersion: String
  public let configurations: [VMConfiguration]

  public init(
    schemaVersion: Int = TartRSettingsDocument.currentSchemaVersion,
    exportedByVersion: String,
    configurations: [VMConfiguration]
  ) {
    self.schemaVersion = schemaVersion
    self.exportedByVersion = exportedByVersion
    self.configurations = configurations
  }
}

public enum TartRSettingsValidation: Equatable, Sendable {
  case valid
  case unsupportedSchema(Int)
  case duplicateID
  case duplicateName
  case invalidName

  public static func validate(_ document: TartRSettingsDocument) -> TartRSettingsValidation {
    guard document.schemaVersion == TartRSettingsDocument.currentSchemaVersion else {
      return .unsupportedSchema(document.schemaVersion)
    }
    guard Set(document.configurations.map(\.id)).count == document.configurations.count else {
      return .duplicateID
    }
    var normalizedNames: Set<String> = []
    for configuration in document.configurations {
      let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name == configuration.name, !name.contains("/") else {
        return .invalidName
      }
      guard normalizedNames.insert(name.lowercased()).inserted else { return .duplicateName }
    }
    return .valid
  }
}

public enum VMState: Equatable, Sendable {
  case unknown
  case missing
  case stopped
  case suspended
  case starting
  case running
  case stopping
  case failed(Int32)

  public var label: String {
    switch self {
    case .unknown: return "状态未知"
    case .missing: return "本地不存在"
    case .stopped: return "已停止"
    case .suspended: return "已挂起"
    case .starting: return "正在启动…"
    case .running: return "运行中"
    case .stopping: return "正在停止…"
    case .failed(let code): return code == 127 ? "未找到 Tart" : "失败（\(code)）"
    }
  }

  public var isRunning: Bool {
    switch self {
    case .starting, .running, .stopping: return true
    case .unknown, .missing, .stopped, .suspended, .failed: return false
    }
  }

  public static func resolved(from info: TartVMInfo?) -> VMState {
    guard let info else { return .missing }
    if info.running { return .running }
    if info.state.caseInsensitiveCompare("suspended") == .orderedSame { return .suspended }
    return .stopped
  }
}

public enum VMNameValidation: Equatable, Sendable {
  case valid
  case empty
  case containsSlash
  case duplicate

  public static func validate(_ name: String, existingNames: [String]) -> VMNameValidation {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty { return .empty }
    if normalized.contains("/") { return .containsSlash }
    if existingNames.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
      return .duplicate
    }
    return .valid
  }
}

public enum VMResourceValidation: Equatable, Sendable {
  case valid
  case invalidCPU
  case invalidMemory
  case invalidDisplay
  case invalidDiskSize

  public static func validate(
    cpu: String,
    memory: String,
    display: String,
    diskSize: String
  ) -> VMResourceValidation {
    if !cpu.isEmpty, UInt16(cpu).map({ $0 > 0 }) != true { return .invalidCPU }
    if !memory.isEmpty, UInt64(memory).map({ $0 > 0 }) != true { return .invalidMemory }
    if !display.isEmpty,
      display.range(of: #"^[1-9][0-9]*x[1-9][0-9]*(pt|px)?$"#, options: .regularExpression)
        == nil
    {
      return .invalidDisplay
    }
    if !diskSize.isEmpty, UInt16(diskSize).map({ $0 > 0 }) != true { return .invalidDiskSize }
    return .valid
  }
}

public enum TartListParser {
  public static func parse(_ data: Data) throws -> [TartVMInfo] {
    let decoder = JSONDecoder()
    if let direct = try? decoder.decode([TartVMInfo].self, from: data) { return direct }

    guard let text = String(data: data, encoding: .utf8),
      let start = text.firstIndex(of: "["),
      let end = text.lastIndex(of: "]"), start <= end,
      let jsonData = String(text[start...end]).data(using: .utf8)
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "Tart list did not return a JSON array"))
    }
    return try decoder.decode([TartVMInfo].self, from: jsonData)
  }
}

public enum VMExitAssessment {
  public static func shouldReportFailure(
    expectedStop: Bool,
    terminationStatus: Int32,
    runtimeDuration: TimeInterval,
    synchronizedState: VMState
  ) -> Bool {
    if expectedStop || terminationStatus == 0 { return false }
    if synchronizedState.isRunning || synchronizedState == .suspended { return false }
    // A VM that ran for a meaningful amount of time was likely closed by the user,
    // stopped externally, or shut down from inside the guest.
    if runtimeDuration >= 5 { return false }
    return true
  }
}

public enum VMListSortKey: String, Sendable {
  case name
  case status
  case disk
  case size
}

public enum VMListProjection {
  public static func make(
    configurations: [VMConfiguration],
    states: [UUID: VMState],
    infoByName: [String: TartVMInfo],
    query: String,
    sortKey: VMListSortKey,
    ascending: Bool
  ) -> [VMConfiguration] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = configurations.filter {
      normalizedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(normalizedQuery)
    }
    result.sort { left, right in
      let comparison: ComparisonResult
      switch sortKey {
      case .status:
        comparison = (states[left.id]?.label ?? "").localizedStandardCompare(
          states[right.id]?.label ?? "")
      case .disk:
        comparison = NSNumber(value: infoByName[left.name]?.disk ?? -1).compare(
          NSNumber(value: infoByName[right.name]?.disk ?? -1))
      case .size:
        comparison = NSNumber(value: infoByName[left.name]?.size ?? -1).compare(
          NSNumber(value: infoByName[right.name]?.size ?? -1))
      case .name:
        comparison = left.name.localizedStandardCompare(right.name)
      }
      if comparison == .orderedSame {
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
      }
      return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
    return result
  }
}
