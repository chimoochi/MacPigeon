//! Narrow Apple IDS access check. No transport activation or messaging registration.
use std::{ffi::{CStr, CString, c_char}, time::Duration};
use base64::{Engine, engine::general_purpose::STANDARD};
use plist::{Value, Dictionary};
use reqwest::{Client, Response};
use zeroize::Zeroize;
use super::Account;

extern "C" {
    fn mp_device_validation(cert: *const u8, len: usize, url: *const c_char) -> *mut c_char;
    fn mp_auth_free(value: *mut c_char);
}
pub struct Access { pub token: String, pub profile: String }
impl Drop for Access { fn drop(&mut self) {self.token.zeroize();self.profile.zeroize();} }
pub struct Failure { pub stage: &'static str, pub code: Option<i64> }
type Result<T> = std::result::Result<T,Failure>;
pub(crate) fn fail(stage: &'static str)->Failure {Failure {stage,code:None}}
pub(crate) fn dict(entries: impl IntoIterator<Item=(&'static str,Value)>)->Value {
    Value::Dictionary(entries.into_iter().map(|(k,v)|(k.to_string(),v)).collect::<Dictionary>())
}
pub(crate) fn string(value:&Value,key:&str)->Option<String> {
    value.as_dictionary()?.get(key)?.as_string().map(str::to_owned)
}
pub(crate) fn number(value:&Value,key:&str)->Option<i64> {
    value.as_dictionary()?.get(key)?.as_signed_integer()
}
pub(crate) fn apple_url(value: &str)->bool {
    reqwest::Url::parse(value).map(|u|u.scheme()=="https" && u.port_or_known_default()==Some(443)
        && u.username().is_empty() && u.password().is_none()
        && u.host_str().map(|h|h=="apple.com"||h.ends_with(".apple.com")).unwrap_or(false)).unwrap_or(false)
}
pub(crate) async fn bounded(mut response: Response, stage: &'static str)->Result<Vec<u8>> {
    if !response.status().is_success() {return Err(Failure{stage,code:Some(response.status().as_u16() as i64)});}
    let mut data=Vec::new();
    while let Some(chunk)=response.chunk().await.map_err(|_|fail(stage))? {
        if data.len()+chunk.len()>1_048_576 {return Err(fail("response_limit"));}
        data.extend_from_slice(&chunk);
    }
    Ok(data)
}
pub(crate) async fn public_plist(client:&Client,url:&str)->Result<Value> {
    if !apple_url(url) {return Err(fail("endpoint_policy"));}
    let data=bounded(client.get(url).send().await.map_err(|_|fail("public_input"))?,"public_input").await?;
    plist::from_bytes(&data).map_err(|_|fail("public_schema"))
}
pub async fn validation_data()->Result<String> {
    let client=Client::builder().https_only(true).no_proxy().redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10)).timeout(Duration::from_secs(30)).build().map_err(|_|fail("tls_client"))?;
    let outer=public_plist(&client,"https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3").await?;
    let bag_bytes=outer.as_dictionary().and_then(|d|d.get("bag")).and_then(|v|v.as_data()).ok_or(fail("bag_schema"))?;
    let bag:Value=plist::from_bytes(bag_bytes).map_err(|_|fail("bag_schema"))?;
    let mut cert_url=string(&bag,"id-validation-cert").ok_or(fail("certificate_url"))?;
    if cert_url.starts_with("http://") {cert_url=cert_url.replacen("http://","https://",1);}
    let cert_response=public_plist(&client,&cert_url).await?;
    let certificate=cert_response.as_dictionary().and_then(|d|d.get("cert")).and_then(|v|v.as_data()).ok_or(fail("certificate_schema"))?;
    if certificate.is_empty()||certificate.len()>65536 {return Err(fail("certificate_limit"));}
    let initialize=string(&bag,"id-initialize-validation").ok_or(fail("validation_url"))?;
    if !apple_url(&initialize) {return Err(fail("endpoint_policy"));}
    let initialize=CString::new(initialize).map_err(|_|fail("endpoint_policy"))?;
    let pointer=unsafe {mp_device_validation(certificate.as_ptr(),certificate.len(),initialize.as_ptr())};
    if pointer.is_null() {return Err(fail("native_validation"));}
    let validation=unsafe {CStr::from_ptr(pointer).to_string_lossy().into_owned()};
    unsafe {mp_auth_free(pointer);}
    // Check encoding without displaying or persisting the device-validation bytes.
    if STANDARD.decode(&validation).map(|b|b.is_empty()).unwrap_or(true) {return Err(fail("validation_encoding"));}
    Ok(validation)
}
pub async fn check(account: &mut Account)->Result<Access> {
    // The direct get_pet accessor ignores expiry. Refresh an expired saved token
    // through the existing authenticated account client before IDS delegation.
    let mut pet=account.get_token("com.apple.gs.idms.pet").await.ok_or(fail("account_session_expired"))?;
    let session=account.persisted.as_ref().ok_or(fail("account_session"))?;
    let client=Client::builder().https_only(true).no_proxy().redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10)).timeout(Duration::from_secs(30)).build().map_err(|_|fail("tls_client"))?;
    let mut validation=validation_data().await?;
    let request=dict([
        ("delegates",dict([("com.apple.private.ids",dict([("protocol-version",Value::String("4".into()))]))])),
        ("protocolVersion",Value::String("1.0".into())),
        ("userInfo",dict([("client-id",Value::String(uuid::Uuid::new_v4().to_string().to_uppercase())),
            ("language",Value::String("en-US".into())),("timezone",Value::String("America/Los_Angeles".into()))])),
    ]);
    let mut body=Vec::new();plist::to_writer_xml(&mut body,&request).map_err(|_|fail("request_encoding"))?;
    let headers=account.anisette.lock().await.get_headers().await.map_err(|_|fail("authentication_headers"))?.clone();
    let client_description = &account.client_info.mme_client_info;
    let prefix = client_description.rsplit_once(" <").map(|(p,_)|p).ok_or(fail("client_metadata"))?;
    // Use the installed AOSKit version for the IDS delegate request; keep the
    // original AuthKit description for GrandSlam account authentication.
    let aos_description = format!("{} <com.apple.AOSKit/282>", prefix);
    let mut request=client.post("https://setup.icloud.com/setup/signin/v2/login")
        .header("User-Agent","com.apple.iCloudHelper/282")
        .header("X-Mme-Client-Info",aos_description)
        .header("X-Mme-Nas-Qualify",&validation)
        .header("X-Apple-ADSID",&session.adsid)
        .basic_auth(&session.username,Some(&pet)).body(body);
    for (name,value) in headers {
        if !name.eq_ignore_ascii_case("X-Mme-Client-Info") {request=request.header(name,value);}
    }
    let response=request.send().await.map_err(|_|fail("ids_delegate_http"));
    pet.zeroize();validation.zeroize();
    let mut bytes=bounded(response?,"ids_delegate_http").await?;
    let parsed=plist::from_bytes::<Value>(&bytes);bytes.zeroize();
    let parsed=parsed.map_err(|_|fail("ids_delegate_schema"))?;
    if number(&parsed,"status")!=Some(0) {return Err(Failure{stage:"ids_account_status",code:number(&parsed,"status")});}
    let delegate=parsed.as_dictionary().and_then(|d|d.get("delegates")).and_then(|v|v.as_dictionary())
        .and_then(|d|d.get("com.apple.private.ids")).ok_or(fail("ids_delegate_missing"))?;
    if number(delegate,"status")!=Some(0) {return Err(Failure{stage:"ids_delegate_status",code:number(delegate,"status")});}
    let service=delegate.as_dictionary().and_then(|d|d.get("service-data")).ok_or(fail("ids_service_data"))?;
    let token=string(service,"auth-token").filter(|s|!s.is_empty()).ok_or(fail("ids_auth_token"))?;
    let profile=string(service,"profile-id").filter(|s|!s.is_empty()).ok_or(fail("ids_profile"))?;
    Ok(Access {token,profile})
}


