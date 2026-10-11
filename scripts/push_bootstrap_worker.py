"""One bounded app-owned Mac push activation experiment; no account or messages.

Uses the public legacy bootstrap signer shipped in pinned RustPush, like the
pinned Corten build recipe. Its expiry is recorded, not treated as current
production material. A new device key exists only in a disposable private
directory; no native Messages/phone keys or Keychain entries are accessed.
"""
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import urllib.request
import uuid
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bundled_tls import create_context

ENDPOINT = 'https://albert.apple.com/deviceservices/deviceActivation?device=MacOS'


def command(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=15)
    if result.returncode:
        raise ValueError('local_crypto_or_hardware_command')
    return result.stdout


def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)


def pinned_public(name):
    # Materials are staged by the build; never fetch signing material at runtime.
    resources = Path(__file__).resolve().parent
    manifest = json.loads((resources / 'push-bootstrap-manifest.json').read_text())
    if name not in manifest:
        raise ValueError('bootstrap_material_not_allowlisted')
    path = resources / 'PushBootstrapMaterial' / name
    data = path.read_bytes()
    if len(data) > 65536 or hashlib.sha256(data).hexdigest() != manifest[name]:
        raise ValueError('bootstrap_material_pin_mismatch')
    return data


def hardware():
    records = plistlib.loads(command(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice', '-a']))
    if len(records) != 1:
        raise ValueError('hardware_ambiguous')
    record = records[0]
    serial = record['IOPlatformSerialNumber']
    device = record['IOPlatformUUID']
    model = record.get('model')
    if isinstance(model, bytes):
        model = model.rstrip(b'\0').decode('ascii')
    version = command(['/usr/bin/sw_vers', '-productVersion']).decode().strip()
    build = command(['/usr/bin/sw_vers', '-buildVersion']).decode().strip()
    if not all(isinstance(v, str) and v and len(v)<100 for v in [serial,device,model,version,build]):
        raise ValueError('hardware_schema')
    uuid.UUID(device)
    return serial, device, model, version, build


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def https_opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects(),
        urllib.request.HTTPSHandler(context=create_context()))


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.recv(size-len(data))
        if not chunk:
            raise ValueError('push_connection_closed')
        data.extend(chunk)
    return bytes(data)


def frame(command_id, fields):
    body = b''.join(bytes([field])+struct.pack('>H',len(value))+value for field,value in fields)
    return bytes([command_id])+struct.pack('>I',len(body))+body


def connect_push(folder, own, device_cert, report):
    opener = https_opener()
    with opener.open('https://init.push.apple.com/bag',timeout=15) as response:
        data = response.read(1048577)
    if len(data)>1048576:
        raise ValueError('push_bag_size')
    bag = plistlib.loads(data)
    host = bag['APNSCourierHostname']
    if not isinstance(host,str) or not host.endswith('.push.apple.com') or '/' in host or ':' in host:
        raise ValueError('push_hostname_policy')
    count = bag['APNSCourierHostcount']
    if not isinstance(count,int) or not 1<count<1000:
        raise ValueError('push_bag_schema')
    # Native daemon has no part in this direct TLS connection. Verify Apple CA
    # roots and server hostname; offer only the simple frame wire protocol.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    for name in ['AppleIncRootCertificate','AppleRootCA-G2','AppleRootCA-G3']:
        root = pinned_public(f'certs/root/{name}.cer')
        context.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(root))
    context.set_alpn_protocols(['apns-security-v3'])
    certificate_der = command(['/usr/bin/openssl','x509','-in',str(folder/'issued.pem'),'-outform','DER'])
    nonce = b'\0'+struct.pack('>Q',int(time.time())*1000)+os.urandom(8)
    signature = b'\x01\x01'+command(['/usr/bin/openssl','dgst','-sha1','-sign',str(own)],nonce)
    request = frame(7,[(2,b'\x01'),(5,struct.pack('>I',0x41)),
        (12,certificate_der),(13,nonce),(14,signature),(16,struct.pack('>H',9))])
    report['push_connection_attempted'] = True
    with socket.create_connection(('1-'+host,5223),timeout=15) as plain:
        with context.wrap_socket(plain,server_hostname=host) as stream:
            stream.settimeout(15)
            report['push_tls_hostname_verified'] = True
            report['push_alpn'] = stream.selected_alpn_protocol()
            if report['push_alpn'] not in [None,'apns-security-v3']:
                raise ValueError('push_protocol_unsupported')
            stream.sendall(request)
            # No topics, message frames or notifications are requested.
            for _ in range(4):
                header = read_exact(stream,5)
                size = struct.unpack('>I',header[1:])[0]
                if size>65536:
                    raise ValueError('push_frame_size')
                body = read_exact(stream,size)
                if header[0]!=8:
                    continue
                fields = {}
                while body:
                    if len(body)<3:
                        raise ValueError('push_frame_fields')
                    field,size=body[0],struct.unpack('>H',body[1:3])[0]
                    if len(body)<size+3 or field in fields:
                        raise ValueError('push_frame_fields')
                    fields[field]=body[3:3+size]
                    body=body[3+size:]
                if len(fields.get(1,b''))!=1:
                    raise ValueError('push_status_schema')
                report['push_connect_status']=fields[1][0]
                report['app_owned_token_received']=len(fields.get(3,b''))==32
                report['push_handshake_success']=report['push_connect_status']==0 and report['app_owned_token_received']
                if not report['push_handshake_success']:
                    raise ValueError('push_authentication_rejected')
                return fields[3],certificate_der
            raise ValueError('push_response_missing')


def probe(live, connect=False, private_worker=False):
    report = {'experiment':'one app-owned Mac push activation with public legacy bootstrap',
        'fresh_key_bits':2048, 'native_identity_accessed':False,
        'apple_account_credentials_used':False, 'ids_registration_called':False,
        'push_connection_attempted':False, 'message_sent':False,
        'activation_requests':0, 'credentials_saved':False}
    stage = 'local_inputs'
    try:
        cert = pinned_public('certs/legacy-fairplay/fairplay.crt')
        signer = pinned_public('certs/legacy-fairplay/fairplay.pem')
        with tempfile.TemporaryDirectory(prefix='macpigeon-push-') as directory:
            folder = Path(directory)
            own = folder/'own-key.pem'
            boot = folder/'public-legacy-signing-key.der'
            chain = folder/'public-legacy-chain.der'
            private_write(boot, signer)
            private_write(chain, cert)
            dates = command(['/usr/bin/openssl','x509','-inform','DER','-in',str(chain),'-noout','-dates']).decode()
            expiry = next(line.split('=',1)[1] for line in dates.splitlines() if line.startswith('notAfter='))
            report['public_legacy_certificate_not_after'] = expiry
            report['public_legacy_certificate_expired'] = datetime.datetime.strptime(expiry,'%b %d %H:%M:%S %Y %Z').replace(tzinfo=datetime.timezone.utc) < datetime.datetime.now(datetime.timezone.utc)
            private_write(own, command(['/usr/bin/openssl','genrsa','2048']))
            csr = command(['/usr/bin/openssl','req','-new','-sha1','-key',str(own),'-subj','/CN=Client Push Certificate'])
            command(['/usr/bin/openssl','req','-verify','-noout'],csr)
            if live:
                serial, device, model, version, build = hardware()
            else:
                serial, device, model, version, build = 'SYNTHETIC',str(uuid.uuid4()),'Mac16,1','27.0.1','26A434'
            activation = {'ActivationRandomness':str(uuid.uuid4()).upper(),
                'ActivationState':'Unactivated','BuildVersion':build,
                'DeviceCertRequest':csr,'DeviceClass':'MacOS','ProductType':model,
                'ProductVersion':version,'SerialNumber':serial,'UniqueDeviceID':device.upper()}
            body = plistlib.dumps(activation, fmt=plistlib.FMT_XML, sort_keys=False)
            signature = command(['/usr/bin/openssl','dgst','-sha1','-sign',str(boot),'-keyform','DER'],body)
            public = command(['/usr/bin/openssl','pkey','-inform','DER','-in',str(boot),'-pubout'])
            private_write(folder/'bootstrap-public.pem',public)
            private_write(folder/'signature.bin',signature)
            command(['/usr/bin/openssl','dgst','-sha1','-verify',str(folder/'bootstrap-public.pem'),'-signature',str(folder/'signature.bin')],body)
            request = {'ActivationInfoComplete':True,'ActivationInfoXML':body,
                'FairPlayCertChain':cert,'FairPlaySignature':signature}
            report['own_csr_and_bootstrap_signature_verified'] = True
            if not live:
                report['status'] = 'offline crypto/request check passed'
                return report
            stage = 'activation_http'
            from urllib.parse import urlencode
            encoded = urlencode({'activation-info':plistlib.dumps(request,fmt=plistlib.FMT_XML,sort_keys=False).decode()}).encode()
            request = urllib.request.Request(ENDPOINT, data=encoded, headers={
                'User-Agent':'ApplePushService/4.0 com.apple.iCloudHelper/282',
                'Content-Type':'application/x-www-form-urlencoded'})
            opener = https_opener()
            report['activation_requests'] = 1
            try:
                response = opener.open(request,timeout=25)
            except urllib.error.HTTPError as error:
                report['http_status'] = error.code
                report['status'] = 'Apple activation HTTP rejection'
                return report
            with response:
                report['http_status'] = response.status
                response_body = response.read(1048577)
            if len(response_body)>1048576:
                raise ValueError('activation_response_size')
            stage = 'activation_response'
            # Only parse the protocol section, never echo Apple's response body.
            start, end = response_body.find(b'<Protocol>'), response_body.find(b'</Protocol>')
            if start<0 or end<start:
                report['status'] = 'No device certificate protocol in Apple response'
                return report
            protocol = plistlib.loads(response_body[start+10:end])
            device_cert = protocol.get('device-activation',{}).get('activation-record',{}).get('DeviceCertificate')
            if not isinstance(device_cert,bytes) or len(device_cert)>65536:
                report['status'] = 'No device certificate issued'
                return report
            private_write(folder/'issued.pem',device_cert)
            cert_public = command(['/usr/bin/openssl','x509','-in',str(folder/'issued.pem'),'-pubkey','-noout'])
            own_public = command(['/usr/bin/openssl','pkey','-in',str(own),'-pubout'])
            if cert_public!=own_public:
                raise ValueError('device_certificate_key_mismatch')
            command(['/usr/bin/openssl','x509','-in',str(folder/'issued.pem'),'-checkend','0','-noout'])
            report['device_certificate_key_matches'] = True
            report['status'] = 'Apple issued device certificate for fresh app-owned key'
            if connect:
                stage = 'push_handshake'
                token, certificate_der = connect_push(folder,own,device_cert,report)
                if private_worker:
                    report['_private_push_state'] = {
                        'key_pem':base64.b64encode(own.read_bytes()).decode(),
                        'certificate_der':base64.b64encode(certificate_der).decode(),
                        'token':base64.b64encode(token).decode()}
    except Exception as error:
        report['status'] = 'probe failed'
        report['failure_stage'] = stage
        report['error_type'] = type(error).__name__
    return report


if __name__ == '__main__':
    import sys
    if sys.argv[1:] != ['--private-worker']:
        raise SystemExit('This helper is used only by the app through a private pipe.')
    request = sys.stdin.buffer.readline(4097)
    if len(request) > 4096 or json.loads(request).get('action') != 'prepare_push':
        raise SystemExit(2)
    print(json.dumps(probe(True, True, True)))
