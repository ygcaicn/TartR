import Foundation

struct VMConfiguration: Codable {
  let id: UUID
  let name: String
  let autoStart: Bool
}

let names = Array(CommandLine.arguments.dropFirst())
let configurations = names.map { VMConfiguration(id: UUID(), name: $0, autoStart: true) }
let data = try JSONEncoder().encode(configurations) as CFData
let appID = "com.caiyagang.tartr" as CFString
CFPreferencesSetAppValue("vmConfigurations.v2" as CFString, data, appID)
if let selected = configurations.first?.id.uuidString {
  CFPreferencesSetAppValue("selectedVM.v2" as CFString, selected as CFString, appID)
}
guard CFPreferencesAppSynchronize(appID) else { exit(2) }
