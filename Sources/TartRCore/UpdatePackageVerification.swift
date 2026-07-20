import CryptoKit
import Foundation

public enum UpdatePackageVerificationResult: Equatable, Sendable {
  case valid(size: UInt64)
  case unreadable
  case tooLarge(actual: UInt64, maximum: UInt64)
  case sizeMismatch(expected: UInt64, actual: UInt64)
  case checksumMismatch(actual: String)
}

public enum UpdatePackageVerification {
  public static func verify(
    fileURL: URL,
    expectedSize: UInt64,
    expectedSHA256: String,
    maximumBytes: UInt64 = UpdateManifestValidation.maximumPackageBytes,
    fileManager: FileManager = .default
  ) -> UpdatePackageVerificationResult {
    guard expectedSize > 0, expectedSize <= maximumBytes,
      expectedSHA256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
      let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
      let number = attributes[.size] as? NSNumber
    else { return .unreadable }

    let actualSize = number.uint64Value
    guard actualSize <= maximumBytes else {
      return .tooLarge(actual: actualSize, maximum: maximumBytes)
    }
    guard actualSize == expectedSize else {
      return .sizeMismatch(expected: expectedSize, actual: actualSize)
    }
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unreadable }
    defer { try? handle.close() }

    var hasher = SHA256()
    do {
      while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
        hasher.update(data: data)
      }
    } catch {
      return .unreadable
    }
    let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard actualHash.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
      return .checksumMismatch(actual: actualHash)
    }
    return .valid(size: actualSize)
  }
}
