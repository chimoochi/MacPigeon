import Foundation

enum GameCatalog {
    static let titles:[String:String] = {
        guard let resources=Bundle.main.resourceURL,
              let data=try? Data(contentsOf:resources.appendingPathComponent("RendererHostTemplate.app/Contents/Resources/macpigeon-game-registry.json")),
              let registry=(try? JSONSerialization.jsonObject(with:data)) as? [String:[String:String]] else{return ["connect":"Four in a Row","pool":"8 Ball","chess":"Chess","golf":"Mini Golf"]}
        return registry.compactMapValues{$0["title"]}
    }()
}

enum BoardError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

struct GameSample: Codable {
    let game: String
    let board: [Int]?
    let move: [Int]?
    let num: String?
    let kind: String?
    var avatars: [String:String]? = nil
    var finished: Bool? = nil
    var title:String { GameCatalog.titles[game] ?? "Game" }
}

