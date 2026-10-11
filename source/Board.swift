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

struct MoveDraft: Encodable {
    let game = "connect"
    let kind = "offline-move-candidate"
    let replay: String
    let board: [Int]
    let move: [Int]
    let num: String?
    let size = "4"
    let validation = "Offline candidate; session, identities and transport unverified"
}

struct Board {
    var cells = Array(repeating: 0, count: 42)
    var avatars: [String:String] = [:]
    var nextPlayer = 1
    var lastMove: [Int]?
    var number: Int?
    var winner: Int? {
        for y in 0..<6 { for x in 0..<7 {
            let p = cells[y * 7 + x]
            if p == 0 { continue }
            for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                let ex = x + 3 * dx, ey = y + 3 * dy
                guard (0..<7).contains(ex), (0..<6).contains(ey) else { continue }
                if (1...3).allSatisfy({ cells[(y + $0 * dy) * 7 + x + $0 * dx] == p }) { return p }
            }
        }}
        return nil
    }
    var finished: Bool { winner != nil || !cells.contains(0) }
    func row(for column: Int) -> Int? {
        guard (0..<7).contains(column) else { return nil }
        return (0..<6).first { cells[$0 * 7 + column] == 0 }
    }
    mutating func drop(in column: Int) throws -> MoveDraft {
        guard !finished else { throw BoardError.invalid("This board is finished.") }
        guard let y = row(for: column) else { throw BoardError.invalid("That column is full.") }
        let prior = cells
        let move = [column, y, nextPlayer]
        let replay = "board:" + prior.map(String.init).joined(separator: ",") + "|move:" + move.map(String.init).joined(separator: ",")
        cells[y * 7 + column] = nextPlayer
        lastMove = move
        nextPlayer = 3 - nextPlayer
        number = number.map { $0 + 1 }
        return MoveDraft(replay: replay, board: cells, move: move, num: number.map(String.init))
    }
    init() {}
    init(sample: GameSample) throws {
        guard sample.game == "connect" else { throw BoardError.invalid("Choose a Four in a Row sample.") }
        guard let board = sample.board else { throw BoardError.invalid("This is an invitation with no played turn.") }
        guard board.count == 42, board.allSatisfy({ (0...2).contains($0) }) else { throw BoardError.invalid("Invalid board cells.") }
        for x in 0..<7 {
            var empty = false
            for y in 0..<6 {
                if board[y * 7 + x] == 0 { empty = true }
                else if empty { throw BoardError.invalid("Board contains a floating disc.") }
            }
        }
        guard let move = sample.move, move.count == 3,
              (0..<7).contains(move[0]), (0..<6).contains(move[1]), (1...2).contains(move[2]),
              board[move[1] * 7 + move[0]] == move[2] else { throw BoardError.invalid("Missing or inconsistent latest move.") }
        guard move[1] == 5 || board[(move[1] + 1) * 7 + move[0]] == 0 else { throw BoardError.invalid("Latest move is buried under another disc.") }
        avatars = sample.avatars ?? [:]
        cells = board
        nextPlayer = 3 - move[2]
        lastMove = move
        number = sample.num.flatMap(Int.init)
    }
}
