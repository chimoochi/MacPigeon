"""Remove Homebrew dynamic-library paths from packaged account helpers."""
import os,shutil,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1]);resources=app/'Contents/Resources';libs=resources/'RuntimeLibraries';libs.mkdir(exist_ok=True)
files=list((app/'Contents/MacOS').iterdir());seen=set()
while files:
 p=files.pop()
 if p in seen or not p.is_file():continue
 seen.add(p)
 result=subprocess.run(['otool','-L',str(p)],capture_output=True,text=True)
 for line in result.stdout.splitlines()[1:]:
  d=line.strip().split(' (')[0]
  if not d.startswith('/opt/homebrew'):continue
  source=Path(d);dest=libs/source.name
  if not dest.exists():shutil.copy2(source.resolve(),dest);files.append(dest)
  subprocess.run(['install_name_tool','-change',d,'@loader_path/'+os.path.relpath(dest,p.parent),str(p)],check=True,stderr=subprocess.DEVNULL)
 if p.suffix=='.dylib':subprocess.run(['install_name_tool','-id','@loader_path/'+p.name,str(p)],check=True,stderr=subprocess.DEVNULL)
 subprocess.run(['codesign','--force','--sign','-',str(p)],check=True,stderr=subprocess.DEVNULL)
print('Account helper libraries relocated and signed.')
