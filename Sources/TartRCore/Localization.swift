import Foundation

public enum TartRLocalization {
  public static func string(_ key: String, _ arguments: CVarArg...) -> String {
    string(key, arguments: arguments)
  }

  public static func string(_ key: String, arguments: [CVarArg]) -> String {
    let format = Bundle.main.localizedString(
      forKey: key,
      value: key,
      table: "Localizable")
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
  }
}
