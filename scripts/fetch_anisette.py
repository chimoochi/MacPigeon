"""Cache the required Anisette libraries directly from Apple's Android APK."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, build_opener
import zipfile

APPLE_MUSIC_URL = 'https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk'
# Pin the libraries, since Apple's APK URL can change independently of this repo.
LIBRARIES = {
    'lib/arm64-v8a/libCoreADI.so': '9d5b557cf3faf88c34c394ab2cd7fc1a3b4acf3aed51f28cd0bc093858107c22',
    'lib/arm64-v8a/libstoreservicescore.so': 'bd335e6963ba5ae2f5babca613435ad56d2660a9aee37df35f876c458d105ce4',
}
MAX_APK_BYTES = 512 * 1024 * 1024
MAX_LIBRARY_BYTES = 16 * 1024 * 1024


class AppleRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urlsplit(newurl)
        host = url.hostname or ''
        if (url.scheme != 'https' or url.port not in (None, 443)
                or url.username or url.password
                or not (host == 'mzstatic.com' or host.endswith('.mzstatic.com'))):
            raise ValueError('Download redirected outside Apple HTTPS CDN')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def read_libraries(archive):
    libraries = {}
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        for name, expected in LIBRARIES.items():
            if names.count(name) != 1:
                raise ValueError(f'Expected exactly one archive entry: {name}')
            if source.getinfo(name).file_size > MAX_LIBRARY_BYTES:
                raise ValueError(f'Library exceeds size limit: {name}')
            with source.open(name) as library:
                data = library.read(MAX_LIBRARY_BYTES + 1)
            if len(data) > MAX_LIBRARY_BYTES or hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f'Unsupported library SHA-256: {name}; see scripts/fetch_anisette.py')
            libraries[name] = data
    return libraries


def prepare(destination):
    if destination.exists():
        read_libraries(destination)
        print(f'Using verified Anisette libraries: {destination}')
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='macpigeon-anisette-', dir=destination.parent) as temporary:
        apk = Path(temporary) / 'applemusic.apk'
        print('Downloading Apple Music authentication libraries from Apple...', flush=True)
        with build_opener(AppleRedirects()).open(APPLE_MUSIC_URL, timeout=30) as response, apk.open('wb') as output:
            if response.status != 200:
                raise ValueError(f'Apple download returned HTTP {response.status}')
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_APK_BYTES:
                    raise ValueError('Apple Music APK exceeds size limit')
                output.write(chunk)
        libraries = read_libraries(apk)
        bundle = Path(temporary) / 'libraries.zip'
        with zipfile.ZipFile(bundle, 'w', compression=zipfile.ZIP_DEFLATED) as output:
            for name, data in libraries.items():
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                output.writestr(entry, data)
        os.replace(bundle, destination)
    print(f'Cached verified Anisette libraries: {destination}')


if __name__ == '__main__':
    try:
        prepare(Path(sys.argv[1]).expanduser().resolve())
    except Exception as error:
        print(f'Cannot prepare Anisette libraries: {error}', file=sys.stderr)
        sys.exit(1)
