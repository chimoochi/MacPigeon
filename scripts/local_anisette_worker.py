"""Private stdio-only local Anisette provider; never receives account credentials."""
import contextlib
import io
import json
import logging
import os
from pathlib import Path
import resource
import signal
import sys
import subprocess
from datetime import datetime, timezone
from urllib.parse import urlsplit

logging.disable(logging.CRITICAL)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
os.umask(0o077)
# The development app packages dependencies beside this worker; no global install.
sys.path.insert(0, str(Path(__file__).resolve().parent))
vendor = Path(__file__).resolve().parent / 'python-vendor'
if vendor.is_dir():
    sys.path.insert(0, str(vendor))

from anisette import Anisette
from anisette._session import ProvisioningSession
from anisette._device import AnisetteDeviceConfig
import urllib3
from bundled_tls import create_context

counts = {'requests': 0}
def restricted_request(self, method, url, extra_headers, data=None, cache_key=None):
    parsed = urlsplit(url)
    host = parsed.hostname or ''
    if (parsed.scheme != 'https' or not (host == 'apple.com' or host.endswith('.apple.com'))
            or parsed.port not in (None, 443) or parsed.username or parsed.password):
        raise ValueError('Non-Apple provisioning URL rejected')
    counts['requests'] += 1
    response = self._http.request(method, url, body=data, headers=self._ProvisioningSession__headers | extra_headers,
                                  timeout=urllib3.Timeout(connect=10, read=20), retries=False,
                                  redirect=False, preload_content=False)
    try:
        if response.status != 200:
            raise RuntimeError('Provisioning HTTP status rejected')
        body = response.read(1_048_577)
        if len(body) > 1_048_576:
            raise ValueError('Provisioning response exceeds limit')
        # No request/response caches, private headers or server payloads written.
        return body
    finally:
        response.close()

ProvisioningSession._request = restricted_request

def emit(object):
    print(json.dumps(object, separators=(',', ':')), flush=True)

def main():
    args = sys.argv[1:]
    preflight = '--preflight' in args
    args = [arg for arg in args if arg != '--preflight']
    libs = Path(args[0]).resolve()
    state_dir = Path(args[1]).resolve()
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    state = state_dir / 'provisioning.bin'
    library_bundle = state_dir / 'libraries.bin'
    signal.alarm(120)
    with contextlib.redirect_stdout(io.StringIO()):
        def system_value(command):
            return subprocess.check_output(command, text=True, timeout=5).strip()
        model = system_value(['/usr/sbin/sysctl', '-n', 'hw.model'])
        version = system_value(['/usr/bin/sw_vers', '-productVersion'])
        build = system_value(['/usr/bin/sw_vers', '-buildVersion'])
        description = f'<{model}> <macOS;{version};{build}> <com.apple.AuthKit/1 (com.apple.akd/1.0)>'
        if not library_bundle.exists():
            Anisette.init(libs).save_libs(library_bundle)
            os.chmod(library_bundle, 0o600)
        if state.exists():
            ani = Anisette.load(state, library_bundle)
        else:
            config = AnisetteDeviceConfig.default()
            config.server_friendly_description = description
            ani = Anisette.init(libs, default_device_config=config)
        # Refresh version metadata while preserving the separate local identity.
        ani._ani_provider.device._server_friendly_description = description
        ani._ani_provider.device.write()
        # The VM stays local. Its provisioning traffic goes directly to Apple.
        ani._ani_provider.provisioning_session._http = urllib3.PoolManager(ssl_context=create_context())
        headers = ani.get_data()
        temporary = state.with_suffix('.new')
        with temporary.open('wb') as out:
            ani._ani_provider.save(out, include=['device', 'adi'])
        os.chmod(temporary, 0o600)
        temporary.replace(state)
    signal.alarm(0)
    def clean(h):
        h['X-Apple-I-Client-Time'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        h['X-Mme-Client-Info'] = h.pop('X-MMe-Client-Info')
        return h
    headers = clean(headers)
    if preflight:
        # Exercise repeated OTP generation without exposing headers or identifiers.
        with contextlib.redirect_stdout(io.StringIO()):
            second = clean(ani.get_data())
        emit({'local_emulator_provisioned': ani.is_provisioned, 'apple_provisioning_requests': counts['requests'],
              'required_headers_available': all(headers.get(k) for k in ('X-Apple-I-MD', 'X-Apple-I-MD-M', 'X-Mme-Device-Id')),
              'second_otp_available': bool(second['X-Apple-I-MD']),
              'account_login_called': False, 'ids_registration_called': False, 'send_called': False,
              'headers_printed': False, 'remote_anisette_service_used': False})
        return
    emit({'headers': headers})  # GUI helper pipe only; not a terminal command.
    for line in sys.stdin:
        if len(line) > 1024:
            return
        action = json.loads(line).get('action')
        if action == 'quit':
            return
        if action != 'headers':
            return
        signal.alarm(60)
        with contextlib.redirect_stdout(io.StringIO()):
            refreshed = clean(ani.get_data())
        signal.alarm(0)
        emit({'headers': refreshed})

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exception bodies can contain state; only its class is reported.
        emit({'error': type(error).__name__, 'local_provider_available': False})
        sys.exit(2)
