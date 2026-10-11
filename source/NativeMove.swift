import Foundation
struct NativeMove {
    static func validate(fields:[String:String],sample:GameSample,ownPlayer:Int,revision:String?,expectedRevision:String?) throws -> (Int,Int) {
        guard let revision,revision==expectedRevision,fields["game"]=="connect",
              let replay=fields["replay"],let tail=replay.components(separatedBy:"|move:").last else {throw BoardError.invalid("Stale or invalid original turn.")}
        let move=tail.split(separator:",").compactMap{Int($0)}
        guard move.count==3 else {throw BoardError.invalid("Invalid original move.")}
        var board=try Board(sample:sample)
        guard board.nextPlayer==ownPlayer else {throw BoardError.invalid("Not your turn.")}
        let draft=try board.drop(in:move[0])
        guard draft.move==move,draft.replay==replay,let number=Int(sample.num ?? ""),fields["num"]==String(number+1) else {throw BoardError.invalid("Original output differs from the validated board.")}
        return(move[0],number)
    }
}
