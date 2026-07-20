import Foundation

public enum SecureURLValidation {
  public static func isSecureHTTPS(_ url: URL?) -> Bool {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil
    else { return false }
    return true
  }

  public static func parseSecureHTTPS(_ value: String) -> URL? {
    guard let url = URL(string: value), isSecureHTTPS(url) else { return nil }
    return url
  }
}
