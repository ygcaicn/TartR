import Foundation

public enum TartVersionValidation {
  public static func isPlausible(_ output: String) -> Bool {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 256 else { return false }
    return value.range(
      of: #"(?i)^(tart\s+)?v?[0-9]+\.[0-9]+(\.[0-9]+)?([+-][0-9a-z.-]+)?$"#,
      options: .regularExpression) != nil
  }
}
