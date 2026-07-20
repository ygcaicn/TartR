import Foundation

struct VMConfiguration: Codable {
  let id: UUID
  let name: String
  let autoStart: Bool
}

var arguments = Array(CommandLine.arguments.dropFirst())
var bundleID = "com.caiyagang.tartr"
var autoStart = true
if arguments.first == "--bundle-id", arguments.count >= 2 {
  bundleID = arguments[1]
  arguments.removeFirst(2)
}
if arguments.first == "--no-auto-start" {
  autoStart = false
  arguments.removeFirst()
}
let configurations = arguments.map { VMConfiguration(id: UUID(), name: $0, autoStart: autoStart) }
let data = try JSONEncoder().encode(configurations) as CFData
let appID = bundleID as CFString
CFPreferencesSetAppValue("vmConfigurations.v2" as CFString, data, appID)
if let selected = configurations.first?.id.uuidString {
  CFPreferencesSetAppValue("selectedVM.v2" as CFString, selected as CFString, appID)
}
guard CFPreferencesAppSynchronize(appID) else { exit(2) }
