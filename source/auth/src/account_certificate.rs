//! An app-owned IDS authentication certificate, separate from push activation.
//! No system keychain identifiers are overwritten and no messaging registration occurs.
use std::{cmp::Ordering, io::Write, time::Duration};
use flate2::{write::GzEncoder, Compression};
use openssl::{asn1::Asn1Time, hash::{hash, MessageDigest}, nid::Nid,
    pkey::{PKey, Private}, rsa::Rsa, x509::{X509, X509NameBuilder, X509Req}};
use plist::Value;
use reqwest::{Client, redirect::Policy};
use zeroize::{Zeroize, Zeroizing};
use crate::ids_access::{Access, Failure, apple_url, bounded, dict, fail, number, public_plist, string};

pub struct Certificate {
    // Owned only by the helper until explicit persistence is implemented.
    pub key: PKey<Private>,
    pub certificate: X509,
}
type Result<T> = std::result::Result<T, Failure>;

fn csr(profile: &str) -> Result<(PKey<Private>, Vec<u8>)> {
    let digest = hash(MessageDigest::sha1(), profile.as_bytes()).map_err(|_|fail("csr_subject"))?;
    let name: String = digest.iter().map(|b|format!("{b:02X}")).collect();
    let mut subject = X509NameBuilder::new().map_err(|_|fail("csr_subject"))?;
    subject.append_entry_by_nid(Nid::COMMONNAME, &name).map_err(|_|fail("csr_subject"))?;
    let key = PKey::from_rsa(Rsa::generate(2048).map_err(|_|fail("csr_key"))?).map_err(|_|fail("csr_key"))?;
    let mut request = X509Req::builder().map_err(|_|fail("csr_encoding"))?;
    request.set_version(0).map_err(|_|fail("csr_encoding"))?;
    request.set_subject_name(&subject.build()).map_err(|_|fail("csr_encoding"))?;
    request.set_pubkey(&key).map_err(|_|fail("csr_encoding"))?;
    // SHA-1 is required by this legacy CSR wire format, not used for TLS.
    request.sign(&key, MessageDigest::sha1()).map_err(|_|fail("csr_signing"))?;
    let bytes = request.build().to_der().map_err(|_|fail("csr_encoding"))?;
    Ok((key, bytes))
}

pub(crate) fn validate(bytes: &[u8], key: &PKey<Private>) -> Result<X509> {
    if bytes.is_empty() || bytes.len() > 65536 {return Err(fail("certificate_size"));}
    let cert = X509::from_der(bytes).map_err(|_|fail("certificate_der"))?;
    let public = cert.public_key().map_err(|_|fail("certificate_key"))?;
    if !public.public_eq(key) {return Err(fail("certificate_key_mismatch"));}
    let now = Asn1Time::days_from_now(0).map_err(|_|fail("certificate_time"))?;
    if cert.not_before().compare(&now).map_err(|_|fail("certificate_time"))? == Ordering::Greater
        || cert.not_after().compare(&now).map_err(|_|fail("certificate_time"))? != Ordering::Greater {
        return Err(fail("certificate_expired"));
    }
    Ok(cert)
}

fn user_agent(description: &str) -> Result<String> {
    let parts: Vec<_> = description.split('<').filter_map(|p|p.split_once('>').map(|(a,_)|a)).collect();
    if parts.len() < 2 || parts[0].contains(['\r','\n']) {return Err(fail("certificate_client_metadata"));}
    let os: Vec<_> = parts[1].split(';').collect();
    if os.len()!=3 || os[0]!="macOS" || os.iter().any(|p|p.contains([',','\r','\n'])) {
        return Err(fail("certificate_client_metadata"));
    }
    Ok(format!("com.apple.invitation-registration [macOS,{},{},{}]", os[1], os[2], parts[0]))
}

pub async fn prepare(access: &Access, description: &str) -> Result<Certificate> {
    let client=Client::builder().https_only(true).no_proxy().redirect(Policy::none())
        .connect_timeout(Duration::from_secs(10)).timeout(Duration::from_secs(30))
        .build().map_err(|_|fail("certificate_tls"))?;
    let outer=public_plist(&client,"https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3").await?;
    let bytes=outer.as_dictionary().and_then(|d|d.get("bag")).and_then(Value::as_data).ok_or(fail("bag_schema"))?;
    let bag:Value=plist::from_bytes(bytes).map_err(|_|fail("bag_schema"))?;
    let endpoint=string(&bag,"id-authenticate-ds-id").ok_or(fail("certificate_endpoint"))?;
    if !apple_url(&endpoint) {return Err(fail("endpoint_policy"));}
    let agent=user_agent(description)?;
    let (key, request)=csr(&access.profile)?;
    let request=dict([
        ("authentication-data",dict([("auth-token",Value::String(access.token.clone()))])),
        ("csr",Value::Data(request)),
        ("realm-user-id",Value::String(access.profile.clone())),
    ]);
    let mut body=Zeroizing::new(Vec::new());
    plist::to_writer_xml(&mut *body,&request).map_err(|_|fail("certificate_request"))?;
    let mut gzip=GzEncoder::new(Vec::new(),Compression::default());
    gzip.write_all(&body).map_err(|_|fail("certificate_compression"))?;
    let mut compressed=gzip.finish().map_err(|_|fail("certificate_compression"))?;
    body.zeroize();
    let response=client.post(endpoint).header("User-Agent",agent)
        .header("x-protocol-version","1660").header("content-encoding","gzip")
        .body(std::mem::take(&mut compressed)).send().await.map_err(|_|fail("certificate_http"))?;
    let mut bytes=bounded(response,"certificate_http").await?;
    let parsed=plist::from_bytes::<Value>(&bytes);bytes.zeroize();
    let parsed=parsed.map_err(|_|fail("certificate_schema"))?;
    if number(&parsed,"status")!=Some(0) {return Err(Failure{stage:"certificate_status",code:number(&parsed,"status")});}
    let bytes=parsed.as_dictionary().and_then(|d|d.get("cert")).and_then(Value::as_data).ok_or(fail("certificate_missing"))?;
    let certificate=validate(bytes,&key)?;
    Ok(Certificate{key,certificate})
}


