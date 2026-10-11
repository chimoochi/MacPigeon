enum SetupStep:Int {
    case account, messages, fullDiskAccess, gameImport, ready
    static func required(account:Bool,messages:Bool,disk:Bool,game:Bool,local:Bool=false)->SetupStep {
        if local{return game ? .ready : .gameImport}
        if !account{return .account}
        if !messages{return .messages}
        if !disk{return .fullDiskAccess}
        if !game{return .gameImport}
        return .ready
    }
}

