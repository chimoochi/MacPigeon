import AppKit
import ApplicationServices

extension Notification.Name {
    static let macPigeonGameOpened = Notification.Name("local.macpigeon.gameOpened")
}

// Observe Messages' exact GamePigeon store sheet and replace that visible flow
// with our own window. No injection, event interception, key logging or transcript.
final class GameBubbleOpener: ObservableObject {
    enum OpeningMethod: String, CaseIterable, Identifiable {
        case companion = "Companion window"
        case sheetHook = "Replace Messages sheet (unavailable)"
        var id: String { rawValue }
    }
    // There is no enabled hook backend: task access was denied on the inspected
    // Messages build. Do not represent an overlay or AX dismissal as injection.
    static let sheetHookAvailable = false
    @Published var openingMethod: OpeningMethod = .companion

    @Published var status = "Close this window, then open a game bubble in the matching Messages chat."
    @Published var openedFromBubble = false
    var expectedRecipient: String?
    var showGame: (() -> Void)?
    var importGame: ((String,String?) -> Void)?
    var enabled=false
    private var selectedGUID:String?
    private var selectedTime:TimeInterval=0
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var previousRecipient: String?
    private var previousTime: TimeInterval = 0
    private var handling = false
    private var facts: [String: Bool] = ["keyboard_observed":false,"mouse_observed":false,"transcript_enumerated":false]

    init() {
        if CommandLine.arguments.contains("--ui-preview") || Bundle.main.object(forInfoDictionaryKey: "OfflineUIPreview") as? Bool == true { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func attach(_ app: NSRunningApplication) {
        guard observedPID != app.processIdentifier else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedPID = app.processIdentifier
        var next: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, element, _, context in
            guard let context else { return }
            let owner = Unmanaged<GameBubbleOpener>.fromOpaque(context).takeUnretainedValue()
            owner.poll(notified: element)
        }, &next)
        guard result == .success, let next else { facts["sheet_observer_installed"] = false; return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for key in [kAXSheetCreatedNotification,kAXWindowCreatedNotification,kAXFocusedWindowChangedNotification,kAXFocusedUIElementChangedNotification] {
            if AXObserverAddNotification(next, root, key as CFString, context) == .success { registered = true }
        }
        facts["sheet_observer_installed"] = registered
        observer = next
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(next), .commonModes)
    }
    private func poll(notified: AXUIElement? = nil) {
        guard openingMethod == .companion, enabled, !handling, MessagesContext.allowed,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { return }
        attach(app)
        let current=try? MessagesContext.currentHandle()
        guard let recipient=current ?? previousRecipient else{return}
        // Store modal keeps the underlying conversation fixed. Allow its very
        // recent verified address while the modal temporarily hides AX focus.
        if let current {
            if previousRecipient != current {selectedGUID=nil}
            previousRecipient = current; previousTime = ProcessInfo.processInfo.systemUptime
            if let guid=MessagesContext.selectedBubbleGUID(){selectedGUID=guid;selectedTime=previousTime}
        } else if previousRecipient != recipient || ProcessInfo.processInfo.systemUptime - previousTime > 15 { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.MobileSMS" || notified != nil else { return }
        facts["matching_chat"] = true
        facts["store_watch_active"] = true
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var candidates: [AXUIElement] = []
        if let notified { candidates.append(notified) }
        for key in [kAXFocusedWindowAttribute,kAXFocusedUIElementAttribute,kAXMainWindowAttribute] {
            if let value = MessagesContext.attribute(root, key), CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates.append(unsafeBitCast(value, to: AXUIElement.self))
            }
        }
        if let windows = MessagesContext.attribute(root, kAXWindowsAttribute) as? [AXUIElement] { candidates.append(contentsOf: windows.prefix(8)) }
        var sheets: [AXUIElement] = []
        for element in candidates.prefix(12) {
            if (MessagesContext.attribute(element,kAXRoleAttribute) as? String) == kAXSheetRole { sheets.append(element) }
            // Roles/identifiers only while finding sheets. Never descend into a
            // conversation list, transcript, or message-entry content.
            var budget = 18
            func findSheet(_ node: AXUIElement, depth: Int) {
                guard depth < 3, budget > 0 else { return }; budget -= 1
                let id = MessagesContext.attribute(node,kAXIdentifierAttribute) as? String ?? ""
                if ["TranscriptCollectionView","ConversationList","MessageEntryView"].contains(id) { return }
                if (MessagesContext.attribute(node,kAXRoleAttribute) as? String) == kAXSheetRole { sheets.append(node); return }
                if let children = MessagesContext.attribute(node,kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children.prefix(8) { findSheet(child,depth:depth+1) }
                }
            }
            findSheet(element,depth:0)
        }
        facts["sheet_candidates_found"] = !sheets.isEmpty
        for sheet in sheets.prefix(8) {
            var remaining = 24
            var exactProduct = false
            var done: AXUIElement?
            func header(_ node: AXUIElement, depth: Int) {
                guard depth < 5, remaining > 0 else { return }; remaining -= 1
                let role = MessagesContext.attribute(node,kAXRoleAttribute) as? String ?? ""
                if role == kAXButtonRole,
                   [MessagesContext.attribute(node,kAXTitleAttribute) as? String,MessagesContext.attribute(node,kAXDescriptionAttribute) as? String].contains("Done") { done = node }
                for key in [kAXURLAttribute,kAXDocumentAttribute] {
                    let raw = MessagesContext.attribute(node,key)
                    let address = (raw as? URL)?.absoluteString ?? raw as? String
                    if let address {
                        facts["store_url_attribute_exposed"] = true
                        if Self.isGamePigeonStoreURL(address) { exactProduct = true }
                    }
                }
                // Stop at the web area: only its URL, not reviews/page text.
                if role == "AXWebArea" { return }
                if let children = MessagesContext.attribute(node,kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children.prefix(8) { header(child,depth:depth+1) }
                }
            }
            header(sheet,depth:0)
            if exactProduct {
                facts["embedded_store_sheet_observed"] = true
                facts["specific_gamepigeon_store_url"] = true
                facts["done_button_found"] = done != nil
                guard let done else { report(); return }
                handling = true
                let dismissed = AXUIElementPerformAction(done,kAXPressAction as CFString) == .success
                facts["specific_store_sheet_dismissed"] = dismissed
                report()
                guard dismissed else { handling = false; return }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
                    guard let self else { return }
                    self.handling = false
                    guard self.enabled,(try? MessagesContext.currentHandle()) == recipient else {
                        self.facts["post_dismiss_chat_verified"] = false; self.report(); return
                    }
                    self.facts["post_dismiss_chat_verified"] = true
                    self.openedFromBubble = true
                    self.status = "Choose the game bubble to resume."
                    let guid=ProcessInfo.processInfo.systemUptime-self.selectedTime<3 ? self.selectedGUID : nil
                    self.importGame?(recipient,guid)
                    self.selectedGUID=nil
                    self.facts["import_requested"] = true
                    NotificationCenter.default.post(name:.macPigeonGameOpened,object:nil)
                    self.report()
                }
                return
            }
        }
        // Only report when a modal is present; don't log user activity or timings.
        if !sheets.isEmpty { report() }
    }
    static func isGamePigeonStoreURL(_ value: String) -> Bool {
        let normalized = value.hasPrefix("apps.apple.com/") ? "https://" + value : value
        guard let url = URL(string:normalized),url.scheme == "https",url.host == "apps.apple.com" else { return false }
        return url.path.split(separator:"/").last == "id1124197642"
    }
    static func isGameLabel(_ text: String) -> Bool {
        ["your move.","your move","four in a row"].contains(text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased())
    }
    private func report() {
        guard let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else { return }
        let folder = support.appendingPathComponent("MacPigeon")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url = folder.appendingPathComponent("bubble-open-status.json")
            try JSONSerialization.data(withJSONObject:facts,options:[.sortedKeys]).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { }
    }
    deinit {
        timer?.invalidate()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes) }
    }
}
