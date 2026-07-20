import Foundation

public struct ImageCatalogItem: Equatable, Sendable {
  public let os: String
  public let kind: String
  public let source: String
  public let suggestedName: String

  public init(os: String, kind: String, source: String, suggestedName: String) {
    self.os = os
    self.kind = kind
    self.source = source
    self.suggestedName = suggestedName
  }
}

public let officialImageCatalog: [ImageCatalogItem] = [
  ("macOS 26 Tahoe", "Vanilla", "macos-tahoe-vanilla", "tahoe-vanilla"),
  ("macOS 26 Tahoe", "Base", "macos-tahoe-base", "tahoe-base"),
  ("macOS 26 Tahoe", "Xcode", "macos-tahoe-xcode", "tahoe-xcode"),
  ("macOS 15 Sequoia", "Vanilla", "macos-sequoia-vanilla", "sequoia-vanilla"),
  ("macOS 15 Sequoia", "Base", "macos-sequoia-base", "sequoia-base"),
  ("macOS 15 Sequoia", "Xcode", "macos-sequoia-xcode", "sequoia-xcode"),
  ("macOS 14 Sonoma", "Vanilla", "macos-sonoma-vanilla", "sonoma-vanilla"),
  ("macOS 14 Sonoma", "Base", "macos-sonoma-base", "sonoma-base"),
  ("macOS 14 Sonoma", "Xcode", "macos-sonoma-xcode", "sonoma-xcode"),
  ("macOS 13 Ventura", "Vanilla", "macos-ventura-vanilla", "ventura-vanilla"),
  ("macOS 13 Ventura", "Base", "macos-ventura-base", "ventura-base"),
  ("macOS 13 Ventura", "Xcode", "macos-ventura-xcode", "ventura-xcode"),
  ("macOS 12 Monterey", "Vanilla", "macos-monterey-vanilla", "monterey-vanilla"),
  ("macOS 12 Monterey", "Base", "macos-monterey-base", "monterey-base"),
  ("macOS 12 Monterey", "Xcode", "macos-monterey-xcode", "monterey-xcode"),
].map {
  ImageCatalogItem(
    os: $0.0, kind: $0.1,
    source: "ghcr.io/cirruslabs/\($0.2):latest", suggestedName: $0.3)
}
