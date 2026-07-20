import Foundation

public enum StorageCapacityAssessment: Equatable, Sendable {
  case sufficient(availableBytes: UInt64, requiredBytes: UInt64)
  case insufficient(availableBytes: UInt64, requiredBytes: UInt64)
  case unavailable
}

public enum StorageCapacityPreflight {
  public static let defaultReserveBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024

  public static func assess(
    availableBytes: Int64?,
    operationBytes: UInt64,
    reserveBytes: UInt64 = defaultReserveBytes
  ) -> StorageCapacityAssessment {
    guard let availableBytes, availableBytes >= 0 else { return .unavailable }
    let (requiredBytes, overflow) = operationBytes.addingReportingOverflow(reserveBytes)
    let required = overflow ? UInt64.max : requiredBytes
    let available = UInt64(availableBytes)
    if available >= required {
      return .sufficient(availableBytes: available, requiredBytes: required)
    }
    return .insufficient(availableBytes: available, requiredBytes: required)
  }
}
