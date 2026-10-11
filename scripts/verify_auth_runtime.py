"""Check the shipped local-auth runtime offline, away from the build directory."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from fetch_anisette import read_libraries


def verify(app):
    resources = app / 'Contents/Resources'
    read_libraries(resources / 'apple-music-arm64-libs.zip')
    with tempfile.TemporaryDirectory(prefix='MacPigeon portable auth ') as temporary:
        moved = Path(temporary) / 'MacPigeon.app'
        shutil.copytree(app, moved, symlinks=True)
        resources = moved / 'Contents/Resources'
        code = '''
import runpy, ssl, sys
from pathlib import Path
resources = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(resources))
ssl.SSLContext.load_default_certs = lambda *args, **kwargs: None
from bundled_tls import create_context
import certifi
from anisette import Anisette
context = create_context()
assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
assert context.cert_store_stats()['x509_ca'] > 100
assert resources in Path(certifi.where()).resolve().parents
for name in ('local_anisette_worker.py', 'push_bootstrap_worker.py'):
    worker = runpy.run_path(str(resources / name), run_name='packaged_import_check')
    if name == 'push_bootstrap_worker.py':
        import urllib.request
        handler = next(h for h in worker['https_opener']().handlers
                       if isinstance(h, urllib.request.HTTPSHandler))
        assert handler._context.verify_mode == ssl.CERT_REQUIRED
        assert handler._context.check_hostname
        assert handler._context.cert_store_stats()['x509_ca'] > 100
ani = Anisette.init(resources / 'apple-music-arm64-libs.zip')
assert not ani.is_provisioned
ani.save_libs(Path(sys.argv[2]) / 'libraries.bin')
print('Portable local-auth runtime, libraries and bundled TLS trust verified offline.')
'''
        subprocess.run([str(resources / 'python-runtime'), '-I', '-B', '-c', code,
                        str(resources), temporary], env={'LANG': 'en_US.UTF-8'},
                       check=True, timeout=60)


if __name__ == '__main__':
    verify(Path(sys.argv[1]).resolve())
