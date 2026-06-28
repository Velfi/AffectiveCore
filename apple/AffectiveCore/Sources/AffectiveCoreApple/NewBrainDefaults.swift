import Foundation

enum NewBrainDefaults {
    private struct Payload: Decodable {
        let wants: [String]
        let goals: [String]
    }

    private static let payload: Payload = {
        guard let url = Bundle.module.url(forResource: "new_brain_defaults", withExtension: "json") else {
            fatalError("missing bundled new_brain_defaults.json")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            fatalError("failed to decode new_brain_defaults.json: \(error)")
        }
    }()

    static var wants: String {
        payload.wants.joined(separator: "\n")
    }

    static var goals: String {
        payload.goals.joined(separator: "\n")
    }
}
