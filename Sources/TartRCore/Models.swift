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

public struct VMConfiguration: Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var autoStart: Bool

  public init(id: UUID = UUID(), name: String, autoStart: Bool = false) {
    self.id = id
    self.name = name
    self.autoStart = autoStart
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
