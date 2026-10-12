import Foundation
@main struct AccountLifecycleTests {
 static func main() throws {
  let account=AccountConnection(startImmediately:false)
  let waiting:[String:Any]=["game":"connect","board":[1]+Array(repeating:0,count:41),"move":[0,0,1],"num":"2","kind":"played-turn"]
  account.applyFixture(["type":"game_loaded","game":waiting,"can_play":true,"recipient":"tel:+15555550123","own_player":2])
  precondition(account.canPlayGame && account.gameSample?.num=="2")
  var cells=Array(repeating:0,count:42);cells[0]=1;cells[7]=2
  account.applyFixture(["type":"game_sent","game":["game":"connect","board":cells,"move":[0,1,2],"num":"3"],"can_play":false])
  precondition(!account.canPlayGame && !account.busy && account.gameSample?.num=="3")
  cells[1]=1
  account.applyFixture(["type":"game_received","game":["game":"connect","board":cells,"move":[1,0,1],"num":"4"],"can_play":true])
  precondition(account.canPlayGame && !account.busy)
  account.applyFixture(["type":"game_error","message":"Fixture uncertain delivery"])
  precondition(!account.canPlayGame && !account.busy)
  cells=Array(repeating:0,count:42);cells[0..<4]=[1,1,1,1]
  account.applyFixture(["type":"game_received","game":["game":"connect","board":cells,"move":[3,0,1],"num":"8","finished":true],"can_play":true])
  precondition(account.gameFinished && !account.canPlayGame)
  account.disconnect();precondition(account.gameSample==nil && !account.phoneAuthorized)
  account.send(["action":"receive_game"]);precondition(!account.busy && !account.canPlayGame && account.phase=="error")
  let queued=AccountConnection(startImmediately:false)
  queued.phoneAuthorized=true;queued.fixtureRecipient="tel:+15555550124"
  queued.setGamePollingEnabled(false);queued.beginReceiveFixture()
  precondition(queued.startGame(game:"connect",options:[:],recipient:"tel:+15555550124",invitation:["game":"connect","opaque":"original"]))
  precondition(queued.fixtureCommands.isEmpty)
  precondition(queued.fixtureCancelledReceives.count==1)
  queued.applyFixture(["type":"game_receive_error","failure_stage":"receive_cancelled"])
  precondition(queued.fixtureCommands.count==1 && queued.fixtureCommands[0]["action"] as? String == "start_game")
  precondition(queued.fixtureCommands[0]["recipient"] as? String == "tel:+15555550124")
  precondition((queued.fixtureCommands[0]["native_invitation"] as? [String:String])?["opaque"] == "original")
  queued.applyFixture(["type":"game_wait","game":waiting,"can_play":false])
  precondition(queued.fixtureCommands.count==1)
  queued.applyFixture(["type":"game_sent","game":waiting,"can_play":false])
  queued.beginReceiveFixture()
  precondition(queued.startGame(game:"connect",options:[:],recipient:"tel:+15555550124"))
  precondition(queued.fixtureCancelledReceives.count==2)
  queued.fixtureRecipient="tel:+15555550125"
  queued.applyFixture(["type":"game_wait","game":waiting,"can_play":false])
  precondition(queued.fixtureCommands.count==1 && queued.phase=="game_error")
  queued.disconnect()
  let room=AccountConnection(startImmediately:false)
  room.phoneAuthorized=true;room.fixtureRecipient="tel:+15555550124"
  room.applyFixture(["type":"game_sent","game":["game":"crazy","num":"1","kind":"invitation"],"can_play":false])
  RunLoop.current.run(until:Date().addingTimeInterval(2.2))
  precondition(room.fixtureCommands.isEmpty && !room.busy)
  room.disconnect()
  print("PASS: live room invitations do not start blocking alternating-turn receive polling")
  print("PASS: queued invitation survives background receive; changed recipient cancels before send")
  print("PASS: isolated account events load/play/send/wait/reply/error/finished/disconnect; no helper or account started")
 }
}
