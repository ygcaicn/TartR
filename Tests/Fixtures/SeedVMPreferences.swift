import Foundation

struct VMConfiguration: Codable {
  let id: UUID
  let name: String
  let autoStart: Bool
}

var arguments = Array(CommandLine.arguments.dropFirst())
var bundleID = "com.caiyagang.tartr"
var autoStart = true
var tartHomePath: String?
if arguments.first == "--bundle-id", arguments.count >= 2 {
  bundleID = arguments[1]
  arguments.removeFirst(2)
}
if arguments.first == "--no-auto-start" {
  autoStart = false
  arguments.removeFirst()
}
if arguments.first == "--tart-home", arguments.count >= 2 {
  tartHomePath = arguments[1]
  arguments.removeFirst(2)
}
let configurations = arguments.map { VMConfiguration(id: UUID(), name: $0, autoStart: autoStart) }
let data = try JSONEncoder().encode(configurations) as CFData
let appID = bundleID as CFString
let namespaceSuffix: String
if let tartHomePath {
  let encoded = Data(tartHomePath.utf8).base64EncodedString()
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "=", with: "")
  namespaceSuffix = ".home.\(encoded)"
  CFPreferencesSetAppValue("tartHomePath.v1" as CFString, tartHomePath as CFString, appID)
} else {
  namespaceSuffix = ""
}
CFPreferencesSetAppValue("vmConfigurations.v2\(namespaceSuffix)" as CFString, data, appID)
if let selected = configurations.first?.id.uuidString {
  CFPreferencesSetAppValue(
    "selectedVM.v2\(namespaceSuffix)" as CFString, selected as CFString, appID)
}
guard CFPreferencesAppSynchronize(appID) else { exit(2) }
