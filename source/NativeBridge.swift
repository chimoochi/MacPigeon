import AppKit
import SwiftUI
import Combine

final class NativeTransport: ObservableObject {
    let account = AccountConnection(startImmediately:false)
    let importer=GameImporter()
    let runtime=GameRuntime()
    let local=LocalPlay()
    @Published private(set) var localMode=UserDefaults.standard.bool(forKey:"localPlayMode")
    private var localObserver:AnyCancellable?
    private var openLocalAfterStart=false
    @Published var fullDiskAccessGranted = false
    @Published var diskCheckFailed = false
    @Published var diskFeedback = ""
    var setupStep:SetupStep {return SetupStep.required(account:account.phoneAuthorized && !disconnected,messages:permissionGranted,disk:fullDiskAccessGranted,game:runtime.ready,local:localMode)}
    @Published var permissionGranted = false
    @Published var checkingPermission = false
    @Published var permissionCheckFailed = false
    @Published var permissionFeedback = ""
    @Published var currentRecipient:String?
    @Published var opponentDisplay = ""
    @Published var chatMatched = false
    @Published var disconnected = false
    @Published var messagesSyncNeedsAccess = false
    @Published var gameSyncReady = false
    @Published var gameSyncFailed = false
    @Published var pendingNewGame:String?
    @Published var verifyLastConversation = false
    private var pendingNewConversationName:String?
    private var pendingNewOptions:[String:String]=[:]
    private var pendingNewInvitation:[String:String]?
    private var invitationSending=false
    private var pendingNewRecipient:String?
    private var pendingNewName=""
    private var pendingNewID:String?
    private var accountStarted = false
    private var accountObserver: AnyCancellable?
    private var importObserver: AnyCancellable?
    private var runtimeObserver: AnyCancellable?
    private var pendingImport:ImportChoice?
    private var pendingResume:SavedGame?
    private var openAfterImport=false
    private let bubbleOpener = GameBubbleOpener()
    @Published var status = "Connecting…"
    private var timer: Timer?
    private var menuRequestID:String?
    private var consumed = Set<String>()
    private var pendingNativeRequest:[String:Any]?
    private var exporterRunning = false
    private var state: [String:Any] = [:]
    private var connectionID=UUID().uuidString
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/local.macpigeon.native.renderer/Data/Library/Application Support")
    init() {
        if let data=try? Data(contentsOf:directory.appendingPathComponent("native-menu-request.json")),data.count<262144 {menuRequestID=((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["id"] as? String}
        localObserver=local.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.objectWillChange.send()} }
        runtimeObserver=runtime.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.objectWillChange.send()} }
        if CommandLine.arguments.contains("--ui-preview") || Bundle.main.object(forInfoDictionaryKey:"OfflineUIPreview") as? Bool == true {
            let step=Bundle.main.object(forInfoDictionaryKey:"SetupPreviewStep") as? Int ?? 0
            account.phoneAuthorized=step>0;permissionGranted=step>1;fullDiskAccessGranted=step>2
            return // Isolated UI preview: no helper, timer, database check, or transport.
        }
        bubbleOpener.showGame = { [weak self] in self?.tick(); self?.openBoard() }
        bubbleOpener.importGame = { [weak self] recipient,guid in guard let self,!self.localMode else{return};self.importer.request(recipient:recipient,guid:guid,preferCurrent:true) }
        importer.openCurrent = { [weak self] in
            guard let self,!self.localMode,self.gameSyncReady,self.chatMatched,self.runtime.ready,self.account.phoneAuthorized,
                  self.state["recipient"] as? String == self.account.gameRecipient else{return false}
            self.openBoard();return true
        }
        importer.autoSelect = { [weak self] choice in self?.selectGame(choice) }
        importer.imported = { [weak self] in guard let self,!self.localMode else{return};self.state=[:];self.gameSyncReady=false;self.openAfterImport=true;self.account.loadGame() }
        accountObserver=account.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.objectWillChange.send()} }
        importObserver=importer.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.objectWillChange.send()} }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func setLocalMode(_ enabled:Bool){
        guard enabled != localMode else{return}
        localMode=enabled;UserDefaults.standard.set(enabled,forKey:"localPlayMode")
        connectionID=UUID().uuidString;cancelNewGame();invitationSending=false;pendingNativeRequest=nil;pendingImport=nil;pendingResume=nil;importer.presented=false;openAfterImport=false
        if let data=try? Data(contentsOf:directory.appendingPathComponent("native-menu-request.json")),data.count<262144 {menuRequestID=((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["id"] as? String}
        account.setGamePollingEnabled(false);bubbleOpener.enabled=false
        if enabled {account.disconnect();accountStarted=false;local.load()}
        else {local.stop();disconnected=false;state=[:];gameSyncReady=false}
        tick()
    }
    func openLocalGame(){guard localMode,local.ready,setupStep == .ready,let app=runtime.appURL else{return};write(["id":UUID().uuidString,"view":"board"],name:"native-view.json");NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration()){_,_ in}}
    func connect() { guard !localMode else{return};disconnected=false; if !accountStarted {accountStarted=true;account.start()} else if !account.busy && !["login","code","sms_choice"].contains(account.phase) {account.connectDelivery()} }
    func disconnect() {disconnected=true;accountStarted=false;invitationSending=false;openAfterImport=false;cancelNewGame();account.disconnect();state=[:];tick()}
    func openCurrentChatGame(){
        guard !localMode,setupStep == .ready else{return}
        guard let recipient=try? MessagesContext.currentHandle() else{
            verifyLastConversation=true;return
        }
        importer.request(recipient:recipient,latest:true)
    }
    func importOpenChat(){guard !localMode else{return};guard let recipient=try? MessagesContext.currentHandle() else{status="Verify the open conversation first.";return};importer.request(recipient:recipient)}
    func selectGame(_ choice:ImportChoice){guard !localMode else{return};pendingImport=choice;importer.status="Waiting for the current connection check to finish…";tick()}
    func resumeGame(_ game:SavedGame){guard !localMode else{return};pendingResume=game;importer.status="Waiting for the current connection check to finish…";tick()}
    func cancelImport(){pendingImport=nil;pendingResume=nil;importer.presented=false}
    func cancelNewGame(){pendingNewGame=nil;pendingNewOptions=[:];pendingNewInvitation=nil;pendingNewRecipient=nil;pendingNewConversationName=nil;pendingNewID=nil;write([:],name:"native-invitation-prompt.json")}
    func confirmNewGame(){
        guard !localMode,setupStep == .ready else{cancelNewGame();return}
        guard let game=pendingNewGame,let recipient=pendingNewRecipient else{return}
        let options=pendingNewOptions;let invitation=pendingNewInvitation;cancelNewGame()
        if account.startGame(game:game,options:options,recipient:recipient,invitation:invitation){
            state=[:];gameSyncReady=false;openAfterImport=true;invitationSending=true
            write(["id":UUID().uuidString,"connection_id":connectionID,"title":"Sending invitation","notice":account.gameStatus,"expires_at":Date().timeIntervalSince1970+120],name:"native-invitation-prompt.json")
        }
        else{write(["id":UUID().uuidString,"connection_id":connectionID,"error":"Return to the verified Messages conversation, then try again.","expires_at":Date().timeIntervalSince1970+15],name:"native-invitation-prompt.json")}
    }
    var newGameTitle:String { GameCatalog.titles[pendingNewGame ?? ""] ?? "Game" }
    var newGameTarget:String {pendingNewName}
    func checkPermission() {
        guard !checkingPermission else{return}
        checkingPermission=true;permissionFeedback="Checking Messages access…";permissionCheckFailed=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
            guard let self else{return};self.tick();self.checkingPermission=false
            self.permissionCheckFailed = !self.permissionGranted
            self.permissionFeedback = self.permissionGranted ? "Messages access confirmed." : "Access is still disabled."
        }
    }
    func checkDiskAccess() {
        let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        // Open and close only: check the OS grant without reading message contents.
        if let handle=try? FileHandle(forReadingFrom:url) {try? handle.close();fullDiskAccessGranted=true}
        else {fullDiskAccessGranted=false}
    }
    func recheckDiskAccess(){checkDiskAccess();diskCheckFailed = !fullDiskAccessGranted;diskFeedback=fullDiskAccessGranted ? "Access confirmed." : "Access is still disabled."}
    func openDiskSettings(){if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"){NSWorkspace.shared.open(url)}}
    func openMenu(){
        guard setupStep == .ready else{return}
        guard let app=runtime.appURL else{return}
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        write(["id":UUID().uuidString,"view":"menu"],name:"native-view.json")
        NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration()){_,_ in}
    }
    func openBoard(requireMatchedChat:Bool=true) {
        guard !localMode,setupStep == .ready,account.phoneAuthorized,account.gameSample != nil,gameSyncReady,state["recipient"] as? String == account.gameRecipient,
              let recipient=account.gameRecipient else{return}
        if requireMatchedChat && (try? MessagesContext.currentHandle()) != recipient {return}
        guard let app = runtime.appURL else { return }
        write(["id":UUID().uuidString,"view":"board"],name:"native-view.json")
        NSWorkspace.shared.openApplication(at:app,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
    func exportDiagnostics() {
        let panel=NSSavePanel();panel.title="Save diagnostics";panel.nameFieldStringValue="MacPigeon-diagnostics.json"
        guard panel.runModal() == .OK,let destination=panel.url else{return}
        let report:[String:Any]=[
            "format":1,"app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
            "macos":ProcessInfo.processInfo.operatingSystemVersionString,
            "messages_access":permissionGranted,"conversation_matched":chatMatched,
            "messages_sync_needs_access":messagesSyncNeedsAccess,"game_sync_ready":gameSyncReady,
            "game_sync_failed":gameSyncFailed,"account_connected":account.phoneAuthorized,
            "connection_busy":account.busy,"game_loaded":account.gameSample != nil,
            "game_finished":account.gameFinished,"can_play":account.canPlayGame,
            "runtime_ready":runtime.ready,"contains_credentials":false,"contains_message_contents":false]
        do {let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:destination,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)}
        catch {status="Diagnostics could not be saved. Choose a writable folder."}
    }
    func write(_ object:[String:Any], name:String) {
        guard FileManager.default.fileExists(atPath:directory.path),let data=try? JSONSerialization.data(withJSONObject:object) else {return}
        let url=directory.appendingPathComponent(name)
        try? data.write(to:url,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func tick() {
        runtime.prepareInstalledHost()
        if localMode {tickLocal();return}
        if invitationSending && !account.busy && ["game_sent","game_error","error"].contains(account.phase) {
            invitationSending=false
            var result:[String:Any]=["id":UUID().uuidString,"connection_id":connectionID,"title":"Invitation status","notice":account.gameStatus,"expires_at":Date().timeIntervalSince1970+30]
            if account.phase != "game_sent" {openAfterImport=false;result["error"]=account.phase == "error" ? account.status : account.gameStatus;result.removeValue(forKey:"notice")}
            write(result,name:"native-invitation-prompt.json")
        }
        permissionGranted=MessagesContext.allowed
        checkDiskAccess()
        if !accountStarted && !disconnected {connect()}
        if setupStep != .ready && pendingNewGame != nil {cancelNewGame()}
        let openRecipient=try? MessagesContext.currentHandle()
        currentRecipient=openRecipient
        let matched=account.gameRecipient != nil && openRecipient == account.gameRecipient
        chatMatched=matched
        account.setGamePollingEnabled(setupStep == .ready && matched && pendingNewGame==nil)
        if let recipient=openRecipient {
            let rawName=MessagesContext.conversationName() ?? ""
            let address=String(recipient.dropFirst(recipient.hasPrefix("tel:") ? 4 : 7))
            opponentDisplay=rawName.isEmpty || rawName=="Messages" || MessagesContext.address(in:rawName) != nil ? address : rawName
        }else{opponentDisplay=""}
        if openAfterImport && !account.busy && gameSyncReady && state["recipient"] as? String == account.gameRecipient {openAfterImport=false;openBoard()}
        bubbleOpener.expectedRecipient = account.phoneAuthorized && account.gameSample != nil && !disconnected ? account.gameRecipient : nil
        bubbleOpener.enabled = setupStep == .ready
        if let choice=pendingImport,setupStep == .ready,!account.busy,!exporterRunning,!importer.busy {pendingImport=nil;account.canPlayGame=false;importer.select(choice)}
        if let game=pendingResume,setupStep == .ready,!account.busy,!exporterRunning,!importer.busy {pendingResume=nil;account.canPlayGame=false;importer.resume(game)}
        status = !MessagesContext.allowed ? "Enable Messages access for MacPigeon." : (!matched ? "Open the matching Messages conversation." : (!gameSyncReady ? (messagesSyncNeedsAccess ? "Allow Full Disk Access to sync this game." : (gameSyncFailed ? "Game progress could not be verified." : "Checking game progress…")) : account.status))
        var output=state
        output["can_play"]=setupStep == .ready && matched && gameSyncReady && (account.canPlayGame || state["realtime"] as? Bool == true) && account.phoneAuthorized && !account.busy && !importer.busy && pendingImport==nil && pendingResume==nil && state["finished"] as? Bool != true
        if state["finished"] as? Bool == true {output["status"]="Game finished."}
        output["status"]=status
        output["connection_id"]=connectionID
        output["expires_at"]=Date().timeIntervalSince1970+3
        write(output,name:"native-state.json")
        let menuURL=directory.appendingPathComponent("native-menu-request.json")
        if let data=try? Data(contentsOf:menuURL),data.count<262144,let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=request["id"] as? String,id != menuRequestID {
            menuRequestID=id
            if let game=request["game"] as? String,GameCatalog.titles[game] != nil,setupStep == .ready,account.phoneAuthorized,!importer.busy,(!account.busy || account.receivingGame),let name=MessagesContext.conversationName(),!name.isEmpty {
                pendingNewGame=game;pendingNewOptions=request["options"] as? [String:String] ?? [:];pendingNewInvitation=request["invitation"] as? [String:String];pendingNewRecipient=currentRecipient;pendingNewConversationName=currentRecipient == nil ? name : nil;pendingNewName=currentRecipient == nil ? name : opponentDisplay;pendingNewID=UUID().uuidString
            }else{write(["id":UUID().uuidString,"connection_id":connectionID,"error":"Connect your account and verify the open Messages conversation first.","expires_at":Date().timeIntervalSince1970+15],name:"native-invitation-prompt.json")}
        }
        if let id=pendingNewID {
            if pendingNewConversationName != nil ? MessagesContext.conversationName() != pendingNewConversationName : currentRecipient != pendingNewRecipient {cancelNewGame()}
            else {
                write(["id":id,"connection_id":connectionID,"title":"Start \(newGameTitle)?","target":pendingNewName,"requires_phone":pendingNewConversationName != nil,"expires_at":Date().timeIntervalSince1970+3],name:"native-invitation-prompt.json")
                let responseURL=directory.appendingPathComponent("native-invitation-response.json")
                if let data=try? Data(contentsOf:responseURL),data.count<4096,let response=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],response["id"] as? String == id,response["connection_id"] as? String == connectionID {
                    if response["action"] as? String == "send" {
                        if let name=pendingNewConversationName {
                            guard let address=response["address"] as? String,let recipient=MessagesContext.canonicalHandle(address),recipient.hasPrefix("tel:") else{pendingNewID=UUID().uuidString;return}
                            do {try MessagesContext.verifyNamedConversation(name:name,address:address);pendingNewRecipient=recipient;pendingNewConversationName=nil}
                            catch {cancelNewGame();return}
                        }
                        confirmNewGame()
                    }else{cancelNewGame()}
                }
            }
        }
        consumeRequest(matched:matched)
        guard setupStep == .ready,account.gameSample != nil,!exporterRunning,!importer.busy,pendingImport==nil,pendingResume==nil else{return}
        exporterRunning=true
        let syncAllowed = !account.busy
        DispatchQueue.global().async { [weak self] in
            guard let self else{return}
            let task=Process(), pipe=Pipe()
            task.executableURL=GameImporter.python(in:Bundle.main.resourceURL!)
            task.arguments=["-B",Bundle.main.resourceURL!.appendingPathComponent("export_native_state.py").path] + (syncAllowed ? ["--sync"] : [])
            task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
            var value:[String:Any]=[:]
            do {try task.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();if task.terminationStatus==0,data.count<262144 {value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}}catch{}
            DispatchQueue.main.async {
                guard !self.localMode else{self.exporterRunning=false;return}
                if value["sync_status"] as? String != "deferred" {
                    self.messagesSyncNeedsAccess = value["sync_status"] as? String == "messages_access_required"
                    self.gameSyncFailed = ["validation_failed","history_limit"].contains(value["sync_status"] as? String ?? "")
                    self.gameSyncReady = ["current", "updated", "not_authorized"].contains(value["sync_status"] as? String ?? "")
                }
                if let num=value["num"] as? Int {
                    if String(num)==self.account.gameSample?.num {self.state=value}
                    else if !self.account.busy {self.state=value;self.account.loadGame()}
                }
                self.exporterRunning=false
            }
        }
    }
    private func tickLocal(){
        bubbleOpener.enabled=false;account.setGamePollingEnabled(false)
        currentRecipient=nil;chatMatched=false;opponentDisplay="";local.load()
        var output=local.state
        output["mode"]="local";output["local_handoff"]=local.handoff
        output["can_play"]=setupStep == .ready && local.ready && !local.busy && !local.handoff && !local.finished
        output["status"]=local.status;output["connection_id"]=connectionID;output["expires_at"]=Date().timeIntervalSince1970+3
        write(output,name:"native-state.json");status=local.status
        if openLocalAfterStart && local.ready && !local.busy {openLocalAfterStart=false;openLocalGame()}
        if let data=try? Data(contentsOf:directory.appendingPathComponent("native-menu-request.json")),data.count<262144,let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=request["id"] as? String,id != menuRequestID,!local.busy {
            menuRequestID=id
            if setupStep == .ready,!local.busy,let game=request["game"] as? String,GameCatalog.titles[game] != nil {
                local.start(game:game,options:request["options"] as? [String:String] ?? [:],avatar:request["avatar"] as? String ?? ""){[weak self] success in
                    guard let self else{return}
                    if success {self.openLocalAfterStart=true}
                    else {self.showLocalStartError(self.local.status)}
                }
            } else {
                showLocalStartError(setupStep != .ready ? "Finish local setup before starting a game." : "This game is not available in this launcher. Reopen MacPigeon after updating.")
            }
        }
        if let data=try? Data(contentsOf:directory.appendingPathComponent("native-local-ready.json")),data.count<4096,let response=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],response["connection_id"] as? String == connectionID,let revision=response["revision"] as? String {local.continueTurn(revision:revision)}
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("native-request.json")),data.count<262144,let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=request["request_id"] as? String,!consumed.contains(id) else{return}
        consumed.insert(id);if consumed.count>1000 {consumed=[id]}
        let revision=request["revision"] as? String ?? "",token=connectionID
        guard setupStep == .ready,request["connection_id"] as? String == token,revision==local.state["revision"] as? String,let fields=request["fields"] as? [String:String] else{return}
        local.play(fields:fields,revision:revision){[weak self] success in
            guard let self,self.localMode,self.connectionID==token else{return}
            self.write(["request_id":id,"connection_id":token,"revision":revision,"accepted":success,"status":success ? self.local.status : "Local turn rejected. Try again."],name:"native-ack.json")
            self.tickLocal()
        }
    }
    private func showLocalStartError(_ message:String){
        write(["id":UUID().uuidString,"connection_id":connectionID,"error":message,"expires_at":Date().timeIntervalSince1970+15],name:"native-invitation-prompt.json")
    }
    func consumeRequest(matched:Bool) {
        guard !localMode else{return}
        if let pending=pendingNativeRequest,!account.busy,["game_sent","game_error"].contains(account.phase) {
            pendingNativeRequest=nil
            if pending["revision"] as? String == state["revision"] as? String, account.phase == "game_error" || account.gameSample?.num == String(state["num"] as? Int ?? -1) {
                write(["request_id":UUID().uuidString,"connection_id":connectionID,"revision":pending["revision"] as? String ?? "","accepted":false,"status":account.gameStatus],name:"native-ack.json")
                if account.phase == "game_error" {account.loadGame()}
            }
        }
        let url=directory.appendingPathComponent("native-request.json")
        guard let data=try? Data(contentsOf:url),data.count<262144,
              let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=request["request_id"] as? String,!consumed.contains(id) else{return}
        consumed.insert(id)
        if consumed.count>1000 {consumed=[id]}
        do {
            guard request["connection_id"] as? String == connectionID,setupStep == .ready,matched,gameSyncReady,!account.busy,account.canPlayGame,account.phoneAuthorized,
                  request["revision"] as? String == state["revision"] as? String,
                  let fields=request["fields"] as? [String:String],let sample=account.gameSample,
                  fields["game"]==sample.game,let number=Int(sample.num ?? ""),fields["num"]==String(number+1),fields["player"]==String(account.ownPlayer) else {throw BoardError.invalid("This turn is stale or the matching chat is not verified.")}
            guard account.sendNativeTurn(fields:fields,number:number) else {throw BoardError.invalid("Transport rejected the current chat or turn state.")}
            pendingNativeRequest=request
            write(["request_id":id,"connection_id":request["connection_id"] as? String ?? "","revision":request["revision"] as? String ?? "","accepted":true,"status":"Sending turn…"],name:"native-ack.json")
        } catch {write(["request_id":id,"connection_id":request["connection_id"] as? String ?? "","revision":request["revision"] as? String ?? "","accepted":false,"status":error.localizedDescription],name:"native-ack.json")}
    }
}
struct NativeConnectionView:View {
    @StateObject var bridge=NativeTransport()
    @State private var showSettings=false
    @State private var showAccount=false
    @State private var showConversation=false
    @State private var conversationName=""
    @State private var conversationAddress=""
    @State private var contactChoices:[String]=[]
    @State private var contactStatus=""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasCurrentGame:Bool {if bridge.localMode{return bridge.local.ready};return bridge.chatMatched && bridge.account.gameSample != nil}
    private var canPlayCurrent:Bool {bridge.localMode ? (bridge.local.ready && !bridge.local.busy && !bridge.local.handoff && !bridge.local.finished) : (bridge.account.canPlayGame || bridge.account.gameSample?.game == "crazy")}
    private var canOpenLast:Bool {bridge.account.phoneAuthorized && bridge.runtime.ready && !bridge.importer.busy}
    private var gameStatus:String {
        if bridge.localMode{return bridge.local.status}
        if bridge.account.gameFinished{return "Game finished"}
        if !bridge.gameSyncReady{return "Checking progress…"}
        if bridge.account.gameSample?.game == "crazy" {return "Live multiplayer room"}
        return bridge.account.canPlayGame ? "Your turn" : "Waiting for your friend"
    }
    var body:some View {
        Group {
            if bridge.setupStep == .ready {launcherContent}
            else {onboarding}
        }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:bridge.setupStep)
        .onChange(of:bridge.setupStep){_,step in
            if step != .ready {showSettings=false;showAccount=false;showConversation=false}
        }
        .sheet(isPresented:$showAccount){AccountView(connection:bridge.account,onConnect:bridge.connect)}
        .sheet(isPresented:$showSettings){settings}
        .sheet(isPresented:$showConversation,onDismiss:{bridge.verifyLastConversation=false}){conversationSheet}
        .onChange(of:bridge.verifyLastConversation){_,requested in
            if requested {conversationName=MessagesContext.conversationName() ?? "";conversationAddress="";contactChoices=[];contactStatus="";showConversation=true}
        }
    }
    private var onboarding:some View {
        VStack(alignment:.leading,spacing:24){
            HStack(spacing:12){
                if let icon=bridge.runtime.icon {Image(nsImage:icon).resizable().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:10))}
                Text("Welcome to MacPigeon").font(.title2.bold())
            }
            HStack{Text(bridge.localMode ? "Local play setup" : "Step \(bridge.setupStep.rawValue+1) of 4");Spacer();Button{showSettings=true}label:{Image(systemName:"gearshape")}.buttonStyle(.plain).help("Settings")}.font(.caption).foregroundStyle(.secondary)
            switch bridge.setupStep {
            case .account:
                AccountView(connection:bridge.account,embedded:true,onConnect:bridge.connect)
            case .messages:
                setupCard(icon:"bubble.left.and.bubble.right",title:"Allow Messages access",detail:"MacPigeon uses the conversation you have open in Messages.")
                HStack{Button("Open Settings"){MessagesContext.requestAccess()}.buttonStyle(.borderedProminent);Button(bridge.checkingPermission ? "Checking…" : "Check again"){bridge.checkPermission()}.disabled(bridge.checkingPermission)}
                if !bridge.permissionFeedback.isEmpty {Text(bridge.permissionFeedback).font(.callout).foregroundStyle(.secondary)}
                if bridge.permissionCheckFailed {permissionTip("Device Control and Data Access")}
            case .fullDiskAccess:
                setupCard(icon:"lock.shield",title:"Allow Full Disk Access",detail:"MacPigeon needs this permission to keep your game progress in sync with Messages.")
                HStack{Button("Open Settings"){bridge.openDiskSettings()}.buttonStyle(.borderedProminent);Button("Check again"){bridge.recheckDiskAccess()}}
                if !bridge.diskFeedback.isEmpty {Text(bridge.diskFeedback).font(.callout).foregroundStyle(.secondary)}
                if bridge.diskCheckFailed {permissionTip("Full Disk Access")}
            case .gameImport:
                setupCard(icon:"gamecontroller",title:bridge.runtime.busy ? "Preparing GamePigeon" : "Add GamePigeon",detail:bridge.runtime.busy ? "Updating your imported game interface." : "Choose your decrypted GamePigeon IPA to load the game interface.")
                Button(bridge.runtime.busy ? "Preparing…" : "Choose IPA…"){bridge.runtime.chooseIPA()}.buttonStyle(.borderedProminent).disabled(bridge.runtime.busy)
                if !bridge.runtime.status.isEmpty {Text(bridge.runtime.status).fixedSize(horizontal:false,vertical:true)}
            case .ready: EmptyView()
            }
        }.padding(28).frame(width:440,alignment:.leading)
    }
    private func permissionTip(_ section:String)->some View {
        VStack(alignment:.leading,spacing:10){
            Text("Remove MacPigeon from \(section), then add it again and enable it.").font(.callout).fixedSize(horizontal:false,vertical:true)
            Button("Show app in Finder"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
        }
    }
    private var launcherContent:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:14) {
                if let icon=bridge.runtime.icon {Image(nsImage:icon).resizable().frame(width:58,height:58).clipShape(RoundedRectangle(cornerRadius:13))}
                VStack(alignment:.leading,spacing:4){Text("MacPigeon").font(.system(size:26,weight:.bold));Text(bridge.localMode ? "Local play" : "Let’s play.").foregroundStyle(.secondary)}
                Spacer()
                Button {showSettings=true} label:{Image(systemName:"gearshape").font(.system(size:19))}.buttonStyle(.plain).padding(8).help("Settings")
            }
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top,spacing:14){
                    Image(systemName:"circle.grid.3x3.fill").font(.system(size:28)).foregroundStyle(.yellow).padding(12).background(Color.yellow.opacity(0.12),in:RoundedRectangle(cornerRadius:14))
                    VStack(alignment:.leading,spacing:6){
                        Text(hasCurrentGame ? (bridge.localMode ? bridge.local.title : (bridge.account.gameSample?.title ?? "Game")) : (bridge.localMode ? "Play together" : "Last game in Messages")).font(.title3.bold())
                        Text(bridge.localMode ? "Pass the Mac between turns." : (bridge.opponentDisplay.isEmpty ? "Open a game bubble in Messages to get started." : "With \(bridge.opponentDisplay)")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        if hasCurrentGame || (bridge.localMode && (bridge.local.busy || bridge.local.status != "Choose a game from the menu.")) {Label(gameStatus,systemImage:canPlayCurrent ? "circle.fill" : "clock").font(.caption).foregroundStyle(canPlayCurrent ? Color.green : Color.secondary).fixedSize(horizontal:false,vertical:true)}
                    }
                }
                if bridge.localMode {
                    Button {bridge.openLocalGame()} label:{HStack{Text("Resume local game").fontWeight(.semibold);Spacer();Image(systemName:"arrow.up.right")}.padding(.vertical,7)}.buttonStyle(.borderedProminent).controlSize(.large).disabled(!bridge.local.ready || bridge.local.busy)
                }else{
                Button {bridge.openCurrentChatGame()} label:{HStack{Text("Open last game").fontWeight(.semibold);Spacer();Image(systemName:"arrow.up.right")}.padding(.vertical,7)}.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canOpenLast)
                if bridge.currentRecipient == nil {Text("Open a conversation in Messages to resume its last game.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:20))
            Button {bridge.openMenu()} label:{HStack(spacing:12){Image(systemName:"gamecontroller").font(.title3);Text("Open menu").fontWeight(.medium);Spacer();Image(systemName:"chevron.right").font(.caption.weight(.semibold))}.padding(16).contentShape(Rectangle())}.buttonStyle(.plain).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:16))
            if bridge.importer.presented {
                HStack(alignment:.top,spacing:10){
                    if bridge.importer.busy {ProgressView().controlSize(.small)}
                    Text(bridge.importer.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Button("Cancel"){bridge.cancelImport()}.font(.caption)
                }
            }
        }.padding(28).frame(width:440)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:canOpenLast)
    }
    private var conversationSheet:some View {
            VStack(alignment:.leading,spacing:16){
                HStack{Text("Verify conversation").font(.title2.bold());Spacer();Button("Cancel"){bridge.verifyLastConversation=false;showConversation=false}}
                Text(conversationName.isEmpty ? "Open a conversation in Messages first." : "Messages shows: \(conversationName)")
                Text("Confirm the iMessage address for this conversation. A contact name alone does not identify an address.").font(.callout).foregroundStyle(.secondary)
                TextField("Phone number with +country code, or email",text:$conversationAddress)
                Button("Find this name in Contacts…"){
                    contactStatus="Looking up this name…"
                    MessagesContext.contactAddresses(named:conversationName){result in
                        switch result {case .success(let addresses):contactChoices=addresses;contactStatus=addresses.isEmpty ? "No address with an explicit country code was found. Enter the address above." : "Choose the address used by this Messages conversation."
                        case .failure(let error):contactStatus=error.localizedDescription}
                    }
                }.disabled(conversationName.isEmpty)
                ForEach(contactChoices,id:\.self){address in Button(String(address.dropFirst(address.hasPrefix("tel:") ? 4 : 7))){conversationAddress=String(address.dropFirst(address.hasPrefix("tel:") ? 4 : 7))}}
                if !contactStatus.isEmpty {Text(contactStatus).font(.caption).fixedSize(horizontal:false,vertical:true)}
                Button("Confirm address"){
                    do{try MessagesContext.verifyNamedConversation(name:conversationName,address:conversationAddress);bridge.tick();showConversation=false;if bridge.verifyLastConversation {bridge.verifyLastConversation=false;bridge.openCurrentChatGame()}}catch{contactStatus=error.localizedDescription}
                }.buttonStyle(.borderedProminent).disabled(MessagesContext.canonicalHandle(conversationAddress)==nil || conversationName.isEmpty)
            }.padding(24).frame(width:480)
    }
    private func setupCard(icon:String,title:String,detail:String)->some View {
        HStack(alignment:.top,spacing:14){Image(systemName:icon).font(.system(size:26)).foregroundStyle(Color.accentColor).frame(width:34);VStack(alignment:.leading,spacing:7){Text(title).font(.title3.bold());Text(detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
    }
    private var settings:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Text("Settings").font(.title2.bold());Spacer();Button("Done"){showSettings=false}}
            ScrollView{VStack(alignment:.leading,spacing:18){
                Toggle("Local mode",isOn:Binding(get:{bridge.localMode},set:{bridge.setLocalMode($0)}))
                Text("Play on this Mac by taking turns in one game window.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Divider()
                if !bridge.localMode {
                Text("Apple Account").font(.headline)
                Label(bridge.account.phoneAuthorized ? "Connected" : (bridge.account.busy ? "Connecting…" : "Disconnected"),systemImage:"person.crop.circle")
                Button(bridge.account.phoneAuthorized ? "Manage account…" : "Sign in…"){showSettings=false;if !bridge.account.phoneAuthorized {bridge.connect()};DispatchQueue.main.asyncAfter(deadline:.now()+0.2){showAccount=true}}.disabled(bridge.account.busy)
                if bridge.account.phoneAuthorized || bridge.account.busy {Button("Disconnect"){bridge.disconnect()}}
                if !bridge.account.phoneAuthorized {Text(bridge.account.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                Divider()
                Text("Messages").font(.headline)
                Label(bridge.permissionGranted ? "Access enabled" : "Access needed",systemImage:"bubble.left.and.bubble.right")
                HStack{Button("Allow access…"){MessagesContext.requestAccess()};Button(bridge.checkingPermission ? "Checking…" : "Check again"){bridge.checkPermission()}.disabled(bridge.checkingPermission)}
                if bridge.permissionCheckFailed {Text("Remove MacPigeon from Device Control and Data Access, then add it again and enable it.").font(.caption).fixedSize(horizontal:false,vertical:true);Button("Show app in Finder"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}}
                if !bridge.permissionFeedback.isEmpty {Text(bridge.permissionFeedback).font(.caption).foregroundStyle(.secondary)}
                if bridge.messagesSyncNeedsAccess {Text("Enable Full Disk Access to sync your game.").font(.caption);Button("Open privacy settings…"){if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"){NSWorkspace.shared.open(url)}}}
                Button("Verify open conversation…"){showSettings=false;conversationName=MessagesContext.conversationName() ?? "";conversationAddress="";contactChoices=[];contactStatus="";DispatchQueue.main.asyncAfter(deadline:.now()+0.2){showConversation=true}}
                Divider()
                }
                Text("GamePigeon").font(.headline)
                Button(bridge.runtime.busy ? "Importing…" : "Import GamePigeon IPA…"){bridge.runtime.chooseIPA()}.disabled(bridge.runtime.busy)
                if !bridge.runtime.status.isEmpty {Text(bridge.runtime.status).font(.caption).fixedSize(horizontal:false,vertical:true)}
                Divider()
                Button("Open Data Folder"){NSWorkspace.shared.open(DataStorage.root)}
                Button("Save diagnostics…"){bridge.exportDiagnostics()}
                Divider()
                VStack(alignment:.leading,spacing:6){
                    Text("Ported to Mac by Chimoochi").font(.caption.bold())
                    Link("GitHub",destination:URL(string:"https://github.com/chimoochi/MacPigeon")!)
                    Link("Apache 2.0 with Commons Clause License Condition v1.0",destination:URL(string:"https://github.com/chimoochi/MacPigeon/blob/main/LICENSE")!)
                        .fixedSize(horizontal:false,vertical:true)
                }.font(.caption)
            }.frame(maxWidth:.infinity,alignment:.leading)}
        }.padding(28).frame(width:420,height:500)
    }

}
private struct StorageStartupView: View {
    @State private var ready = false
    @State private var failed = false
    @State private var preparing = false
    var body: some View {
        Group {
            if ready { NativeConnectionView() }
            else {
                VStack(spacing: 16) {
                    Text(failed ? "MacPigeon couldn’t prepare its data folder." : "Preparing your saved data…")
                    if failed { Button("Try again", action: prepare).disabled(preparing) }
                }.padding(28).frame(width: 420, height: 180)
            }
        }.onAppear { if !ready { prepare() } }
    }
    private func prepare() {
        guard !preparing else { return }
        preparing = true
        DispatchQueue.global().async {
            let success: Bool
            do { try DataStorage.prepare(); success = true } catch { success = false }
            DispatchQueue.main.async { preparing = false; failed = !success; ready = success }
        }
    }
}
@main struct NativeBridgeApp:App {
    var body:some Scene {WindowGroup("MacPigeon"){StorageStartupView()}.windowResizability(.contentSize)}
}
