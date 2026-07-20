import Darwin
import Foundation

public enum ProcessDeadline {
  /// Waits for a process without allowing it to block a caller forever.
  /// Returns `true` when the process exits before the deadline. On timeout it first
  /// requests cooperative cancellation with SIGINT, then uses SIGKILL as a last resort.
  @discardableResult
  public static func waitForExit(
    _ process: Process,
    timeout: TimeInterval,
    cancellationGrace: TimeInterval = 0.5
  ) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard process.isRunning else {
      process.waitUntilExit()
      return true
    }

    process.interrupt()
    let cancellationDeadline = Date().addingTimeInterval(max(0, cancellationGrace))
    while process.isRunning, Date() < cancellationDeadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    return false
  }
}
