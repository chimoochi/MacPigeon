import AppKit
import Combine
import UniformTypeIdentifiers

final class GameRuntime:ObservableObject {
    @Published var busy=false
    @Published var status=""
    @Published var revision=0
    private var installed:URL {
        DataStorage.root.appendingPathComponent("Installed/MacPigeon Game.app")
    }
    var appURL:URL? {
        if FileManager.default.fileExists(atPath:installed.appendingPathComponent("Contents/Resources/local-import.json").path){return installed}
        return Bundle.main.url(forResource:"MacPigeon Game",withExtension:"app")
    }
    var ready:Bool {appURL != nil}
    var icon:NSImage? {appURL.flatMap{NSImage(contentsOf:$0.appendingPathComponent("Contents/Resources/local-app-icon.png"))}}
    func chooseIPA(){
        guard !busy else{return}
        if let renderer=NSRunningApplication.runningApplications(withBundleIdentifier:"local.macpigeon.native.renderer").first {
            let alert=NSAlert();alert.messageText="Close the game before importing?";alert.informativeText="Any unsent move in the game window will be discarded.";alert.addButton(withTitle:"Close game");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else{return};renderer.terminate()
        }
        let panel=NSOpenPanel();panel.title="Choose your decrypted GamePigeon IPA";panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.allowedContentTypes=[UTType(filenameExtension:"ipa") ?? .data];panel.allowsOtherFileTypes=false
        guard panel.runModal() == .OK,let ipa=panel.url,let resources=Bundle.main.resourceURL,let python=GameImporter.python(in:resources) else{return}
        busy=true;status="Importing GamePigeon…"
        DispatchQueue.global().async {
            let task=Process(),input=Pipe(),output=Pipe();task.executableURL=python
            task.arguments=["-I","-B","-c","import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[2],run_name='__main__')",resources.path,resources.appendingPathComponent("install_local_ipa.py").path]
            task.standardInput=input;task.standardOutput=output;task.standardError=FileHandle.nullDevice;var result:[String:Any]=[:]
            do {try task.run();let request=try JSONSerialization.data(withJSONObject:["ipa":ipa.path]);input.fileHandleForWriting.write(request);input.fileHandleForWriting.write(Data([10]));try? input.fileHandleForWriting.close();let data=output.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();if task.terminationStatus==0,data.count<8192 {result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}}catch{}
            DispatchQueue.main.async{self.busy=false;self.revision+=1;self.status=result["ok"] as? Bool == true ? "GamePigeon imported." : (result["error"] as? String ?? "Import failed. Your previous installation is kept.");if let icon=self.icon{NSApp.applicationIconImage=icon}}
        }
    }
}
