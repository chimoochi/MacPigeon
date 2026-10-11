"""Stage pinned public backend dependencies in the ignored local workspace.

Does not build/run upstream demos, authenticate accounts, or register senders.
"""
import configparser
import io
import json
from pathlib import Path
import tarfile
import urllib.request

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE/'build/deps/rustpush'
PIN = 'cb2361c2a750ffa2047c1a64eda44c8fb8364218'


def fetch_archive(repo, pin, destination):
    data = urllib.request.urlopen(f'https://codeload.github.com/{repo}/tar.gz/{pin}',timeout=45).read(100*1024*1024+1)
    if len(data)>100*1024*1024:
        raise ValueError('Source archive size limit')
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
        for member in archive.getmembers():
            parts=Path(member.name).parts[1:]
            if not parts:
                continue
            if '..' in parts or member.islnk():
                raise ValueError('Unsupported source archive entry')
            path=destination/Path(*parts)
            if not path.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Source path escapes dependency')
            if member.issym():
                target=(path.parent/member.linkname).resolve()
                if Path(member.linkname).is_absolute() or not target.is_relative_to(destination.resolve()):
                    raise ValueError('Source symlink escapes dependency')
                path.parent.mkdir(parents=True,exist_ok=True)
                if path.is_symlink():
                    path.unlink()
                if not path.exists():
                    path.symlink_to(member.linkname)
            elif member.isdir():
                path.mkdir(parents=True,exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(archive.extractfile(member).read())


def stage(repo,pin,destination,manifest):
    marker=destination/'.macpigeon-source-pin.json'
    if not marker.exists():
        fetch_archive(repo,pin,destination)
        marker.write_text(json.dumps({'repo':repo,'pin':pin})+'\n')
    elif json.loads(marker.read_text())!={'repo':repo,'pin':pin}:
        raise ValueError('Existing source pin mismatch')
    manifest.append({'repo':repo,'pin':pin,'path':str(destination.relative_to(BASE))})
    gitmodules=destination/'.gitmodules'
    if not gitmodules.exists():
        return
    config=configparser.ConfigParser()
    config.read(gitmodules)
    tree_cache = destination / '.macpigeon-submodule-tree.json'
    if tree_cache.exists():
        tree = json.loads(tree_cache.read_text())
    else:
        data=urllib.request.urlopen(f'https://api.github.com/repos/{repo}/git/trees/{pin}?recursive=1',timeout=30).read()
        tree=json.loads(data)['tree']
        tree_cache.write_text(json.dumps(tree))
    gitlinks={x['path']:x['sha'] for x in tree if x['type']=='commit'}
    for section in config.sections():
        path=config[section]['path']
        url=config[section]['url']
        if url.startswith('git@github.com:'):
            subrepo=url[len('git@github.com:'):]
        elif url.startswith('https://github.com/'):
            subrepo=url[len('https://github.com/'):]
        else:
            raise ValueError('Unreviewed dependency source')
        subrepo=subrepo.removesuffix('.git')
        if '..' in Path(path).parts or Path(path).is_absolute():
            raise ValueError('Submodule path')
        stage(subrepo,gitlinks[path],destination/path,manifest)


if __name__=='__main__':
    manifest=[]
    stage('OpenBubbles/rustpush',PIN,ROOT,manifest)
    (BASE/'build/deps/source-pins.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Pinned public sources staged: {len(manifest)} repositories; no code executed.')
