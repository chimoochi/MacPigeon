"""A launcher upgrade replaces the host while preserving user-supplied assets."""
import hashlib,json,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from install_local_ipa import refresh_host

class HostUpgrade(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.resources=self.root/'resources';self.app=self.root/'Installed/Game.app'
        for base,host in [(self.resources/'RendererHostTemplate.app',b'new host'),(self.app,b'old host')]:
            for name,data in [('Contents/MacOS/OriginalHost',host),('Contents/Info.plist',b'host metadata'),('Contents/Resources/macpigeon-game-registry.json',b'{}')]:
                p=base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        self.marker=self.app/'Contents/Resources/local-import.json'
        self.marker.write_text(json.dumps(dict(host_sha256=hashlib.sha256(b'old host').hexdigest(),source_sha256='supplied game',original_ipa_unchanged=True)))
        self.asset=self.app/'Contents/Resources/ExtensionProbe.bundle/ExtensionProbe';self.asset.parent.mkdir();self.asset.write_bytes(b'imported game binary')

    def test_upgrade_preserves_game_and_previous_install(self):
        with patch('install_local_ipa.subprocess.run') as signing:
            self.assertEqual(refresh_host(self.resources,self.app),dict(ok=True,updated=True))
            self.assertEqual(signing.call_count,3)
            self.assertEqual(refresh_host(self.resources,self.app),dict(ok=True,updated=False))
            self.assertEqual(signing.call_count,3)
        self.assertEqual(self.asset.read_bytes(),b'imported game binary')
        self.assertEqual((self.app/'Contents/MacOS/OriginalHost').read_bytes(),b'new host')
        metadata=json.loads(self.marker.read_text());self.assertEqual(metadata['source_sha256'],'supplied game')
        self.assertEqual(metadata['host_sha256'],hashlib.sha256(b'new host').hexdigest())
        self.assertEqual((self.app.with_name('Game Previous.app')/'Contents/MacOS/OriginalHost').read_bytes(),b'old host')

    def test_failed_signature_keeps_installed_host(self):
        with patch('install_local_ipa.subprocess.run',side_effect=[None,subprocess.CalledProcessError(1,'codesign')]):
            with self.assertRaises(subprocess.CalledProcessError):refresh_host(self.resources,self.app)
        self.assertEqual((self.app/'Contents/MacOS/OriginalHost').read_bytes(),b'old host')
        self.assertEqual(self.asset.read_bytes(),b'imported game binary')
        self.assertFalse(self.app.with_name('Game Previous.app').exists())

    def test_modified_host_is_not_overwritten(self):
        (self.app/'Contents/MacOS/OriginalHost').write_bytes(b'modified host')
        with patch('install_local_ipa.subprocess.run',side_effect=subprocess.CalledProcessError(1,'codesign')):
            with self.assertRaises(subprocess.CalledProcessError):refresh_host(self.resources,self.app)
        self.assertEqual((self.app/'Contents/MacOS/OriginalHost').read_bytes(),b'modified host')

    def test_signed_executable_does_not_trigger_another_upgrade(self):
        def sign(command,**kwargs):
            if '--force' in command:
                p=Path(command[-1])/'Contents/MacOS/OriginalHost';p.write_bytes(p.read_bytes()+b' signing changes')
        with patch('install_local_ipa.subprocess.run',side_effect=sign) as signing:
            self.assertTrue(refresh_host(self.resources,self.app)['updated'])
            self.assertFalse(refresh_host(self.resources,self.app)['updated'])
            self.assertEqual(signing.call_count,3)

if __name__=='__main__':unittest.main()
