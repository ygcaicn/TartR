import Foundation

public struct AppVersion: Comparable, Equatable, Sendable {
  private let components: [Int]

  public init?(_ rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("v") { value.removeFirst() }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    var parsed: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else {
        return nil
      }
      parsed.append(number)
    }
    while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
    components = parsed
  }

  public static func < (left: AppVersion, right: AppVersion) -> Bool {
    let count = max(left.components.count, right.components.count)
    for index in 0..<count {
      let lhs = index < left.components.count ? left.components[index] : 0
      let rhs = index < right.components.count ? right.components[index] : 0
      if lhs != rhs { return lhs < rhs }
    }
    return false
  }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let version: String
  public let minimumSystemVersion: String
  public let downloadURL: String
  public let releaseNotesURL: String
  public let sha256: String
  public let fileSize: UInt64?

  public init(
    schemaVersion: Int,
    version: String,
    minimumSystemVersion: String,
    downloadURL: String,
    releaseNotesURL: String,
    sha256: String,
    fileSize: UInt64? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.version = version
    self.minimumSystemVersion = minimumSystemVersion
    self.downloadURL = downloadURL
    self.releaseNotesURL = releaseNotesURL
    self.sha256 = sha256
    self.fileSize = fileSize
  }
}

public struct ValidatedUpdateManifest: Equatable, Sendable {
  public let version: AppVersion
  public let minimumSystemVersion: AppVersion
  public let downloadURL: URL
  public let releaseNotesURL: URL
  public let sha256: String
  public let fileSize: UInt64?
}

public enum UpdateManifestValidation {
  public static let maximumPackageBytes: UInt64 = 512 * 1_024 * 1_024

  public static func validate(_ manifest: UpdateManifest) -> ValidatedUpdateManifest? {
    guard manifest.schemaVersion == 1,
      let version = AppVersion(manifest.version),
      let minimumSystemVersion = AppVersion(manifest.minimumSystemVersion),
      let downloadURL = SecureURLValidation.parseSecureHTTPS(manifest.downloadURL),
      let releaseNotesURL = SecureURLValidation.parseSecureHTTPS(manifest.releaseNotesURL),
      downloadURL.pathExtension.lowercased() == "dmg",
      manifest.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
      manifest.fileSize.map({ (1...maximumPackageBytes).contains($0) }) ?? true
    else { return nil }
    return ValidatedUpdateManifest(
      version: version,
      minimumSystemVersion: minimumSystemVersion,
      downloadURL: downloadURL,
      releaseNotesURL: releaseNotesURL,
      sha256: manifest.sha256.lowercased(),
      fileSize: manifest.fileSize)
  }
}
