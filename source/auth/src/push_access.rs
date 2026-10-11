//! Own push bootstrap and read-only sender eligibility; no IDS registration/send.
use std::{io::Write, process::{Command, Stdio}, time::{Duration,SystemTime,UNIX_EPOCH}};
use base64::{Engine,engine::general_purpose::STANDARD};
use openssl::{pkey::{PKey,Private},x509::X509,hash::MessageDigest,sign::Signer,rsa::Padding};
use plist::Value;
use reqwest::{Client,redirect::Policy};
use zeroize::{Zeroize,Zeroizing};
use crate::{account_certificate::Certificate,ids_access::{Access,Failure,apple_url,bounded,fail,number,public_plist,string}};
type Result<T> = std::result::Result<T,Failure>;
pub struct PushState {pub key:PKey<Private>,pub certificate:X509,pub token:Vec<u8>}
impl Drop for PushState {fn drop(&mut self){self.token.zeroize();}}

pub fn prepare() -> Result<PushState> {
    let executable=std::env::current_exe().map_err(|_|fail("push_worker_start"))?;
    let resources=executable.parent().and_then(|p|p.parent()).ok_or(fail("push_worker_start"))?.join("Resources");
    let mut child=Command::new(resources.join("python-runtime")).arg("-I").arg("-B")
        .arg(resources.join("push_bootstrap_worker.py")).arg("--private-worker")
        .env_clear().env("LANG","en_US.UTF-8")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().map_err(|_|fail("push_worker_start"))?;
    let write_result=child.stdin.take().ok_or(fail("push_worker_pipe"))?
        .write_all(b"{\"action\":\"prepare_push\"}\n");
    if write_result.is_err(){let _=child.kill();let _=child.wait();return Err(fail("push_worker_pipe"));}
    let mut output=child.wait_with_output().map_err(|_|fail("push_worker_exit"))?;
    if !output.status.success() || output.stdout.len()>32768 {output.stdout.zeroize();return Err(fail("push_worker_exit"));}
    let parsed=serde_json::from_slice::<serde_json::Value>(&output.stdout);output.stdout.zeroize();
    let mut parsed=parsed.map_err(|_|fail("push_worker_schema"))?;
    if parsed["push_handshake_success"]!=true {return Err(fail("push_handshake"));}
    let private=parsed["_private_push_state"].as_object_mut().ok_or(fail("push_worker_schema"))?;
    let mut decode=|name:&str|->Result<Zeroizing<Vec<u8>>> {
        let mut value=private.remove(name).and_then(|v|v.as_str().map(str::to_owned)).ok_or(fail("push_worker_schema"))?;
        let result=STANDARD.decode(&value).map(Zeroizing::new).map_err(|_|fail("push_worker_encoding"));value.zeroize();result
    };
    let key_bytes=decode("key_pem")?;let cert_bytes=decode("certificate_der")?;let token=decode("token")?;
    let key=PKey::private_key_from_pem(&key_bytes).map_err(|_|fail("push_key"))?;
    let certificate=crate::account_certificate::validate(&cert_bytes,&key)?;
    if key.bits()!=2048 || token.len()!=32 {return Err(fail("push_worker_schema"));}
    Ok(PushState{key,certificate,token:token.to_vec()})
}

fn nonce() -> Result<Vec<u8>> {
    let mut random=[0u8;8];openssl::rand::rand_bytes(&mut random).map_err(|_|fail("request_nonce"))?;
    let millis=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_|fail("clock"))?.as_secs()*1000;
    Ok([vec![1],millis.to_be_bytes().to_vec(),random.to_vec()].concat())
}
fn signature(key:&PKey<Private>,nonce:&[u8],token:&[u8]) -> Result<String> {
    let mut data=nonce.to_vec();
    for item in [b"id-get-handles".as_slice(),b"",b"",token] {
        data.extend_from_slice(&(item.len() as u32).to_be_bytes());data.extend_from_slice(item);
    }
    let mut signer=Signer::new(MessageDigest::sha1(),key).map_err(|_|fail("request_signature"))?;
    signer.set_rsa_padding(Padding::PKCS1).map_err(|_|fail("request_signature"))?;
    let signed=signer.sign_oneshot_to_vec(&data).map_err(|_|fail("request_signature"))?;
    Ok(STANDARD.encode([vec![1,1],signed].concat()))
}
pub async fn handles(access:&Access,auth:&Certificate,push:&PushState) -> Result<Vec<String>> {
    let client=Client::builder().https_only(true).no_proxy().redirect(Policy::none())
        .connect_timeout(Duration::from_secs(10)).timeout(Duration::from_secs(30))
        .build().map_err(|_|fail("sender_tls"))?;
    let outer=public_plist(&client,"https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3").await?;
    let bag_bytes=outer.as_dictionary().and_then(|d|d.get("bag")).and_then(Value::as_data).ok_or(fail("bag_schema"))?;
    let bag:Value=plist::from_bytes(bag_bytes).map_err(|_|fail("bag_schema"))?;
    let endpoint=string(&bag,"id-get-handles").ok_or(fail("sender_endpoint"))?;
    if !apple_url(&endpoint){return Err(fail("endpoint_policy"));}
    let mut request=client.get(endpoint).header("x-push-token",STANDARD.encode(&push.token))
        .header("x-protocol-version","1660").header("x-auth-user-id",&access.profile);
    for (name,key,certificate) in [("auth",&auth.key,&auth.certificate),("push",&push.key,&push.certificate)] {
        let nonce=nonce()?;
        request=request.header(format!("x-{name}-nonce"),STANDARD.encode(&nonce))
            .header(format!("x-{name}-sig"),signature(key,&nonce,&push.token)?)
            .header(format!("x-{name}-cert"),STANDARD.encode(certificate.to_der().map_err(|_|fail("request_certificate"))?));
    }
    let response=request.send().await.map_err(|_|fail("sender_http"))?;
    let mut bytes=bounded(response,"sender_http").await?;
    let parsed=plist::from_bytes::<Value>(&bytes);bytes.zeroize();
    let parsed=parsed.map_err(|_|fail("sender_schema"))?;
    if number(&parsed,"status")!=Some(0) {return Err(Failure{stage:"sender_status",code:number(&parsed,"status")});}
    let handles=parsed.as_dictionary().and_then(|d|d.get("handles")).and_then(Value::as_array).ok_or(fail("sender_schema"))?;
    if handles.len()>32{return Err(fail("sender_limit"));}
    handles.iter().map(|h|string(h,"uri").filter(|v|(v.starts_with("tel:+")||v.starts_with("mailto:")) && v.len()<256 && !v.contains(['\r','\n'])).ok_or(fail("sender_schema"))).collect()
}


