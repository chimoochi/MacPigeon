import AppKit
import Combine

struct ImportChoice:Identifiable,Decodable {
    let id:String
    let date:String
    let outgoing:Bool
    let known_session:Bool
    var label:String {
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let instant=parser.date(from:date) ?? ISO8601DateFormatter().date(from:date)
        return (known_session ? "Current game · " : "")+(instant.map{DateFormatter.localizedString(from:$0,dateStyle:.medium,timeStyle:.medium)} ?? date)+(outgoing ? " · You sent" : " · Received")
    }
}
struct SavedGame:Identifiable,Decodable {let id:String;let num:Int;let finished:Bool;let can_play:Bool}
final class GameImporter:ObservableObject {
    static func python(in resources:URL)->URL? {
        guard let runtime=try? String(contentsOf:resources.appendingPathComponent("python-runtime-path.txt"),encoding:.utf8) else{return nil}
        let value=runtime.trimmingCharacters(in:.whitespacesAndNewlines)
        return value=="@bundled" ? resources.appendingPathComponent("python-runtime") : URL(fileURLWithPath:value)
    }
    @Published var presented=false
    @Published var busy=false
    @Published var choices:[ImportChoice]=[]
    @Published var saved:[SavedGame]=[]
    @Published var status=""
    private(set) var recipient=""
    private var token=""
    var openCurrent:(()->Bool)?
    var autoSelect:((ImportChoice)->Void)?
    var imported:(()->Void)?
    func request(recipient:String,guid:String?=nil,preferCurrent:Bool=false,latest:Bool=false){
        guard !busy else{return};self.recipient=recipient;choices=[];saved=[];token="";presented=true;status="Finding game bubbles…"
        var request:[String:Any]=["action":"list","recipient":recipient,"prefer_current":preferCurrent,"latest":latest]
        if let guid {request["guid"]=guid}
        run(request){[weak self] result in
            guard let self else{return}
            if result["ok"] as? Bool == true,let data=try? JSONSerialization.data(withJSONObject:result["choices"] ?? []){
                self.token=result["token"] as? String ?? "";self.choices=(try? JSONDecoder().decode([ImportChoice].self,from:data)) ?? []
                if result["automatic"] as? Bool == true,let choice=self.choices.first {
                    if preferCurrent && choice.known_session && self.openCurrent?() == true {
                        self.presented=false;return
                    }
                    self.choices=[];self.status="Opening your game…";self.autoSelect?(choice);return
                }
                self.status=self.choices.isEmpty ? "No supported game bubbles found in this conversation." : "This bubble could not identify one game. Open the newest bubble from your current game."
                self.run(["action":"saved","recipient":recipient]){result in if let data=try? JSONSerialization.data(withJSONObject:result["saved"] ?? []){self.saved=(try? JSONDecoder().decode([SavedGame].self,from:data)) ?? []}}
            }else if guid != nil {
                // A focused accessibility identifier may be a game UUID rather than a message GUID.
                // Require an explicit choice instead of assuming the newest message.
                self.request(recipient:recipient,preferCurrent:preferCurrent,latest:latest)
            }else{self.status=Self.error(result)}
        }
    }
    func select(_ choice:ImportChoice){
        guard !busy,(try? MessagesContext.currentHandle())==recipient else{status="Return to the same Messages conversation.";return}
        status="Loading this game’s latest progress…"
        run(["action":"select","recipient":recipient,"token":token,"choice":choice.id]){[weak self] result in
            guard let self else{return}
            if result["ok"] as? Bool == true {self.presented=false;self.status="Game loaded.";self.imported?()}
            else {self.status=Self.error(result)}
        }
    }
    func resume(_ game:SavedGame){
        guard !busy,(try? MessagesContext.currentHandle())==recipient else{status="Return to the same Messages conversation.";return}
        run(["action":"resume","recipient":recipient,"choice":game.id]){[weak self] result in
            guard let self else{return};if result["ok"] as? Bool == true{self.presented=false;self.imported?()}else{self.status=Self.error(result)}
        }
    }
    private static func error(_ result:[String:Any])->String {
        switch result["error"] as? String {
        case "messages_access_required":return "Enable Full Disk Access for MacPigeon, then try again."
        case "own_reference_required":return "This game needs a turn you sent from the same account before it can be resumed."
        case "selection_expired":return "The selection expired. Click Check again."
        case "game":return "Choose a supported game from the Games menu."
        case "pool_variant":return "Choose a pool game and its options from the Games menu."
        case "turn_gap","history_limit":return "Some game history is missing. Let Messages finish syncing, then choose the newest bubble."
        default:return "This selection could not be verified. Your saved game has not been replaced."
        }
    }
    private func run(_ request:[String:Any],completion:@escaping([String:Any])->Void){
        busy=true
        DispatchQueue.global().async {
            let task=Process(),input=Pipe(),output=Pipe();var result:[String:Any]=[:]
            if let resources=Bundle.main.resourceURL,let runtime=Self.python(in:resources){
                task.executableURL=runtime;task.arguments=["-I","-B","-c","import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[2],run_name='__main__')",resources.path,resources.appendingPathComponent("import_mac_game.py").path]
                task.standardInput=input;task.standardOutput=output;task.standardError=FileHandle.nullDevice
                do{try task.run();if let data=try? JSONSerialization.data(withJSONObject:request){input.fileHandleForWriting.write(data);input.fileHandleForWriting.write(Data([10]))};try? input.fileHandleForWriting.close();let data=output.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();if task.terminationStatus==0,data.count<65536 {result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}}catch{}
            }
            DispatchQueue.main.async{self.busy=false;completion(result)}
        }
    }
}
