import Foundation
import Combine

final class LocalPlay:ObservableObject {
    @Published private(set) var state:[String:Any]=[:]
    @Published private(set) var busy=false
    @Published private(set) var status="Choose a game from the menu."
    @Published private(set) var handoff=false
    private var generation=0
    private var loadAttempted=false
    private let store=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacPigeon/LocalPlay/current.json")
    var ready:Bool {state["revision"] is String}
    var player:Int {state["own_player"] as? Int ?? 1}
    var finished:Bool {state["finished"] as? Bool == true}
    var title:String {state["title"] as? String ?? "Local game"}
    func load(){guard !loadAttempted,!busy,!ready else{return};loadAttempted=true;guard let data=try? Data(contentsOf:store),data.count<=262144,let saved=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return};run(["action":"load","state":saved],pass:false)}
    func start(game:String,options:[String:String],avatar:String,completion:@escaping(Bool)->Void){run(["action":"start","game":game,"options":options,"avatar":avatar],pass:false,completion:completion)}
    func play(fields:[String:String],revision:String,completion:@escaping(Bool)->Void){
        guard ready,!busy,!handoff,!finished else{completion(false);return}
        run(["action":"play","state":state,"fields":fields,"revision":revision],pass:true,completion:completion)
    }
    func continueTurn(revision:String){guard handoff,!finished,revision==state["revision"] as? String,!busy else{return};handoff=false;status="Player \(player)'s turn";persist()}
    func stop(){generation+=1;busy=false}
    private func persist(){
        do{try FileManager.default.createDirectory(at:store.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);var saved=state;saved["local_handoff"]=handoff;let data=try JSONSerialization.data(withJSONObject:saved);try data.write(to:store,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:store.path)}catch{status="This local game could not be saved."}
    }
    private func run(_ request:[String:Any],pass:Bool,completion:((Bool)->Void)?=nil){
        guard !busy,let resources=Bundle.main.resourceURL,let python=GameImporter.python(in:resources),let data=try? JSONSerialization.data(withJSONObject:request) else{completion?(false);return}
        generation+=1;let token=generation;busy=true;status="Loading local game…"
        DispatchQueue.global().async {
            let task=Process(),input=Pipe(),output=Pipe();task.executableURL=python
            task.arguments=["-I","-B","-c","import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[2],run_name='__main__')",resources.path,resources.appendingPathComponent("local_play.py").path]
            task.standardInput=input;task.standardOutput=output;task.standardError=FileHandle.nullDevice
            var result:[String:Any]=[:]
            do{try task.run();input.fileHandleForWriting.write(data);input.fileHandleForWriting.write(Data([10]));try? input.fileHandleForWriting.close();let reply=output.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();if reply.count<=262144 {result=(try? JSONSerialization.jsonObject(with:reply)) as? [String:Any] ?? [:]}}catch{}
            let reply=result
            DispatchQueue.main.async {
                guard token==self.generation else{return}
                self.busy=false
                if reply["ok"] as? Bool == true,let state=reply["state"] as? [String:Any]{
                    self.state=state;self.handoff = (pass || (request["state"] as? [String:Any])?["local_handoff"] as? Bool == true) && !self.finished
                    self.status=self.handoff ? "Pass to Player \(self.player)" : (state["status"] as? String ?? "Local game ready.")
                    self.persist();completion?(true)
                }else{self.status=reply["error"] as? String ?? "Local game could not load. Try again.";completion?(false)}
            }
        }
    }
}
