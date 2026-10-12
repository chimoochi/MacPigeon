import AppKit
import Combine
import UniformTypeIdentifiers
import CryptoKit

final class GameRuntime:ObservableObject {
    @Published var busy=false
    @Published var status=""
    @Published var revision=0
    private var hostPrepared=false
    private var hostUpdateFailed=false
    private var installed:URL {
        DataStorage.root.appendingPathComponent("Installed/MacPigeon Game.app")
    }
    var appURL:URL? {
        if FileManager.default.fileExists(atPath:installed.appendingPathComponent("Contents/Resources/local-import.json").path){return installed}
        return Bundle.main.url(forResource:"MacPigeon Game",withExtension:"app")
    }
    var ready:Bool {hostPrepared && !busy && appURL != nil}
    func prepareInstalledHost(){
        guard !hostPrepared,!hostUpdateFailed,!busy else{return}
        guard FileManager.default.fileExists(atPath:installed.appendingPathComponent("Contents/Resources/local-import.json").path) else{hostPrepared=true;return}
        if let resources=Bundle.main.resourceURL {
            let template=resources.appendingPathComponent("RendererHostTemplate.app")
            let files=["Contents/Info.plist","Contents/Resources/macpigeon-game-registry.json"]
            if let binary=try? Data(contentsOf:template.appendingPathComponent("Contents/MacOS/OriginalHost")),
               let data=try? Data(contentsOf:installed.appendingPathComponent("Contents/Resources/local-import.json")),
               let metadata=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               metadata["host_sha256"] as? String == SHA256.hash(data:binary).map({String(format:"%02x",$0)}).joined(),files.allSatisfy({name in
                guard let current=try? Data(contentsOf:installed.appendingPathComponent(name)),let bundled=try? Data(contentsOf:template.appendingPathComponent(name)) else{return false}
                return current==bundled
            }){hostPrepared=true;return}
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier:"local.macpigeon.native.renderer").isEmpty else{status="Close the game window to finish updating GamePigeon.";return}
        guard let resources=Bundle.main.resourceURL,let python=GameImporter.python(in:resources) else{hostUpdateFailed=true;status="Game update could not start. Import your IPA again.";return}
        busy=true;status="Updating GamePigeon…"
        let destination=installed
        DispatchQueue.global().async {
            let task=Process(),input=Pipe(),output=Pipe();var result:[String:Any]=[:]
            task.executableURL=python
            task.arguments=["-I","-B","-c","import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[2],run_name='__main__')",resources.path,resources.appendingPathComponent("install_local_ipa.py").path]
            task.standardInput=input;task.standardOutput=output;task.standardError=FileHandle.nullDevice
            do {
                try task.run();input.fileHandleForWriting.write(Data("{\"action\":\"refresh_host\"}\n".utf8));try input.fileHandleForWriting.close()
                let data=output.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
                if task.terminationStatus==0,data.count<8192 {result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}
            }catch{}
            DispatchQueue.main.async {
                self.busy=false;self.hostPrepared=result["ok"] as? Bool == true;self.hostUpdateFailed = !self.hostPrepared;self.revision+=1
                self.status=self.hostPrepared ? "" : "Game update failed. Import your IPA again; your previous installation is kept."
                if self.hostPrepared,result["updated"] as? Bool == true {NSWorkspace.shared.noteFileSystemChanged(destination.path)}
            }
        }
    }
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
            DispatchQueue.main.async{self.busy=false;self.revision+=1;if result["ok"] as? Bool == true{self.hostPrepared=true;self.hostUpdateFailed=false};self.status=result["ok"] as? Bool == true ? "GamePigeon imported." : (result["error"] as? String ?? "Import failed. Your previous installation is kept.");if let icon=self.icon{NSApp.applicationIconImage=icon}}
        }
    }
}
