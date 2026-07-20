import Foundation

public struct VMSelectionCapabilities: Equatable, Sendable {
  public let selectionCount: Int
  public let startableIDs: [UUID]
  public let stoppableIDs: [UUID]
  public let canRemoveRecords: Bool

  public var hasSingleSelection: Bool { selectionCount == 1 }

  public static func resolve(
    configurations: [VMConfiguration],
    states: [UUID: VMState],
    discoveredNames: Set<String>
  ) -> VMSelectionCapabilities {
    let startableIDs = configurations.compactMap { configuration -> UUID? in
      switch states[configuration.id] ?? .unknown {
      case .stopped, .suspended, .failed:
        return configuration.id
      case .unknown, .missing, .starting, .running, .stopping:
        return nil
      }
    }
    let stoppableIDs = configurations.compactMap { configuration -> UUID? in
      switch states[configuration.id] ?? .unknown {
      case .starting, .running:
        return configuration.id
      case .unknown, .missing, .stopped, .suspended, .stopping, .failed:
        return nil
      }
    }
    let canRemoveRecords =
      !configurations.isEmpty
      && configurations.allSatisfy { configuration in
        !discoveredNames.contains(configuration.name)
          && states[configuration.id]?.isRunning != true
      }
    return VMSelectionCapabilities(
      selectionCount: configurations.count,
      startableIDs: startableIDs,
      stoppableIDs: stoppableIDs,
      canRemoveRecords: canRemoveRecords)
  }
}
