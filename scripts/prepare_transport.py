"""Apply explicit local build-only changes to isolated pinned backend source."""
from pathlib import Path
import re
import shutil

BASE=Path(__file__).resolve().parents[1]
ROOT=BASE/'build/deps/rustpush'


def write_if_changed(path, text):
    if path.read_text() != text:
        path.write_text(text)


def prepare():
    activation=ROOT/'src/activation.rs'
    names=re.findall(r'include_cert!\("(\d+)"\)',activation.read_text())
    if len(names)!=10:
        raise ValueError('Pinned activation shape changed')
    # Same public legacy substitution as the pinned Corten build recipe. Our
    # runtime imports its own already verified push state instead of activating.
    target=ROOT/'certs/fairplay'
    target.mkdir(exist_ok=True)
    for name in names:
        for suffix in ['crt','pem']:
            path=target/f'{name}.{suffix}'
            shutil.copy2(ROOT/f'certs/legacy-fairplay/fairplay.{suffix}',path)
            path.chmod(0o600)
    lib=ROOT/'src/lib.rs'
    text=re.sub(r'(?m)^(?:pub )*use activation::ActivationInfo;',
        'pub use activation::ActivationInfo;',lib.read_text())
    write_if_changed(lib,text)
    auth=ROOT/'third_party/apple-private-apis/omnisette/Cargo.toml'
    text=auth.read_text()
    text='\n'.join(line for line in text.splitlines() if not line.startswith('android-loader ='))+'\n'
    write_if_changed(auth,text)
    # All diagnostic argument evaluation is compiled out in this prototype.
    manifest=ROOT/'Cargo.toml'
    text=manifest.read_text().replace('log = "0.4.20"','log = { version = "0.4.20", features = ["max_level_off", "release_max_level_off"] }')
    write_if_changed(manifest,text)
    # The pinned audio module uses AtomicU64::update, unavailable in installed
    # Rust1.92. Always-Some fetch_update has the same CAS/retry behavior here.
    audio=ROOT/'src/avconference.rs'
    text=audio.read_text()
    for field in ['short_q13_lag','long_q13_lag']:
        marker=f'self.stats.{field}.update('
        if marker not in text:
            continue
        begin=text.index(marker)
        end=text.index('});',begin)+3
        block=text[begin:end]
        block=block.replace('.update(','.fetch_update(',1)
        block=block.replace('|i| {','|i| { Some({',1)
        block=block[:-3]+'}) }).expect("always-Some atomic update");'
        text=text[:begin]+block+text[end:]
    write_if_changed(audio,text)
    # Prototype worker uses existing compiled dependencies, never upstream demos.
    text=manifest.read_text()
    if 'name = "macpigeon-transport"' not in text:
        text+='\n[[bin]]\nname = "macpigeon-transport"\npath = "../../../source/transport/main.rs"\n'
    write_if_changed(manifest,text)
    user=ROOT/'src/ids/user.rs'
    text=user.read_text()
    original="pub async fn register(config: &dyn OSConfig, aps: &APSState, id_services: &[&'static IDSService], users: &mut [IDSUser], identity: &IDSNGMIdentity) -> Result<(), PushError> {"
    if 'pub async fn register_scoped(' not in text:
        text=text.replace(original,original+'\n    register_scoped(config, aps, id_services, users, identity, None).await\n}\n\n'+original.replace('register(', 'register_scoped(').replace('identity: &IDSNGMIdentity)', 'identity: &IDSNGMIdentity, selected_handle: Option<&str>)'))
        text=text.replace('possible_handles.insert(user.user_id.clone(), user.get_possible_handles(aps).await?);',"""let mut handles = user.get_possible_handles(aps).await?;
        if let Some(selected)=selected_handle {
            handles.retain(|h|h==selected);
            if handles.len()!=1 {return Err(PushError::RegisterFailed(IDSError(6005)));}
        }
        possible_handles.insert(user.user_id.clone(), handles);""")
    write_if_changed(user,text)
    text=lib.read_text().replace('IDSUser, register, IDSUserIdentity','IDSUser, register, register_scoped, IDSUserIdentity')
    write_if_changed(lib,text)
    util=ROOT/'src/util.rs'
    write_if_changed(util,util.read_text().replace('http://init-p01st.push.apple.com/bag','https://init.push.apple.com/bag'))
    # Refreshes must keep the same phone-only registration scope.
    text=lib.read_text().replace('pub use ids::user::{IDSUser, register, register_scoped, IDSUserIdentity','pub use ids::user::{IDSService, IDSUser, register, register_scoped, IDSUserIdentity').replace('IdentityManager, KeyCache};','IdentityManager, KeyCache, SendResult};')
    if 'fn get_registration_handle(' not in text:
        text=text.replace('pub trait OSConfig: Sync + Send {','pub trait OSConfig: Sync + Send {\n    fn get_registration_handle(&self) -> Option<String> { None }')
    write_if_changed(lib,text)
    text=user.read_text().replace('register_scoped(config, aps, id_services, users, identity, None).await', 'register_scoped(config, aps, id_services, users, identity, config.get_registration_handle().as_deref()).await')
    write_if_changed(user,text)
    im=ROOT/'src/imessage/aps_client.rs'
    text=im.read_text().replace('conn.request_topics(&["com.apple.private.alloy.sms", "com.apple.madrid"])','conn.request_topics(&["com.apple.madrid"])')
    write_if_changed(im,text)
    aps=ROOT/'src/aps.rs'
    text=aps.read_text()
    if 'pub async fn probe_socket_tls(' not in text:
        text+='\npub async fn probe_socket_tls() -> Result<(), PushError> {\n    let (stream, _, _) = open_socket().await?;\n    drop(stream);\n    Ok(())\n}\n'
    write_if_changed(aps,text)
    write_if_changed(lib,lib.read_text().replace('pub use aps::{APSConnectionResource,','pub use aps::{probe_socket_tls, APSConnectionResource,'))
    # The validated HTTPS APNS bag is a direct dictionary, while IDS has a
    # binary `bag` wrapper. Preserve both documented wire shapes.
    text=util.read_text()
    old='        let parsed: BagBody = plist::from_bytes(&content.bytes().await?)?;\n        let dict: Dictionary = plist::from_bytes(parsed.bag.as_ref())?;'
    new='        let bytes=content.bytes().await?;\n        let dict: Dictionary = if url==APNS_BAG {\n            plist::from_bytes(&bytes)?\n        } else {\n            let parsed: BagBody = plist::from_bytes(&bytes)?;\n            plist::from_bytes(parsed.bag.as_ref())?\n        };'
    write_if_changed(util,text.replace(old,new))
    print('Isolated backend build prepared; public legacy stubs only, no activation or account call.')


if __name__=='__main__':
    prepare()
