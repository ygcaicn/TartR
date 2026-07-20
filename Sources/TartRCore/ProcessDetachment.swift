import Foundation

public enum ProcessDetachment {
  /// Releases the parent's monitoring and file handles without signaling the child process.
  /// The child keeps its inherited file descriptors and is re-parented when TartR exits.
  public static func detach(_ process: Process, closing handles: [FileHandle]) {
    process.terminationHandler = nil
    for handle in handles {
      try? handle.synchronize()
      try? handle.close()
    }
  }
}
