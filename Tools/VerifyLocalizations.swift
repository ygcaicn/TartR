#!/usr/bin/swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceFiles = [
  "Sources/TartR/AppDelegate.swift",
  "Sources/TartRCore/Models.swift",
  "Sources/TartRCore/BoundedProcessOutput.swift",
]
let patterns = [
  #"\blocalized\(\s*\"((?:\\.|[^\"\\])*)\""#,
  #"TartRLocalization\.string\(\s*\"((?:\\.|[^\"\\])*)\""#,
]

func decodeStringLiteral(_ body: String) throws -> String {
  let data = Data("\"\(body)\"".utf8)
  guard
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      as? String
  else {
    throw NSError(domain: "TartRLocalizationVerifier", code: 1)
  }
  return value
}

var expected = Set<String>()
for relativePath in sourceFiles {
  let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  for pattern in patterns {
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)
    for match in expression.matches(in: source, range: range) {
      guard let bodyRange = Range(match.range(at: 1), in: source) else { continue }
      expected.insert(try decodeStringLiteral(String(source[bodyRange])))
    }
  }
}

func loadStrings(_ relativePath: String) throws -> [String: String] {
  let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
  guard
    let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: String]
  else {
    throw NSError(domain: "TartRLocalizationVerifier", code: 2)
  }
  return dictionary
}

let english = try loadStrings("Resources/en.lproj/Localizable.strings")
let chinese = try loadStrings("Resources/zh-Hans.lproj/Localizable.strings")
guard english["__language__"] == "English", chinese["__language__"] == "简体中文" else {
  fatalError("Localization metadata is missing")
}

let translatedKeys = Set(chinese.keys).subtracting(["__language__"])
let missing = expected.subtracting(translatedKeys).sorted()
let obsolete = translatedKeys.subtracting(expected).sorted()
guard missing.isEmpty else { fatalError("Missing zh-Hans keys:\n\(missing.joined(separator: "\n"))") }
guard obsolete.isEmpty else { fatalError("Obsolete zh-Hans keys:\n\(obsolete.joined(separator: "\n"))") }

let formatExpression = try NSRegularExpression(pattern: #"%(?:@|d|%)"#)
func formatTokens(_ value: String) -> [String] {
  let range = NSRange(value.startIndex..., in: value)
  return formatExpression.matches(in: value, range: range).compactMap {
    Range($0.range, in: value).map { String(value[$0]) }
  }.filter { $0 != "%%" }
}

for key in expected.sorted() {
  guard let translation = chinese[key], formatTokens(key) == formatTokens(translation) else {
    fatalError("Format placeholders do not match for key: \(key)")
  }
}

print("Verified \(expected.count) localized strings for en and zh-Hans.")
