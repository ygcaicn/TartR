import Foundation

public struct BoundedOutputSnapshot: Equatable, Sendable {
  public let data: Data
  public let wasTruncated: Bool

  public init(data: Data, wasTruncated: Bool) {
    self.data = data
    self.wasTruncated = wasTruncated
  }

  public var text: String {
    let value = String(decoding: data, as: UTF8.self)
    return wasTruncated ? "[较早的输出已省略]\n\(value)" : value
  }
}

public final class BoundedProcessOutput: @unchecked Sendable {
  public let pipe = Pipe()

  private let maximumBytes: Int
  private let lock = NSLock()
  private let reachedEOF = DispatchSemaphore(value: 0)
  private var buffer = Data()
  private var wasTruncated = false
  private var didReachEOF = false

  public init(maximumBytes: Int) {
    self.maximumBytes = max(1, maximumBytes)
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        self?.markEOF()
        return
      }
      self?.append(chunk)
    }
  }

  public func attach(to process: Process) {
    process.standardOutput = pipe
    process.standardError = pipe
  }

  public func processDidStart() {
    try? pipe.fileHandleForWriting.close()
  }

  public func finish(timeout: TimeInterval = 2) -> BoundedOutputSnapshot {
    processDidStart()
    if reachedEOF.wait(timeout: .now() + max(0, timeout)) == .timedOut {
      pipe.fileHandleForReading.readabilityHandler = nil
      try? pipe.fileHandleForReading.close()
    }
    return snapshot()
  }

  public func snapshot() -> BoundedOutputSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return BoundedOutputSnapshot(data: buffer, wasTruncated: wasTruncated)
  }

  private func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    if chunk.count >= maximumBytes {
      buffer = Data(chunk.suffix(maximumBytes))
      wasTruncated = true
      return
    }
    let overflow = buffer.count + chunk.count - maximumBytes
    if overflow > 0 {
      buffer.removeFirst(overflow)
      wasTruncated = true
    }
    buffer.append(chunk)
  }

  private func markEOF() {
    lock.lock()
    guard !didReachEOF else {
      lock.unlock()
      return
    }
    didReachEOF = true
    lock.unlock()
    reachedEOF.signal()
  }
}
