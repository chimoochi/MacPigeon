import AppKit
import ApplicationServices
import Contacts

// Only inspect the window title and conversation header. Never descend into the
// conversation list or transcript, whose descriptions can contain other messages.
enum MessagesContext {
    // A user-selected address is valid only for the unchanged named header.
    private static var verifiedName: String?
    private static var verifiedAddress: String?
    static var allowed: Bool { AXIsProcessTrusted() }
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    static func canonicalHandle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@"), !trimmed.contains(" "), trimmed.filter({ $0 == "@" }).count == 1 { return "mailto:" + trimmed.lowercased() }
        guard trimmed.hasPrefix("+"), trimmed.allSatisfy({ $0.isNumber || "+ ()-".contains($0) }) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        return "tel:+" + digits
    }
    static func address(in text:String)->String? {
        if let exact=canonicalHandle(text){return exact}
        let patterns=[#"\+[0-9][0-9 ()-]{6,24}[0-9]"#,#"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#]
        var found=Set<String>()
        for pattern in patterns {if let regex=try? NSRegularExpression(pattern:pattern){for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)){if let range=Range(match.range,in:text),let value=canonicalHandle(String(text[range])){found.insert(value)}}}}
        return found.count==1 ? found.first : nil
    }
    static func focusedWindow()->AXUIElement? {
        guard allowed,let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.MobileSMS").first else{return nil}
        let root=AXUIElementCreateApplication(app.processIdentifier)
        guard let value=attribute(root,kAXMainWindowAttribute),CFGetTypeID(value)==AXUIElementGetTypeID() else{return nil}
        return unsafeBitCast(value,to:AXUIElement.self)
    }
    static func conversationName()->String? {
        guard let window=focusedWindow() else{return nil}
        var budget=80
        func header(_ node:AXUIElement,_ depth:Int)->String? {
            guard depth<7,budget>0 else{return nil};budget-=1
            let id=attribute(node,kAXIdentifierAttribute) as? String ?? ""
            if ["ConversationList","TranscriptCollectionView","MessageEntryView"].contains(id){return nil}
            if id=="ConversationTitle" {for key in [kAXDescriptionAttribute,kAXTitleAttribute,kAXValueAttribute] {if let name=attribute(node,key) as? String,!name.isEmpty{return name}}}
            if let children=attribute(node,kAXChildrenAttribute) as? [AXUIElement] {for child in children.prefix(30){if let name=header(child,depth+1){return name}}}
            return nil
        }
        let name=header(window,0) ?? attribute(window,kAXTitleAttribute) as? String
        if name != verifiedName {verifiedName=nil;verifiedAddress=nil}
        return name
    }
    static func verifyNamedConversation(name:String,address:String)throws {
        guard conversationName()==name,let canonical=canonicalHandle(address) else{throw BoardError.invalid("The conversation changed. Try again.")}
        verifiedName=name;verifiedAddress=canonical
    }
    static func contactAddresses(named name:String,completion:@escaping(Result<[String],Error>)->Void) {
        let store=CNContactStore()
        store.requestAccess(for:.contacts){allowed,error in
            guard allowed else {DispatchQueue.main.async{completion(.failure(error ?? BoardError.invalid("Contacts access is needed to resolve this name.")))};return}
            do {
                let keys:[CNKeyDescriptor]=[CNContactFormatter.descriptorForRequiredKeys(for:.fullName),CNContactPhoneNumbersKey as CNKeyDescriptor,CNContactEmailAddressesKey as CNKeyDescriptor]
                let matches=try store.unifiedContacts(matching:CNContact.predicateForContacts(matchingName:name),keysToFetch:keys).filter{CNContactFormatter.string(from:$0,style:.fullName)?.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)==name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)}
                guard matches.count==1 else{throw BoardError.invalid("That name does not identify one contact. Verify its iMessage address instead.")}
                let contact=matches[0];let raw=contact.phoneNumbers.map{$0.value.stringValue}+contact.emailAddresses.map{String($0.value)}
                let addresses=Array(Set(raw.compactMap(canonicalHandle))).sorted()
                DispatchQueue.main.async{completion(.success(addresses))}
            }catch{DispatchQueue.main.async{completion(.failure(error))}}
        }
    }
    static func selectedBubbleGUID()->String? {
        guard allowed,let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.MobileSMS").first else{return nil}
        let root=AXUIElementCreateApplication(app.processIdentifier)
        guard let value=attribute(root,kAXFocusedUIElementAttribute),CFGetTypeID(value)==AXUIElementGetTypeID() else{return nil}
        var node=unsafeBitCast(value,to:AXUIElement.self)
        let pattern=#"(?i)(?:^|[^0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:$|[^0-9a-f])"#
        let regex=try? NSRegularExpression(pattern:pattern)
        func identifier(_ element:AXUIElement)->String? {
            guard let id=attribute(element,kAXIdentifierAttribute) as? String,let match=regex?.firstMatch(in:id,range:NSRange(id.startIndex...,in:id)),let range=Range(match.range(at:1),in:id) else{return nil}
            return String(id[range])
        }
        for _ in 0..<5 {
            // Identifiers only; never read bubble text, description, or neighbors.
            if let guid=identifier(node){return guid}
            if let selected=attribute(node,kAXSelectedChildrenAttribute) as? [AXUIElement],selected.count==1,let guid=identifier(selected[0]){return guid}
            guard let parent=attribute(node,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID() else{break};node=unsafeBitCast(parent,to:AXUIElement.self)
        }
        if let window=focusedWindow(){
            var budget=80
            func selected(_ node:AXUIElement,_ depth:Int)->String? {
                guard depth<7,budget>0 else{return nil};budget-=1
                let id=attribute(node,kAXIdentifierAttribute) as? String ?? ""
                if id=="TranscriptCollectionView" {
                    // Access only the one selected object's identifier, never its text,
                    // the transcript's children, or neighboring messages.
                    if let children=attribute(node,kAXSelectedChildrenAttribute) as? [AXUIElement],children.count==1{return identifier(children[0])}
                    return nil
                }
                if ["ConversationList","MessageEntryView"].contains(id){return nil}
                if let children=attribute(node,kAXChildrenAttribute) as? [AXUIElement]{for child in children.prefix(30){if let guid=selected(child,depth+1){return guid}}}
                return nil
            }
            return selected(window,0)
        }
        return nil
    }
    static func currentHandle() throws -> String {
        guard allowed else { throw BoardError.invalid("Enable MacPigeon in System Settings → Privacy & Security → Accessibility, then try again.") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { throw BoardError.invalid("Open a conversation in Messages first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let windows = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap { key -> AXUIElement? in
            guard let value = attribute(root, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        // A store sheet can become focused while the underlying conversation stays
        // the main window. Do not inspect other conversations or unrelated windows.
        for window in windows {
            var current = window
            for _ in 0..<5 {
                if (attribute(current,kAXRoleAttribute) as? String) == kAXWindowRole,
                   let title = attribute(current,kAXTitleAttribute) as? String,let handle = address(in:title) { return handle }
                if let document=attribute(current,kAXDocumentAttribute) as? String,let handle=address(in:document.removingPercentEncoding ?? document){return handle}
                guard let parent = attribute(current,kAXParentAttribute),CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = unsafeBitCast(parent,to:AXUIElement.self)
            }
        }
        guard let window = windows.first(where: { (attribute($0, kAXRoleAttribute) as? String) != kAXSheetRole }) else { throw BoardError.invalid("Select a Messages conversation first.") }
        var remaining = 80
        func header(_ element: AXUIElement, depth: Int) -> String? {
            guard depth < 7, remaining > 0 else { return nil }; remaining -= 1
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
            if ["ConversationList", "TranscriptCollectionView"].contains(identifier) { return nil }
            if identifier == "ConversationTitle" {for key in [kAXDescriptionAttribute,kAXTitleAttribute,kAXValueAttribute,kAXHelpAttribute] {if let text=attribute(element,key) as? String,let handle=address(in:text){return handle}}}
            if identifier == "messageBodyField", let help = attribute(element, kAXHelpAttribute) as? String, let handle = canonicalHandle(help) { return handle }
            guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for child in children.prefix(30) { if let found = header(child, depth: depth+1) { return found } }
            return nil
        }
        guard let found = header(window, depth: 0) else {
            if let name=conversationName(),name==verifiedName,let verifiedAddress{return verifiedAddress}
            throw BoardError.invalid("Verify the iMessage address for this named conversation.")
        }
        return found
    }
}
