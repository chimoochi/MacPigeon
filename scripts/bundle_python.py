"""Bundle the installed Python runtime and relocate its non-system libraries."""
import os, shutil, subprocess, sys
from pathlib import Path
if sys.version_info[:2] != (3, 13):
    raise RuntimeError('Run the build with framework Python 3.13 (MACPIGEON_PYTHON).')
SOURCE=Path(os.environ.get('MACPIGEON_PYTHON_FRAMEWORK', sys.base_prefix)).resolve()
if not (SOURCE/'Python').is_file():
    raise RuntimeError('A framework Python build is required; install Homebrew python@3.13.')
resources=Path(sys.argv[1]);target=resources/'Python.framework/Versions/3.13'
if not target.exists():
    shutil.copytree(SOURCE,target,ignore=shutil.ignore_patterns('__pycache__','*.pyc','test','tests','idlelib','tkinter','ensurepip','site-packages','include','share'))
framework=resources/'Python.framework'
for p,d in [(framework/'Versions/Current','3.13'),(framework/'Python','Versions/Current/Python'),(framework/'Resources','Versions/Current/Resources')]:
    if not p.exists():p.symlink_to(d)

def dependencies(p):
    result=subprocess.run(['otool','-L',str(p)],capture_output=True,text=True)
    return [line.strip().split(' (')[0] for line in result.stdout.splitlines()[1:] if line.strip()]
# Only Mach-O binaries are modified, not stdlib or source files.
files=[]
for p in target.rglob('*'):
    if p.is_file() and not p.is_symlink() and (p.suffix in ('.so','.dylib') or p.name in ('Python','python3.13')):files.append(p)
for p in (resources/'python-vendor').rglob('*'):
    if p.is_file() and not p.is_symlink() and p.suffix in ('.so','.dylib'):files.append(p)
license_roots={SOURCE.parents[3]}
seen=set();deps=target/'Dependencies';deps.mkdir(exist_ok=True)
while files:
    p=files.pop()
    if p in seen:continue
    seen.add(p)
    for d in dependencies(p):
        if not d.startswith('/opt/homebrew'):continue
        source=Path(d)
        resolved=source.resolve()
        for parent in resolved.parents:
            if (parent/"INSTALL_RECEIPT.json").exists():license_roots.add(parent);break
        if 'Python.framework/Versions/3.13/Python' in d:dest=target/'Python'
        else:
            dest=deps/source.name
            if not dest.exists():shutil.copy2(source.resolve(),dest);files.append(dest)
        relative=os.path.relpath(dest,p.parent)
        subprocess.run(['install_name_tool','-change',d,'@loader_path/'+relative,str(p)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if p.suffix=='.dylib' or p.name=='Python':subprocess.run(['install_name_tool','-id','@loader_path/'+p.name,str(p)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['codesign','--force','--sign','-',str(p)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
remaining=[p for p in seen if any(d.startswith('/opt/homebrew') for d in dependencies(p))]
if remaining:raise RuntimeError('Unrelocated runtime dependency')
(resources/'python-runtime-path.txt').write_text('@bundled\n')
(resources/'python-runtime').write_text('''#!/bin/sh
resources="$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd)"
export PYTHONHOME="$resources/Python.framework/Versions/3.13"
exec "$PYTHONHOME/bin/python3.13" -S "$@"
''')
(resources/'python-runtime').chmod(0o755)
# Preserve Python and dependent libraries' license material in the local build.
licenses=resources/'RuntimeLicenses';licenses.mkdir(exist_ok=True)
# Read unchanged installed originals too: repeat builds see already-relocated copies.
for original in SOURCE.rglob('*'):
    if original.is_file() and not original.is_symlink() and (original.suffix in ('.so','.dylib') or original.name in ('Python','python3.13')):
        for dependency in dependencies(original):
            if dependency.startswith('/opt/homebrew'):
                for parent in Path(dependency).resolve().parents:
                    if (parent/'INSTALL_RECEIPT.json').exists():license_roots.add(parent);break
for cell in sorted(license_roots):
    for name in ['LICENSE','LICENSE.txt','LICENSE.md','COPYING','COPYING.LESSER']:
        if (cell/name).is_file():shutil.copy2(cell/name,licenses/(cell.name+'-'+name))
print('Bundled Python; runtime dependencies relocated and signed.')
