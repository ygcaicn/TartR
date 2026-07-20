import Foundation

public enum TemporaryFileCleanup {
  @discardableResult
  public static func removeStaleFiles(
    in directory: URL,
    namePrefix: String,
    olderThan age: TimeInterval,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> [URL] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    else { return [] }

    var removed: [URL] = []
    for url in urls where url.lastPathComponent.hasPrefix(namePrefix) {
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true,
        let modifiedAt = values.contentModificationDate,
        now.timeIntervalSince(modifiedAt) >= max(0, age)
      else { continue }
      do {
        try fileManager.removeItem(at: url)
        removed.append(url)
      } catch {
        continue
      }
    }
    return removed
  }
}
