//! Private transport snapshots travel only between this helper and its GUI's Keychain.
use base64::{Engine,engine::general_purpose::STANDARD};
use openssl::pkey::PKey;
use serde_json::{json,Value};
use zeroize::Zeroizing;
use crate::{account_certificate::{Certificate,validate},push_access::PushState,ids_access::{Failure,fail}};
type Result<T> = std::result::Result<T,Failure>;
fn decode(value:&Value,name:&str)->Result<Zeroizing<Vec<u8>>> {
    let text=value[name].as_str().filter(|s|s.len()<131072).ok_or(fail("transport_saved_schema"))?;
    STANDARD.decode(text).map(Zeroizing::new).map_err(|_|fail("transport_saved_encoding"))
}
pub fn snapshot(profile:&str,auth:&Certificate,push:&PushState,backend:Option<&Value>)->Result<Value> {
    let auth_key=Zeroizing::new(auth.key.private_key_to_der().map_err(|_|fail("transport_save_key"))?);
    let push_key=Zeroizing::new(push.key.private_key_to_der().map_err(|_|fail("transport_save_key"))?);
    Ok(json!({"version":1,"profile":profile,
        "auth_key_der":STANDARD.encode(&*auth_key),"auth_cert_der":STANDARD.encode(auth.certificate.to_der().map_err(|_|fail("transport_save_cert"))?),
        "push_key_der":STANDARD.encode(&*push_key),"push_cert_der":STANDARD.encode(push.certificate.to_der().map_err(|_|fail("transport_save_cert"))?),
        "push_token":STANDARD.encode(&push.token),"backend":backend}))
}
pub fn restore(value:&Value)->Result<(String,Certificate,PushState)> {
    if value["version"]!=1 {return Err(fail("transport_saved_version"));}
    let profile=value["profile"].as_str().filter(|s|!s.is_empty()&&s.len()<256).ok_or(fail("transport_saved_schema"))?.to_owned();
    let auth_key=PKey::private_key_from_der(&decode(value,"auth_key_der")?).map_err(|_|fail("transport_saved_key"))?;
    let push_key=PKey::private_key_from_der(&decode(value,"push_key_der")?).map_err(|_|fail("transport_saved_key"))?;
    if auth_key.bits()!=2048 || push_key.bits()!=2048 {return Err(fail("transport_saved_key"));}
    let auth_cert=validate(&decode(value,"auth_cert_der")?,&auth_key)?;
    let push_cert=validate(&decode(value,"push_cert_der")?,&push_key)?;
    let token=decode(value,"push_token")?;
    if token.len()!=32 {return Err(fail("transport_saved_token"));}
    Ok((profile,Certificate{key:auth_key,certificate:auth_cert},PushState{key:push_key,certificate:push_cert,token:token.to_vec()}))
}
pub fn session_data(account:&crate::Account,transport:Option<&Value>)->Option<Value> {
    let mut value=serde_json::to_value(account.persisted.as_ref()?).ok()?;
    if let Some(transport)=transport {value.as_object_mut()?.insert("transport_state".into(),transport.clone());}
    Some(value)
}


