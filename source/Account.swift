import AppKit
import SwiftUI
import Security

final class AccountConnection: ObservableObject {
    @Published var phase = "starting"
    @Published var status = "Connecting…"
    @Published var busy = true
    @Published var choices: [(Int, String)] = []
    private var process: Process?
    private var input: FileHandle?
    private let keychainQueue = DispatchQueue(label: "local.macpigeon.account.keychain")
    private let queue = DispatchQueue(label: "local.macpigeon.account.pipe")
    private let service = "local.macpigeon.lab.account"
    private let key = "experimental-session"
    @Published var certificatePrepared = false
    private var certificateKeyMatches = false
    private var certificateKeyBits: Int?
    private var idsAuthorized = false
    private var idsFailureStage: String?
    private var idsFailureCode: Int?
    @Published var senderHandles: [String] = []
    private var pushBootstrapReady = false
    @Published var deliveryKeysSaved = false
    private var registrationCalled = false
    @Published var phoneAuthorized = false
    @Published var testAttempted = false
    @Published var testAcknowledged = false
    @Published var receivedBoardPath: String?
    private var selectedGameReceived = false
    private var connectionVerified = false

    @Published var gameSample: GameSample?
    @Published var canPlayGame = false
    @Published var gameRecipient: String?
    @Published var ownPlayer = 2
    @Published var gameRevision = 0
    @Published var gameStatus = "Opening your saved game…"
    var gameFinished:Bool {gameSample?.finished ?? false}
    private var autoConnected = false
    private var receiveAgain: DispatchWorkItem?
    private var receiveFailures = 0
    @Published private(set) var receivingGame = false
    private var gamePollingEnabled = true
    private var queuedInvitation:(game:String,options:[String:String],recipient:String)?
    private var helperGeneration=0
    init(startImmediately: Bool = true) { if startImmediately { start() } else { busy=false; phase="idle"; status="Ready to connect your account." } }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    func start() {
        guard process == nil else { return }
        helperGeneration+=1;let generation=helperGeneration
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "macpigeon-auth") else {
            phase = "error"; status = "The account helper is missing."; busy = false; return
        }
        let task = Process(), source = Pipe(), destination = Pipe()
        task.executableURL = helper
        // Passwords, codes and session tokens travel only through these private pipes.
        task.arguments = []
        task.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(), "PYTHONDONTWRITEBYTECODE": "1"]
        task.standardInput = source; task.standardOutput = destination
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            guard let self, self.helperGeneration == generation else { return }
            self.process = nil; self.input = nil; self.busy = false
            self.phase = "error"; self.status = "Connection stopped. Reconnect to check game progress."
        } }
        do { try task.run() } catch {
            phase = "error"; status = "Couldn’t start the account helper."; busy = false; return
        }
        process = task; input = source.fileHandleForWriting
        queue.async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = destination.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 2_000_000 { task.terminate(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    let event = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: event) as? [String: Any] else { continue }
                    DispatchQueue.main.async {guard self?.helperGeneration==generation else{return};self?.receive(object)}
                }
            }
        }
    }
    private func receive(_ event: [String: Any]) {
        guard let kind = event["type"] as? String else { return }
        if ["game_loaded", "game_sent", "game_received", "game_wait"].contains(kind) {
            if let game = event["game"], let data = try? JSONSerialization.data(withJSONObject: game), let sample = try? JSONDecoder().decode(GameSample.self, from: data) {
                gameSample = sample; gameRevision += 1
            }
            receivingGame=false
            canPlayGame = event["can_play"] as? Bool ?? false
            gameRecipient = event["recipient"] as? String ?? gameRecipient
            ownPlayer = event["own_player"] as? Int ?? ownPlayer
            gameStatus = event["message"] as? String ?? "Game updated."
            if gameFinished {canPlayGame=false;gameStatus="Game finished."}
            busy = false; phase = kind; status = gameStatus
            receiveFailures = 0
            if runQueuedInvitation() {return}
            if !canPlayGame && phoneAuthorized && !gameFinished { scheduleReceive() }
            return
        }
        if ["game_error", "game_receive_error", "game_unavailable"].contains(kind) {
            receivingGame=false
            busy = false; phase = kind; gameStatus = event["message"] as? String ?? "Game unavailable."
            status = gameStatus
            if kind == "game_error" { canPlayGame = false }
            if kind == "game_receive_error",runQueuedInvitation() {return}
            if kind == "game_receive_error", phoneAuthorized, !canPlayGame {
                receiveFailures = min(receiveFailures + 1, 5)
                gameStatus = "Connection interrupted. Retrying…"; status = gameStatus
                scheduleReceive(delay:min(30,pow(2,Double(receiveFailures))))
            }
            return
        }
        if kind == "session" {
            guard let object = event["data"], let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            let needsAck = event["await_transport_ack"] as? Bool ?? false
            let lookup = query
            keychainQueue.async { [weak self] in
                let update = [kSecValueData as String: data]
                var result = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
                if result == errSecItemNotFound {
                    var addition = lookup
                    addition[kSecValueData as String] = data
                    addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    result = SecItemAdd(addition as CFDictionary, nil)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if result != errSecSuccess { self.status = "The app’s keys couldn’t be saved in Keychain. Delivery registration is blocked." }
                    if needsAck { self.send(["action": "transport_state_saved", "success": result == errSecSuccess]) }
                }
            }
            return
        }
        if kind == "delivery_progress" {
            status = "Connecting…"
            deliveryKeysSaved = event["delivery_keys_saved"] as? Bool ?? deliveryKeysSaved
            busy = true; return
        }
        if kind == "delivery_registered" || kind == "delivery_error" {
            deliveryKeysSaved = event["delivery_keys_saved"] as? Bool ?? deliveryKeysSaved
            registrationCalled = event["ids_registration_called"] as? Bool ?? registrationCalled
            phoneAuthorized = event["phone_number_authorized"] as? Bool ?? phoneAuthorized
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
            idsAuthorized = event["ids_delegate_authorized"] as? Bool ?? idsAuthorized
            pushBootstrapReady = event["push_bootstrap_ready"] as? Bool ?? pushBootstrapReady
            certificatePrepared = event["ids_account_certificate_prepared"] as? Bool ?? certificatePrepared
            certificateKeyMatches = event["certificate_key_matches"] as? Bool ?? certificateKeyMatches
            certificateKeyBits = event["key_bits"] as? Int ?? certificateKeyBits
            senderHandles = event["handles"] as? [String] ?? senderHandles
        }
        if kind == "test_transport_acknowledged" || kind == "test_send_unconfirmed" {
            testAttempted = event["send_called"] as? Bool ?? testAttempted
            testAcknowledged = event["recipient_transport_acknowledged"] as? Bool ?? false
            connectionVerified = event["registered_connection_verified"] as? Bool ?? connectionVerified
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
        }
        if kind == "test_reply_received" || kind == "test_receive_wait" {
            receivedBoardPath = event["received_board_path"] as? String
            selectedGameReceived = event["selected_game_received"] as? Bool ?? false
            connectionVerified = event["registered_connection_verified"] as? Bool ?? connectionVerified
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
        }
        busy = false
        if kind == "ready" {
            phase = "login"; status = "Sign in with the Apple Account you use for iMessage."
            record("ready")
            restoreSession()
            return
        }
        if kind == "restored" {
            testAttempted = event["test_attempt_reserved"] as? Bool ?? false
            deliveryKeysSaved = event["delivery_keys_saved"] as? Bool ?? false
            testAcknowledged = event["test_recipient_acknowledged"] as? Bool ?? false
        }
        if kind == "restore_error" {
            phase = "login"; status = event["message"] as? String ?? "Saved session could not be read."; record(kind); return
        }
        if kind == "sms_choice" {
            choices = (event["choices"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? Int, let label = $0["label"] as? String else { return nil }
                return (id, label)
            }
        }
        if kind == "certificate_ready" || kind == "certificate_error" {
            idsAuthorized = event["ids_delegate_authorized"] as? Bool ?? idsAuthorized
            certificatePrepared = kind == "certificate_ready"
            certificateKeyMatches = event["certificate_key_matches"] as? Bool ?? certificateKeyMatches
            certificateKeyBits = event["key_bits"] as? Int ?? certificateKeyBits
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
        }
        if kind == "ids_access" {
            idsAuthorized = true; idsFailureStage = nil; idsFailureCode = nil
        } else if kind == "ids_error" {
            idsAuthorized = false
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
        }
        if kind == "sender_handles_ready" || kind == "sender_handles_error" {
            pushBootstrapReady = event["push_bootstrap_ready"] as? Bool ?? false
            certificatePrepared = event["ids_account_certificate_prepared"] as? Bool ?? certificatePrepared
            certificateKeyMatches = event["certificate_key_matches"] as? Bool ?? certificateKeyMatches
            certificateKeyBits = event["key_bits"] as? Int ?? certificateKeyBits
            idsAuthorized = event["ids_delegate_authorized"] as? Bool ?? idsAuthorized
            senderHandles = event["handles"] as? [String] ?? []
            idsFailureStage = event["failure_stage"] as? String
            idsFailureCode = event["numeric_code"] as? Int
        }
        if kind != "error" || phase == "starting" { phase = kind }
        status = ["restored", "authenticated"].contains(kind) ? "Sign-in complete." : (kind == "delivery_registered" ? "Connected." : (event["message"] as? String ?? "Connecting…"))
        record(kind)
        if ["restored", "authenticated"].contains(kind), !autoConnected {
            autoConnected = true
            DispatchQueue.main.async { [weak self] in self?.connectDelivery() }
        } else if kind == "delivery_registered" { loadGame() }
    }
    #if OFFLINE_TESTS
    var fixtureRecipient:String?
    var fixtureCommands:[[String:Any]]=[]
    func beginReceiveFixture(){receivingGame=true;busy=true}
    func applyFixture(_ event:[String:Any]){receive(event)}
    #endif
    func restoreSession() {
        busy = true; status = "Restoring your sign-in…"
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        // Keychain may display a system prompt. Keep the app’s main thread responsive.
        keychainQueue.async { [weak self] in
            var result: CFTypeRef?
            let code = SecItemCopyMatching(lookup as CFDictionary, &result)
            let data = result as? Data
            DispatchQueue.main.async {
                guard let self else { return }
                if code == errSecSuccess, let data,
                   let saved = try? JSONSerialization.jsonObject(with: data) {
                    self.send(["action": "restore", "data": saved])
                } else {
                    self.busy = false; self.phase = "login"
                    self.status = code == errSecItemNotFound
                        ? "No saved session was found. Sign in locally to continue."
                        : "Saved session could not be loaded (Keychain code \(code)). Retry the saved session or sign in locally."
                    self.record("restore_error", keychainCode: Int(code))
                }
            }
        }
    }
    private func record(_ kind: String, keychainCode: Int? = nil) {
        // Only booleans and fixed event names; never account identifiers or raw responses.
        let accepted = ["ready", "authenticated", "restored", "code", "sms_choice", "error", "ids_access", "ids_error", "restore_error", "certificate_ready", "certificate_error", "sender_handles_ready", "sender_handles_error", "delivery_registered", "delivery_error", "test_transport_acknowledged", "test_send_unconfirmed", "test_reply_received", "test_receive_wait"]
        guard accepted.contains(kind) else { return }
        var report: [String: Any] = ["last_event": kind, "authentication_provider_ready": kind != "error", "account_authenticated_this_run": kind == "authenticated",
            "ids_delegate_authorized": idsAuthorized, "ids_account_certificate_prepared": certificatePrepared, "certificate_key_matches": certificateKeyMatches,
            "ids_registration_called": registrationCalled, "phone_number_authorized": phoneAuthorized, "delivery_keys_saved": deliveryKeysSaved, "live_transport_connected": false,
            "send_called": testAttempted, "recipient_transport_acknowledged": testAcknowledged, "registered_connection_verified": connectionVerified, "game_acceptance_verified": false, "selected_game_received": selectedGameReceived, "ordinary_message_contents_saved": false, "credentials_logged": false]
        report["push_bootstrap_ready"] = pushBootstrapReady
        report["phone_handle_count"] = senderHandles.filter { $0.hasPrefix("tel:") }.count
        if let certificateKeyBits { report["certificate_key_bits"] = certificateKeyBits }
        if let keychainCode { report["keychain_code"] = keychainCode }
        if let idsFailureStage { report["ids_failure_stage"] = idsFailureStage }
        if let idsFailureCode { report["ids_failure_code"] = idsFailureCode }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = support.appendingPathComponent("MacPigeon", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("account-status.json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* No credential-bearing errors or paths are logged. */ }
    }
    func send(_ object: [String: Any]) {
        #if OFFLINE_TESTS
        if fixtureRecipient != nil {fixtureCommands.append(object);return}
        #endif
        guard let input,process?.isRunning==true else{busy=false;canPlayGame=false;phase="error";status="Connection stopped. Reconnect to check game progress.";return}
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        do { try input.write(contentsOf: data) } catch { status = "Connection stopped. Reconnect to check game progress."; busy = false;canPlayGame=false }
    }
    func login(email: String, password: String) { busy = true; status = "Authenticating with Apple…"; send(["action": "login", "email": email, "password": password]) }
    func verify(code: String) { busy = true; status = "Verifying with Apple…"; send(["action": "verify", "code": code]) }
    func sms(id: Int) { busy = true; send(["action": "sms", "id": id]) }
    func checkIDS() { busy = true; status = "Checking iMessage account access with Apple…"; send(["action": "check_ids"]) }
    func prepareCertificate() { busy = true; status = "Preparing your app’s account certificate with Apple…"; send(["action": "prepare_certificate"]) }
    func checkSenderHandles() { busy = true; status = "Checking your iMessage phone-number sender with Apple…"; send(["action": "check_sender_handles"]) }
    func connectDelivery() {if process==nil{start();return};busy = true; status = "Preparing your saved delivery identity…"; send(["action": "connect_delivery"]) }
    func loadGame() { receiveAgain?.cancel(); busy = true; send(["action": "load_game"]) }
    @discardableResult func sendNativeTurn(fields:[String:String],number:Int)->Bool {
        guard !busy,phoneAuthorized,canPlayGame,let recipient=try? MessagesContext.currentHandle(),recipient==gameRecipient else{return false}
        receiveAgain?.cancel();busy=true;canPlayGame=false;gameStatus="Sending your turn…"
        send(["action":"send_native_turn","fields":fields,"expected_num":number]);return true
    }
    private func invitationRecipient()->String? {
        #if OFFLINE_TESTS
        if let fixtureRecipient {return fixtureRecipient}
        #endif
        return try? MessagesContext.currentHandle()
    }
    @discardableResult func startGame(game:String,options:[String:String],recipient:String)->Bool {
        guard (!busy || receivingGame),queuedInvitation==nil,phoneAuthorized,invitationRecipient()==recipient else{return false}
        receiveAgain?.cancel()
        if receivingGame {queuedInvitation=(game,options,recipient);gameStatus="Finishing the current connection check…";status=gameStatus;return true}
        busy=true;canPlayGame=false;gameStatus="Sending invitation…"
        send(["action":"start_game","game":game,"options":options,"recipient":recipient]);return true
    }
    private func runQueuedInvitation()->Bool {
        guard let pending=queuedInvitation else{return false}
        queuedInvitation=nil
        if !startGame(game:pending.game,options:pending.options,recipient:pending.recipient) {
            phase="game_error";gameStatus="The conversation changed. Open your intended chat and try again.";status=gameStatus
        }
        return true
    }
    func setGamePollingEnabled(_ enabled:Bool) {
        guard enabled != gamePollingEnabled else{return}
        gamePollingEnabled=enabled
        if !enabled {receiveAgain?.cancel();receiveAgain=nil}
        else if !busy && !canPlayGame && phoneAuthorized && !gameFinished {scheduleReceive()}
    }
    private func scheduleReceive(delay:TimeInterval = 2) {
        receiveAgain?.cancel()
        // Room gameplay is delivered by the original SDK, not alternating iMessage turns.
        guard gamePollingEnabled,queuedInvitation==nil,gameSample?.game != "crazy" else{return}
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gamePollingEnabled,self.queuedInvitation==nil,self.gameSample?.game != "crazy",!self.busy, !self.canPlayGame, !self.gameFinished, self.phoneAuthorized else { return }
            self.receivingGame=true;self.busy = true; self.gameStatus = "Waiting for your friend…"; self.status = self.gameStatus
            self.send(["action": "receive_game"])
        }
        receiveAgain = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func sendPreparedTest() { busy = true; status = "Preparing the selected game reply…"; send(["action": "send_prepared_test"]) }
    func receiveSelectedReply() { busy = true; status = "Watching for your friend’s reply in the selected game for up to 90 seconds…"; send(["action": "receive_selected_test_reply"]) }
    func disconnect() {
        helperGeneration+=1
        receiveAgain?.cancel(); receiveAgain=nil; receiveFailures=0;receivingGame=false;queuedInvitation=nil
        process?.terminationHandler=nil
        try? input?.close(); process?.terminate(); process=nil; input=nil
        autoConnected=false; phoneAuthorized=false; canPlayGame=false; gameSample=nil
        gameRecipient=nil;senderHandles=[];certificatePrepared=false
        busy=false; phase="idle"; status="Disconnected."
    }
    func forget() {
        if deliveryKeysSaved { status = "Delivery keys are retained until this identity can be unregistered safely."; return }
        SecItemDelete(query as CFDictionary)
        send(["action": "quit"])
        phase = "login"; status = "Local session removed. Reopen the app to sign in again."
    }
    deinit { receiveAgain?.cancel(); try? input?.close(); process?.terminate() }
}

struct AccountView: View {
    @ObservedObject var connection: AccountConnection
    var embedded=false
    var onConnect:(()->Void)?=nil
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your Apple Account").font(.title2.bold())
            Text(connection.status).fixedSize(horizontal: false, vertical: true)
            if connection.phase == "idle" {
                Button("Connect") { if let onConnect {onConnect()}else{connection.start()} }
            } else if connection.phase == "login" {
                TextField("Apple Account email or phone number", text: $email)
                SecureField("Password", text: $password)
                Button("Retry saved session") { connection.restoreSession() }.disabled(connection.busy)
                Button("Sign in") {
                    connection.login(email: email, password: password)
                    password = ""
                }.disabled(connection.busy || email.isEmpty || password.isEmpty)
            } else if connection.phase == "code" {
                SecureField("Six-digit verification code", text: $code)
                Button("Verify") { connection.verify(code: code); code = "" }
                    .disabled(connection.busy || code.count != 6 || !code.utf8.allSatisfy { $0 >= 48 && $0 <= 57 })
            } else if connection.phase == "sms_choice" {
                ForEach(connection.choices, id: \.0) { item in
                    Button(item.1) { connection.sms(id: item.0) }.disabled(connection.busy)
                }
            } else {
                if connection.phoneAuthorized {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    ForEach(connection.senderHandles.filter { $0.hasPrefix("tel:") }, id: \.self) { handle in
                        Text(String(handle.dropFirst(4))).font(.callout).textSelection(.enabled)
                    }
                } else if !connection.busy {
                    Button("Reconnect") { if let onConnect {onConnect()}else{connection.connectDelivery()} }
                }
            }
            if connection.busy { ProgressView().controlSize(.small) }
            Text("Your sign-in is saved securely in Keychain.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !embedded {HStack {
                Spacer()
                Button("Close") { password = ""; code = ""; dismiss() }
            }}
        }.textFieldStyle(.roundedBorder).padding(embedded ? 0 : 28).frame(width: embedded ? nil : 460)
    }
}
