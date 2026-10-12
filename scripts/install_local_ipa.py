"""Private user-supplied IPA installer. Supported inspected binary only; no downloads."""
import hashlib,json,os,plistlib,shutil,stat,subprocess,sys,tempfile,zipfile
from pathlib import Path,PurePosixPath
from binary_adapter import adapt

def refresh_host(resources,destination):
 """Update launcher-owned host files without requiring the original IPA again."""
 resources=Path(resources);destination=Path(destination)
 marker=destination/'Contents/Resources/local-import.json'
 if not marker.is_file():return {'ok':True,'updated':False}
 template=resources/'RendererHostTemplate.app'
 names=['Contents/MacOS/OriginalHost','Contents/Info.plist','Contents/Resources/macpigeon-game-registry.json']
 metadata=json.loads(marker.read_text())
 # Signing changes the executable's signature bytes. Compare its template hash,
 # recorded before signing, rather than the installed signed executable.
 template_hash=hashlib.sha256((template/names[0]).read_bytes()).hexdigest()
 if metadata.get('host_sha256')==template_hash and all((destination/name).read_bytes()==(template/name).read_bytes() for name in names[1:]):
  return {'ok':True,'updated':False}
 subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
 with tempfile.TemporaryDirectory(prefix='host-update-',dir=destination.parent) as tmp:
  stage=Path(tmp)/destination.name;shutil.copytree(destination,stage,symlinks=True)
  for name in names:shutil.copy2(template/name,stage/name)
  metadata['host_sha256']=template_hash
  (stage/'Contents/Resources/local-import.json').write_text(json.dumps(metadata))
  entitlements=Path(tmp)/'sandbox.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
  subprocess.run(['codesign','--force','--sign','-','--entitlements',str(entitlements),str(stage)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
  subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
  previous=destination.with_name(destination.stem+' Previous.app')
  if previous.exists():shutil.rmtree(previous)
  destination.rename(previous)
  try:stage.rename(destination)
  except OSError:
   previous.rename(destination);raise
 return {'ok':True,'updated':True}

def install(ipa,resources,destination):
 ipa=Path(ipa);resources=Path(resources);destination=Path(destination)
 if not ipa.is_file() or ipa.stat().st_size>300*1024*1024:raise ValueError('ipa_limit')
 input_digest=hashlib.sha256(ipa.read_bytes()).hexdigest()
 spec=json.loads((resources/'supported-game-binary.json').read_text())
 destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True);destination.parent.chmod(0o700)
 with tempfile.TemporaryDirectory(prefix='import-',dir=destination.parent) as tmp:
  stage=Path(tmp)/destination.name;shutil.copytree(resources/'RendererHostTemplate.app',stage)
  contents=stage/'Contents/Resources';contents.mkdir(exist_ok=True)
  with zipfile.ZipFile(ipa) as z:
   entries=z.infolist()
   if len(entries)>20000 or sum(e.file_size for e in entries)>900*1024*1024:raise ValueError('archive_limit')
   for e in entries:
    path=PurePosixPath(e.filename)
    if path.is_absolute() or '..' in path.parts or '\\' in e.filename or stat.S_ISLNK(e.external_attr>>16):raise ValueError('archive_path')
   matches=[]
   for entry in entries:
    if '.appex/Info.plist' not in entry.filename or entry.file_size>65536:continue
    info=plistlib.loads(z.read(entry))
    if info.get('CFBundleIdentifier')==spec['bundle']:matches.append((entry,info))
   if len(matches)!=1:raise ValueError('extension_selection')
   entry,info=matches[0];prefix=entry.filename[:-len('Info.plist')];name=info['CFBundleExecutable'];raw=z.read(prefix+name)
   # This allowlist refers to the binary already inspected and executed locally.
   # cryptid=0 alone is deliberately not treated as proof of a valid dump.
   digest=hashlib.sha256(raw).hexdigest()
   if digest!=spec['sha256']:raise ValueError('unsupported_binary')
   patched=adapt(raw);bundle=contents/'ExtensionProbe.bundle';bundle.mkdir(exist_ok=True)
   (bundle/'ExtensionProbe').write_bytes(patched)
   (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.macpigeon.ios-host.extension-probe','CFBundleExecutable':'ExtensionProbe','CFBundlePackageType':'BNDL'}))
   for e in entries:
    if not e.filename.startswith(prefix):continue
    relative=PurePosixPath(e.filename[len(prefix):])
    if not relative.parts or relative.parts[0] in ['Info.plist',name,'_CodeSignature','embedded.mobileprovision','Frameworks']:continue
    target=contents.joinpath(*relative.parts)
    if e.is_dir():target.mkdir(parents=True,exist_ok=True)
    else:target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(z.read(e))
   icon=prefix.split('PlugIns/')[0]+'AppIcon60x60@3x.png'
   if icon in z.namelist() and z.getinfo(icon).file_size<=1048576:(contents/'local-app-icon.png').write_bytes(z.read(icon))
  (contents/'local-import.json').write_text(json.dumps({'source_sha256':digest,'host_sha256':hashlib.sha256((stage/'Contents/MacOS/OriginalHost').read_bytes()).hexdigest(),'original_ipa_unchanged':True}))
  entitlements=Path(tmp)/'sandbox.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
  for cmd in [['codesign','--force','--sign','-',str(bundle)],['codesign','--force','--sign','-','--entitlements',str(entitlements),str(stage)],['codesign','--verify','--deep','--strict',str(stage)]]:
   subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
  if destination.exists():
   previous=destination.with_name(destination.stem+' Previous.app')
   # Keep the previous generated install until a subsequent successful import.
   if previous.exists():shutil.rmtree(previous)
   destination.rename(previous)
  stage.rename(destination)
 return {'ok':True,'source_unchanged':hashlib.sha256(ipa.read_bytes()).hexdigest()==input_digest}

def main():
 request=json.loads(sys.stdin.buffer.readline(8193))
 try:
  resources=Path(__file__).resolve().parent;destination=Path.home()/'Library/Application Support/MacPigeon/Installed/MacPigeon Game.app'
  result=refresh_host(resources,destination) if request.get('action')=='refresh_host' else install(request['ipa'],resources,destination)
 except (ValueError,KeyError,OSError,zipfile.BadZipFile,plistlib.InvalidFileException,subprocess.SubprocessError):result={'ok':False,'error':'The IPA could not be imported. Use the supported decrypted GamePigeon version; the previous installation is kept.'}
 print(json.dumps(result))
if __name__=='__main__':main()
