//! Experimental local delivery worker. JSON goes only to the app's private pipe.
//! No system/phone credentials; no logger; no automatic account registration.
use sha2::Digest;
use std::{collections::HashMap,io::{self,BufRead,Write},process::Command,sync::{Arc,Mutex,RwLock},time::{Duration,SystemTime}};
use async_trait::async_trait;
use base64::{Engine,engine::general_purpose::STANDARD};
use openssl::pkey::PKey;
use plist::{Value,Dictionary};
use serde::{Serialize,Deserialize};
use serde_json::{json,Value as Json};
use keystore::{software::{SoftwareKeystore,SoftwareKeystoreState,NoEncryptor},init_keystore,RsaKey,KeystoreAccessRules,KeystoreDigest,KeystorePadding};
use rustpush::{APSState,IDSUser,IDSNGMIdentity,OSConfig,ActivationInfo,DebugMeta,RegisterMeta,PushError,MADRID_SERVICE};
type Result<T> = std::result::Result<T,&'static str>;
#[derive(Serialize,Deserialize)]
struct Saved {version:u32,store:SoftwareKeystoreState,push:APSState,user:IDSUser,identity:IDSNGMIdentity,phone:String}
fn bin<T:Serialize>(value:&T)->Result<Vec<u8>> {let mut b=vec![];plist::to_writer_binary(&mut b,value).map_err(|_|"state_encoding")?;Ok(b)}
fn b64(v:&Json,key:&str)->Result<Vec<u8>> {STANDARD.decode(v[key].as_str().ok_or("input_schema")?).map_err(|_|"input_encoding")}
fn emit(v:Json) {let mut o=io::stdout().lock();let _=serde_json::to_writer(&mut o,&v);let _=o.write_all(b"\n");let _=o.flush();}
fn copy_store(s:&SoftwareKeystoreState)->SoftwareKeystoreState {plist::from_bytes(&bin(s).expect("state encoding")).expect("state decoding")}
fn store(state:SoftwareKeystoreState)->Arc<Mutex<SoftwareKeystoreState>> {
    let snapshot=Arc::new(Mutex::new(copy_store(&state)));let handle=snapshot.clone();
    init_keystore(SoftwareKeystore{state:RwLock::new(state),encryptor:NoEncryptor,
        update_state:Box::new(move|s|{*handle.lock().unwrap()=copy_store(s);})});snapshot
}
fn import(v:&Json,key:&str,alias:&str)->Result<()> {
    let key=PKey::private_key_from_der(&b64(v,key)?).map_err(|_|"key_encoding")?;
    if key.bits()!=2048 {return Err("key_bits");}
    RsaKey::import(alias,2048,&key.rsa().map_err(|_|"key_type")?.private_key_to_der().map_err(|_|"key_encoding")?,KeystoreAccessRules {
        signature_padding:vec![KeystorePadding::PKCS1],digests:vec![KeystoreDigest::Sha1,KeystoreDigest::Sha256],can_sign:true,..Default::default()
    }).map_err(|_|"key_import")?;Ok(())
}
fn dict(entries:impl IntoIterator<Item=(&'static str,Value)>)->Value {Value::Dictionary(entries.into_iter().map(|(k,v)|(k.to_string(),v)).collect())}
fn pair(v:&Json,cert:&str,alias:&str)->Result<Value> {Ok(dict([("cert",Value::Data(b64(v,cert)?)),("private",Value::String(alias.into()))]))}
fn prepare(v:&Json)->Result<Json> {
    let snapshot=store(SoftwareKeystoreState::default());
    import(v,"auth_key_der","macpigeon:auth")?;import(v,"push_key_der","macpigeon:push")?;
    let token=b64(v,"push_token")?;if token.len()!=32 {return Err("push_token");}
    let push:APSState=plist::from_value(&dict([("token",Value::Data(token)),("keypair",pair(v,"push_cert_der","macpigeon:push")?)])).map_err(|_|"push_schema")?;
    let user:IDSUser=plist::from_value(&dict([
        ("auth_keypair",pair(v,"auth_cert_der","macpigeon:auth")?),
        ("user_id",Value::String(v["profile"].as_str().ok_or("profile_schema")?.into())),
        ("user_type",Value::String("Apple".into())),("protocol_version",Value::Integer(1660.into()))
    ])).map_err(|_|"user_schema")?;
    let phone=v["phone"].as_str().filter(|s|s.starts_with("tel:+")&&s[5..].bytes().all(|b|b.is_ascii_digit())).ok_or("phone_schema")?.to_owned();
    let identity=IDSNGMIdentity::new().map_err(|_|"identity_create")?;
    let saved=Saved{version:1,store:copy_store(&snapshot.lock().unwrap()),push,user,identity,phone};
    // Independently decode the complete binary snapshot before handing it to Keychain.
    let bytes=bin(&saved)?;let restored:Saved=plist::from_bytes(&bytes).map_err(|_|"state_roundtrip")?;
    if restored.version!=1||restored.phone!=saved.phone {return Err("state_roundtrip");}
    Ok(json!({"ok":true,"stage":"identity_prepared","state":STANDARD.encode(bytes),"ids_registration_called":false,"send_called":false}))
}
struct Config {version:String,build:String,model:String,serial:String,uuid:String,validation:Vec<u8>,phone:String}
impl Config {
    fn read(validation:Vec<u8>)->Result<Self> {
        let hardware=Command::new("/usr/sbin/ioreg").args(["-rd1","-c","IOPlatformExpertDevice","-a"]).output().map_err(|_|"hardware")?;
        let root:Value=plist::from_bytes(&hardware.stdout).map_err(|_|"hardware")?;
        let d=root.as_array().and_then(|a|a.first()).and_then(Value::as_dictionary).ok_or("hardware")?;
        let string=|key:&str|->Result<String>{d.get(key).and_then(Value::as_string).map(str::to_owned).ok_or("hardware")};
        let model=d.get("model").and_then(Value::as_data).and_then(|b|std::str::from_utf8(b).ok()).ok_or("hardware")?.trim_end_matches('\0').to_owned();
        let sw=|arg:&str|->Result<String>{let o=Command::new("/usr/bin/sw_vers").arg(arg).output().map_err(|_|"software")?;String::from_utf8(o.stdout).map(|s|s.trim().into()).map_err(|_|"software")};
        Ok(Self{version:sw("-productVersion")?,build:sw("-buildVersion")?,model,serial:string("IOPlatformSerialNumber")?,uuid:string("IOPlatformUUID")?,validation,phone:String::new()})
    }
}
#[async_trait]
impl OSConfig for Config {
 fn get_registration_handle(&self)->Option<String> {Some(self.phone.clone())}
 fn build_activation_info(&self,csr:Vec<u8>)->ActivationInfo {ActivationInfo{activation_randomness:uuid::Uuid::new_v4().to_string(),activation_state:"Unactivated",build_version:self.build.clone(),device_cert_request:csr.into(),device_class:"MacOS".into(),product_type:self.model.clone(),product_version:self.version.clone(),serial_number:self.serial.clone(),unique_device_id:self.uuid.clone()}}
 fn get_activation_device(&self)->String {"MacOS".into()}
 async fn generate_validation_data(&self)->std::result::Result<Vec<u8>,PushError> {Ok(self.validation.clone())}
 fn get_protocol_version(&self)->u32 {1660}
 fn get_register_meta(&self)->RegisterMeta {RegisterMeta{hardware_version:self.model.clone(),os_version:format!("macOS,{},{}",self.version,self.build),software_version:self.build.clone()}}
 fn get_normal_ua(&self,item:&str)->String {format!("{item} [macOS,{},{},{}]",self.version,self.build,self.model)}
 fn get_mme_clientinfo(&self,item:&str)->String {format!("<{}> <macOS;{};{}> <{item}>",self.model,self.version,self.build)}
 fn get_version_ua(&self)->String {format!("[macOS,{},{},{}]",self.version,self.build,self.model)}
 fn get_device_name(&self)->String {"MacPigeon Lab".into()}
 fn get_device_uuid(&self)->String {self.uuid.clone()}
 fn get_private_data(&self)->Dictionary {
    let mut d=Dictionary::new();for k in ["ap","gt","m","p","s","t"] {d.insert(k.into(),Value::String("0".into()));}
    for k in ["h","v"] {d.insert(k.into(),Value::String("1".into()));}
    d.insert("dt".into(),Value::Integer(1.into()));
    d.insert("d".into(),Value::String(format!("{:.6}",(SystemTime::UNIX_EPOCH+Duration::from_secs(978307200)).elapsed().unwrap().as_secs_f64())));
    for (k,v) in [("pb",self.build.clone()),("pn","macOS".into()),("pv",self.version.clone()),("u",self.uuid.to_uppercase())] {d.insert(k.into(),Value::String(v));}d
 }
 fn get_debug_meta(&self)->DebugMeta {DebugMeta{user_version:self.version.clone(),hardware_version:self.model.clone(),serial_number:self.serial.clone()}}
 fn get_login_url(&self)->&'static str {"https://setup.icloud.com/setup/signin/v2/login"}
 fn get_serial_number(&self)->String {self.serial.clone()}
 fn get_gsa_hardware_headers(&self)->HashMap<String,String> {HashMap::new()}
 fn get_aoskit_version(&self)->String {"282".into()}
 fn get_udid(&self)->String {self.uuid.clone()}
}
async fn register(v:&Json)->Result<Json> {
    // Parent must receive a positive GUI Keychain acknowledgement first.
    if v["keychain_saved"]!=true {return Err("keychain_required");}
    let mut saved:Saved=plist::from_bytes(&b64(v,"state")?).map_err(|_|"state_schema")?;
    if saved.version!=1 {return Err("state_version");}
    let snapshot=store(copy_store(&saved.store));
    if saved.user.registration.contains_key("com.apple.madrid") {return Ok(json!({"ok":true,"stage":"already_registered","state":v["state"],"phone_number_authorized":true,"ids_registration_called":false,"send_called":false}));}
    let mut config=Config::read(b64(v,"validation")?)?;config.phone=saved.phone.clone();
    let result=rustpush::register_scoped(&config,&saved.push,&[&MADRID_SERVICE],std::slice::from_mut(&mut saved.user),&saved.identity,Some(&saved.phone)).await;
    saved.store=copy_store(&snapshot.lock().unwrap());
    let phone=saved.user.registration.get("com.apple.madrid").map(|r|r.handles.len()==1&&r.handles[0]==saved.phone).unwrap_or(false);
    let (stage,code)=match result {Ok(())=>("delivery_registered",None),Err(PushError::RegisterFailed(e))=>("registration_rejected",Some(e.0)),Err(PushError::CustomerMessage(_))=>("account_security_step",None),Err(_)=>("registration_failed",None)};
    Ok(json!({"ok":stage=="delivery_registered"&&phone,"stage":stage,"numeric_code":code,"state":STANDARD.encode(bin(&saved)?),"phone_number_authorized":phone,"ids_registration_called":true,"send_called":false}))
}
fn connection_error(error:&PushError)->(&'static str,Option<i64>) {
    match error {
        PushError::APSConnectError(n)=>("push_handshake_status",Some(*n as i64)),
        PushError::IoError(e)=>("push_socket_io",e.raw_os_error().map(i64::from)),
        PushError::TLSError(_)=>("push_tls",None),
        PushError::RequestError(e)=>(if e.is_timeout(){"push_bag_timeout"}else if e.is_connect(){"push_bag_connect"}else{"push_bag_http"},e.status().map(|s|s.as_u16() as i64)),
        PushError::ResourceTimeout=>("push_handshake_timeout",None),
        PushError::KeystoreError(_)=>("push_keystore",None),
        PushError::PlistError(_)=>("push_bag_schema",None),
        PushError::BagKeyNotFound=>("push_bag_key",None),
        _=>("push_connection_failed",None),
    }
}
async fn probe_public_tls()->Result<Json> {
    let result=tokio::time::timeout(Duration::from_secs(25),rustpush::probe_socket_tls()).await;
    let (stage,code)=match result {Ok(Ok(()))=>("public_push_tls_ready",None),Ok(Err(e))=>connection_error(&e),Err(_)=>("public_push_tls_timeout",None)};
    Ok(json!({"ok":stage=="public_push_tls_ready","stage":stage,"numeric_code":code,"account_data_used":false,"push_credentials_used":false,"send_called":false}))
}
async fn send_turn(v:&Json)->Result<Json> {
    if v["keychain_saved"]!=true||v["one_test_send_authorized"]!=true {return Err("send_authorization_required");}
    let mut saved:Saved=plist::from_bytes(&b64(v,"state")?).map_err(|_|"state_schema")?;
    let phone_ok=saved.user.registration.get("com.apple.madrid").map(|r|r.handles==vec![saved.phone.clone()]).unwrap_or(false);
    if !phone_ok {return Err("registered_phone_required");}
    let recipient=v["recipient"].as_str().filter(|s|s.starts_with("tel:+")&&s[5..].bytes().all(|b|b.is_ascii_digit())).ok_or("recipient_schema")?.to_owned();
    let wire=b64(v,"wire")?;if wire.len()>262144 {return Err("wire_limit");}
    let routing="com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext";
    let mut app=rustpush::ExtensionApp::from_bp(&wire,routing).map_err(|_|"balloon_schema")?;
    let balloon=app.balloon.as_ref().ok_or("balloon_schema")?;
    let session=uuid::Uuid::parse_str(v["session_hex"].as_str().ok_or("session_schema")?).map_err(|_|"session_schema")?.to_string();
    if balloon.session.as_deref()!=Some(session.as_str()) {return Err("candidate_binding");}
    if v["replace_template_url"]==true {app.balloon.as_mut().unwrap().url=v["url"].as_str().filter(|s|s.len()<131072).ok_or("url_schema")?.to_owned();}
    else if Some(balloon.url.as_str())!=v["url"].as_str() {return Err("candidate_binding");}
    let snapshot=store(copy_store(&saved.store));
    let mut config=Config::read(b64(v,"validation")?)?;config.phone=saved.phone.clone();
    let config:Arc<dyn OSConfig>=Arc::new(config);
    let (conn,error)=tokio::time::timeout(Duration::from_secs(25),rustpush::APSConnectionResource::new(config.clone(),Some(saved.push.clone()))).await.map_err(|_|"push_connection_timeout")?;
    if let Some(error)=error {
        let (stage,code)=connection_error(&error);
        return Ok(json!({"ok":false,"stage":stage,"numeric_code":code,"send_called":false,"registered_connection_verified":false,"confirmed_not_submitted":true}));
    }
    let home=v["support_directory"].as_str().ok_or("cache_path")?;
    let dir=std::path::Path::new(home);std::fs::create_dir_all(dir).map_err(|_|"cache_path")?;
    use std::os::unix::fs::{PermissionsExt,OpenOptionsExt};
    std::fs::set_permissions(dir,std::fs::Permissions::from_mode(0o700)).map_err(|_|"cache_permissions")?;
    let cache=dir.join("delivery-cache.plist");std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&cache).map_err(|_|"cache_path")?;
    std::fs::set_permissions(&cache,std::fs::Permissions::from_mode(0o600)).map_err(|_|"cache_permissions")?;
    static SERVICES:&[&rustpush::IDSService]=&[&MADRID_SERVICE];
    let client=rustpush::IMClient::new(conn.clone(),vec![saved.user.clone()],saved.identity.clone(),SERVICES,cache,config,Box::new(|_|{})).await;
    let handles=client.identity.get_handles().await;
    if handles!=vec![saved.phone.clone()] {return Err("sender_binding");}
    let mut normal=rustpush::NormalMessage::new(String::new(),rustpush::MessageType::IMessage);normal.app=Some(app);
    let mut message=rustpush::MessageInst::new(rustpush::ConversationData{participants:vec![saved.phone.clone(),recipient.clone()],cv_name:None,sender_guid:None,after_guid:None},&saved.phone,rustpush::Message::Message(normal));
    let sent=tokio::time::timeout(Duration::from_secs(30),client.send(&mut message)).await;
    let mut acknowledged=false;let mut code=None;let mut stage="send_failed";
    if let Ok(Ok(mut job))=sent {
        stage="send_unconfirmed";
        let deadline=tokio::time::sleep(Duration::from_secs(50));tokio::pin!(deadline);
        loop {tokio::select! {
            _=&mut deadline=>break,
            status=job.process.recv()=>match status {
                Ok((target,result))=>if target.participant==recipient {match result {
                    rustpush::SendResult::Sent=>{acknowledged=true;stage="recipient_transport_acknowledged";break;},
                    rustpush::SendResult::APSError(n)=>{code=Some(n);stage="recipient_transport_rejected";break;},
                    rustpush::SendResult::TimedOut=>break,
                }},Err(_)=>break,
            }
        }}
        if let Some(handle)=job.handle {handle.abort();let _=handle.await;}
    } else if sent.is_err() {stage="send_lookup_timeout";}
    saved.push=conn.state.read().await.clone();saved.user=client.identity.users.read().await[0].clone();saved.store=copy_store(&snapshot.lock().unwrap());
    Ok(json!({"ok":acknowledged,"stage":stage,"numeric_code":code,"state":STANDARD.encode(bin(&saved)?),"registered_connection_verified":true,"recipient_transport_acknowledged":acknowledged,"send_called":true,"game_acceptance_verified":false,"message_id":message.id}))
}
async fn receive_test(v:&Json)->Result<Json> {
    if v["test_receive_authorized"]!=true||v["keychain_saved"]!=true {return Err("receive_authorization_required");}
    let mut saved:Saved=plist::from_bytes(&b64(v,"state")?).map_err(|_|"state_schema")?;
    let recipient=v["recipient"].as_str().filter(|s|s.starts_with("tel:+")&&s[5..].bytes().all(|b|b.is_ascii_digit())).ok_or("recipient_schema")?.to_owned();
    let session=uuid::Uuid::parse_str(v["session_hex"].as_str().ok_or("session_schema")?).map_err(|_|"session_schema")?.to_string();
    if saved.user.registration.get("com.apple.madrid").map(|r|r.handles!=vec![saved.phone.clone()]).unwrap_or(true) {return Err("registered_phone_required");}
    let snapshot=store(copy_store(&saved.store));
    let mut config=Config::read(b64(v,"validation")?)?;config.phone=saved.phone.clone();let config:Arc<dyn OSConfig>=Arc::new(config);
    let (conn,error)=tokio::time::timeout(Duration::from_secs(25),rustpush::APSConnectionResource::new(config.clone(),Some(saved.push.clone()))).await.map_err(|_|"push_connection_timeout")?;
    if let Some(error)=error {let (stage,code)=connection_error(&error);return Ok(json!({"ok":false,"stage":stage,"numeric_code":code,"send_called":false}));}
    let mut messages=conn.subscribe().await;
    let dir=std::path::Path::new(v["support_directory"].as_str().ok_or("cache_path")?);std::fs::create_dir_all(dir).map_err(|_|"cache_path")?;
    use std::os::unix::fs::{PermissionsExt,OpenOptionsExt};std::fs::set_permissions(dir,std::fs::Permissions::from_mode(0o700)).map_err(|_|"cache_permissions")?;
    let cache=dir.join("delivery-cache.plist");std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&cache).map_err(|_|"cache_path")?;
    std::fs::set_permissions(&cache,std::fs::Permissions::from_mode(0o600)).map_err(|_|"cache_permissions")?;
    static SERVICES:&[&rustpush::IDSService]=&[&MADRID_SERVICE];
    let client=rustpush::IMClient::new(conn.clone(),vec![saved.user.clone()],saved.identity.clone(),SERVICES,cache,config,Box::new(|_|{})).await;
    let wait_seconds=match v.get("wait_seconds") {None=>90,Some(value)=>value.as_u64().filter(|seconds|(1..=90).contains(seconds)).ok_or("receive_wait_schema")?};
    let deadline=tokio::time::sleep(Duration::from_secs(wait_seconds));tokio::pin!(deadline);
    let routing="com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext";
    let mut matched=None;let mut verification_failed=false;
    loop {tokio::select! {
        _=&mut deadline=>break,
        msg=messages.recv()=>{
            let Ok(msg)=msg else {break;};
            let rustpush::APSMessage::Notification{ref payload,..}=msg else {continue;};
            let Some(outer)=payload.as_dictionary() else {continue;};
            // Inspect routing metadata only; other senders and non-message
            // commands are discarded without decrypting message contents.
            if outer.get("sP").and_then(Value::as_string)!=Some(recipient.as_str())||outer.get("tP").and_then(Value::as_string)!=Some(saved.phone.as_str())||outer.get("c").and_then(Value::as_unsigned_integer)!=Some(100) {continue;}
            if outer.get("P").and_then(Value::as_data).map(|b|b.len()>262144).unwrap_or(false) {continue;}
            let Ok(Some(mut received))=client.identity.receive_message(msg,&["com.apple.madrid"]).await else {continue;};
            if received.verification_failed {verification_failed=true;continue;}
            let Some(body)=received.message_unenc.take() else {continue;};
            let Ok(inner)=body.plist::<Value>() else {continue;};
            let Some(inner)=inner.as_dictionary() else {continue;};
            if inner.get("bid").and_then(Value::as_string)!=Some(routing) {continue;}
            let Some(bp)=inner.get("bp").and_then(Value::as_data).filter(|b|b.len()<262144) else {continue;};
            let Ok(app)=rustpush::ExtensionApp::from_bp(bp,routing) else {continue;};
            let Some(balloon)=app.balloon else {continue;};
            if balloon.session.as_deref()!=Some(session.as_str()) {continue;}
            let digest=format!("{:x}",sha2::Sha256::digest(balloon.url.as_bytes()));
            if v["excluded_url_hashes"].as_array().map(|a|a.iter().any(|h|h.as_str()==Some(digest.as_str()))).unwrap_or(false) {continue;}
            // Persist no text or attachment; only the matching game's URL.
            matched=Some(balloon.url);break;
        }
    }}
    saved.push=conn.state.read().await.clone();saved.user=client.identity.users.read().await[0].clone();saved.store=copy_store(&snapshot.lock().unwrap());
    Ok(json!({"ok":matched.is_some(),"stage":if matched.is_some(){"selected_game_received"}else{"receive_window_ended"},"state":STANDARD.encode(bin(&saved)?),
        "url":matched,"registered_connection_verified":true,"ordinary_message_contents_saved":false,"sender_and_session_filtered":true,"verification_failed":verification_failed,"send_called":false}))
}
#[tokio::main]
async fn main() {
    std::panic::set_hook(Box::new(|_|{}));
    let mut line=String::new();let n=io::stdin().lock().read_line(&mut line).unwrap_or(0);
    if n==0||n>1_048_576 {emit(json!({"ok":false,"stage":"input_limit"}));return;}
    let v:Json=match serde_json::from_str(&line){Ok(v)=>v,Err(_)=>{emit(json!({"ok":false,"stage":"input_schema"}));return;}};
    let result=match v["action"].as_str(){Some("prepare")=>prepare(&v),Some("register")=>register(&v).await,Some("send_turn")=>send_turn(&v).await,Some("probe_public_tls")=>probe_public_tls().await,Some("receive_test")=>receive_test(&v).await,_=>Err("action")};
    match result {Ok(v)=>emit(v),Err(stage)=>emit(json!({"ok":false,"stage":stage,"send_called":false}))}
}


