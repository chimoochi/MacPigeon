use std::{collections::HashMap, io::{self, BufRead, BufReader, Write}, sync::Arc, process::{Child, ChildStdin, ChildStdout, Command, Stdio}, path::PathBuf};
use icloud_auth::{AppleAccount, LoginState, LoginClientInfo, PersistAccountData, VerifyBody};
use omnisette::{AnisetteProvider, AnisetteError, AnisetteClient};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;
mod ids_access;
mod account_certificate;
mod push_access;
mod transport_state;
mod delivery;
use base64::{Engine,engine::general_purpose::STANDARD};
// JSON's byte arrays need a JSON reader; the upstream plist::Data visitor
// accepts binary plist data but cannot read its own JSON array serialization.
#[derive(serde::Deserialize)]
struct SavedSession {
    username: String,
    first_name: Option<String>,
    last_name: Option<String>,
    hashed_password: Vec<u8>,
    postdata_done: Option<bool>,
    tokens: HashMap<String, icloud_auth::FetchedToken>,
    adsid: String,
    dsid: u64,
    acname: String,
}
fn read_saved_session(value: Value) -> Result<PersistAccountData, serde_json::Error> {
    let saved: SavedSession = serde_json::from_value(value)?;
    Ok(PersistAccountData {
        username: saved.username, first_name: saved.first_name, last_name: saved.last_name,
        hashed_password: saved.hashed_password, postdata_done: saved.postdata_done,
        tokens: saved.tokens, adsid: saved.adsid, dsid: saved.dsid, acname: saved.acname,
    })
}

// A reserved move belongs to one recipient/session, not merely an ordinal.
fn same_game(a:&Value,b:&Value)->bool {
    a["recipient"].as_str().is_some() && a["recipient"]==b["recipient"] &&
    a["session_hex"].as_str().is_some() && a["session_hex"]==b["session_hex"]
}



struct LocalWorker { child: Child, input: ChildStdin, output: BufReader<ChildStdout> }
impl LocalWorker {
    fn start() -> Result<Self, AnisetteError> {
        let executable = std::env::current_exe()?;
        let resources = executable.parent().and_then(|p|p.parent()).map(|p|p.join("Resources")).ok_or(AnisetteError::MissingLibraries)?;
        let (python, worker, libs, state) = if resources.join("local_anisette_worker.py").exists() {
            let python = std::fs::read_to_string(resources.join("python-runtime-path.txt"))?;
            let home = std::env::var("HOME").map_err(|_|AnisetteError::MissingLibraries)?;
            let python=if python.trim()=="@bundled" {resources.join("python-runtime")}else{PathBuf::from(python.trim())};
            (python, resources.join("local_anisette_worker.py"), resources.join("apple-music-arm64-libs.zip"), PathBuf::from(home).join("Library/Application Support/MacPigeon Lab/Anisette"))
        } else {
            return Err(AnisetteError::MissingLibraries);
        };
        let mut child = Command::new(python).arg("-I").arg("-B").arg(worker).arg(libs).arg(state)
            .env_clear().env("LANG","en_US.UTF-8").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
        let input=child.stdin.take().ok_or(AnisetteError::MissingLibraries)?;
        let output=BufReader::new(child.stdout.take().ok_or(AnisetteError::MissingLibraries)?);
        Ok(Self {child,input,output})
    }
    fn headers(&mut self, refresh: bool) -> Result<HashMap<String,String>, AnisetteError> {
        if refresh {self.input.write_all(b"{\"action\":\"headers\"}\n")?;self.input.flush()?;}
        let mut line=String::new();self.output.read_line(&mut line)?;
        if line.len()>32768 {line.zeroize();return Err(AnisetteError::InvalidLibraryFormat);}
        let parsed=serde_json::from_str::<Value>(&line);line.zeroize();
        let mut value=parsed.map_err(|_|AnisetteError::InvalidLibraryFormat)?;
        let headers: HashMap<String,String>=serde_json::from_value(value["headers"].take()).map_err(|_|AnisetteError::MissingLibraries)?;
        if !["X-Apple-I-MD","X-Apple-I-MD-M","X-Mme-Device-Id"].iter().all(|k|headers.get(*k).map(|v|!v.is_empty()).unwrap_or(false)) {return Err(AnisetteError::MissingLibraries);}
        Ok(headers)
    }
}
impl Drop for LocalWorker { fn drop(&mut self) {let _=self.child.kill();let _=self.child.wait();} }
struct LocalProvider { worker: Option<LocalWorker> }
impl AnisetteProvider for LocalProvider {
    async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, AnisetteError> {
        if let Some(worker) = &mut self.worker { return worker.headers(true); }
        let mut worker = LocalWorker::start()?;
        let headers = worker.headers(false)?;
        self.worker = Some(worker);
        Ok(headers)
    }
}

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    // This private pipe belongs to the GUI. Session events must never be logged.
    if serde_json::to_writer(&mut out, &value).is_ok() { let _ = out.write_all(b"\n"); let _ = out.flush(); }
}
fn emit_session(account:&Account,transport:Option<&Value>,await_ack:bool) {
    if let Some(data)=transport_state::session_data(account,transport) {
        emit(json!({"type":"session","data":data,"await_transport_ack":await_ack}));
    }
}
fn save_transport_ack(account:&Account,state:&Value,input:&mut impl BufRead)->Result<(),ids_access::Failure> {
    emit_session(account,Some(state),true);
    let mut line=String::new();let n=input.read_line(&mut line).map_err(|_|ids_access::fail("keychain_ack_pipe"))?;
    if n==0||n>1_048_576 {line.zeroize();return Err(ids_access::fail("keychain_ack_limit"));}
    let parsed=serde_json::from_str::<Value>(&line);line.zeroize();
    let parsed=parsed.map_err(|_|ids_access::fail("keychain_ack_schema"))?;
    if parsed["action"]!="transport_state_saved"||parsed["success"]!=true {return Err(ids_access::fail("keychain_save_required"));}Ok(())
}
fn safe_error(error: icloud_auth::Error) {
    let message = match error {
        icloud_auth::Error::Bad2faCode => "Apple rejected that verification code.",
        icloud_auth::Error::AuthSrp | icloud_auth::Error::AuthSrpWithMessage(_, _) => "Apple did not accept the sign-in. Check your account and password.",
        icloud_auth::Error::FailedGetting2FAConfig | icloud_auth::Error::HardwareKeyError => "This account’s security flow is not supported by this experimental client. Keep your account protections enabled.",
        icloud_auth::Error::ExtraStep(_) => "Apple requires an account step outside this app. Open your Apple Account settings.",
        icloud_auth::Error::ErrorGettingAnisette(_) => "Local Apple authentication data is unavailable.",
        _ => "The experimental Apple sign-in failed. No game turn was sent.",
    };
    emit(json!({"type":"error", "message":message}));
}
type Account = AppleAccount<LocalProvider>;
async fn show_state(account: &mut Account, mut state: LoginState, sms: &mut Option<VerifyBody>, transport: Option<&Value>) -> Result<(), icloud_auth::Error> {
    if matches!(state, LoginState::NeedsDevice2FA) { state = account.send_2fa_to_devices().await?; }
    match state {
        LoginState::LoggedIn => {
            emit_session(account,transport,false);
            emit(json!({"type":"authenticated", "message":"Apple account authenticated. Phone-number authorization and live game transport are still pending."}));
        }
        LoginState::Needs2FAVerification => emit(json!({"type":"code", "message":"Approve Apple’s sign-in prompt on a trusted device, then enter the verification code here."})),
        LoginState::NeedsSMS2FA => {
            let extras = account.get_auth_extras().await?;
            let choices: Vec<Value> = extras.trusted_phone_numbers.into_iter().map(|p| json!({"id":p.id,"label":format!("Phone ending in {}",p.last_two_digits)})).collect();
            emit(json!({"type":"sms_choice","choices":choices,"message":"Choose a trusted phone for Apple’s verification code."}));
        }
        LoginState::NeedsSMS2FAVerification(body) => { *sms = Some(body); emit(json!({"type":"code","message":"Enter the verification code Apple sent to your selected phone."})); }
        LoginState::NeedsLogin => {
            let (mut username, mut hash) = account.persisted.as_ref().map(|p|(p.username.clone(),p.hashed_password.clone())).ok_or(icloud_auth::Error::AuthSrp)?;
            let next = account.login_email_pass(&username, &hash).await;
            username.zeroize(); hash.zeroize();
            match next? {
                LoginState::LoggedIn => {
                    emit_session(account,transport,false);
                    emit(json!({"type":"authenticated","message":"Apple account authenticated. Phone-number authorization and live game transport are still pending."}));
                }
                _ => emit(json!({"type":"error","message":"Apple requires another sign-in step. Start sign-in again."})),
            }
        }
        LoginState::NeedsExtraStep(_) => emit(json!({"type":"error","message":"Apple requires an account step outside this app. Keep account protections enabled."})),
        _ => {}
    }
    Ok(())
}

#[tokio::main(flavor="current_thread")]
async fn main() {
    // Never enable a logger or display panic values from upstream parsing.
    std::panic::set_hook(Box::new(|_| {}));
    let provider = Arc::new(tokio::sync::Mutex::new(AnisetteClient::new(LocalProvider {worker:None})));
    let preflight = std::env::args().any(|a|a == "--preflight");
    let headers = match provider.lock().await.get_headers().await { Ok(h) => h.clone(), Err(_) => {
        if preflight {
            emit(json!({"authentication_headers_available":false,"local_emulator_used":true,"account_login_called":false,"ids_registration_called":false,"send_called":false,"header_values_printed":false}));
            std::process::exit(2);
        }
        emit(json!({"type":"error","message":"Local Apple authentication is unavailable. Check that the app includes its Anisette libraries and Python runtime. Sign-in is blocked before any credentials are requested."}));
        // Keep the private GUI pipe alive so its specific blocker stays visible.
        let mut discarded = String::new();
        let _ = io::stdin().lock().read_line(&mut discarded); discarded.zeroize();
        return;
    } };
    if preflight {
        emit(json!({"authentication_headers_available":true,"local_emulator_used":true,"native_framework_used":false,"required_header_count":headers.len(),"account_login_called":false,"ids_registration_called":false,"send_called":false,"header_values_printed":false,"remote_anisette_service_used":false}));
        return;
    }
    let description = headers.get("X-Mme-Client-Info").cloned().unwrap_or_default();
    let info = LoginClientInfo {
        ak_context_type:"imessage".into(),client_app_name:"Messages".into(),client_bundle_id:"com.apple.MobileSMS".into(),
        mme_client_info:description.clone(),mme_client_info_akd:description.clone(),update_account_bundle_id:description,
        akd_user_agent:"akd/1.0".into(),browser_user_agent:"MacPigeonLab/0.1".into(),hardware_headers:HashMap::new(),push_token:None,
    };
    let mut account = match AppleAccount::new_with_anisette(info,provider,None,Box::new(|_| {})) { Ok(a)=>a,Err(e)=>{safe_error(e);return;} };
    let mut sms = None;
    let mut ids_access = None;
    let mut account_certificate = None;
    let mut push_state = None;
    let mut transport_saved:Option<Value> = None;
    let mut transport_profile:Option<String> = None;
    emit(json!({"type":"ready"}));
    let mut input = io::stdin().lock();
    loop {
        let mut line = String::new();
        // Input is solely the child-process pipe, bounded before JSON parsing.
        let read = input.read_line(&mut line);
        if read.is_err() || read.unwrap_or(0) == 0 { line.zeroize(); break; }
        if line.len() > 1_048_576 { line.zeroize(); break; }
        let parsed = serde_json::from_str::<Value>(&line); line.zeroize();
        let mut command = match parsed {Ok(c)=>c,Err(_)=>break};
        match command["action"].as_str().unwrap_or("") {
            "login" => {
                let mut email = command["email"].take().as_str().unwrap_or("").trim().to_owned();
                let mut password = command["password"].take().as_str().unwrap_or("").to_owned();
                if email.is_empty() || password.is_empty() { email.zeroize();password.zeroize();emit(json!({"type":"error","message":"Enter your Apple Account and password."}));continue; }
                let mut hashed = Sha256::digest(password.as_bytes()).to_vec(); password.zeroize();
                let result = account.login_email_pass(&email,&hashed).await;
                email.zeroize(); hashed.zeroize();
                match result {Ok(state)=>if let Err(e)=show_state(&mut account,state,&mut sms,transport_saved.as_ref()).await {safe_error(e)},Err(e)=>safe_error(e)}
            }
            "verify" => {
                let mut code=command["code"].take().as_str().unwrap_or("").to_owned();
                if code.len()!=6 || !code.bytes().all(|b|b.is_ascii_digit()) {code.zeroize();emit(json!({"type":"error","message":"Enter the six-digit verification code."}));continue;}
                let result=if let Some(body)=sms.clone() {account.verify_sms_2fa(code.clone(),body).await} else {account.verify_2fa(code.clone()).await};code.zeroize();
                match result {Ok(state)=>if let Err(e)=show_state(&mut account,state,&mut sms,transport_saved.as_ref()).await {safe_error(e)},Err(e)=>safe_error(e)}
            }
            "sms" => {if let Some(id)=command["id"].as_u64().filter(|v|*v<=u32::MAX as u64) {match account.send_sms_2fa_to_devices(id as u32).await {Ok(state)=>if let Err(e)=show_state(&mut account,state,&mut sms,transport_saved.as_ref()).await {safe_error(e)},Err(e)=>safe_error(e)}}}
            "restore" => {
                // Retain an already authenticated local session in memory; never silently login/register.
                let mut saved=command["data"].take();
                let candidate=saved.as_object_mut().and_then(|d|d.remove("transport_state"));
                match read_saved_session(saved) {
                    Ok(p) => {account.persisted=Some(p);
                        if let Some(saved)=candidate {
                            match transport_state::restore(&saved) {
                                Ok((profile,auth,push))=>{account_certificate=Some(auth);push_state=Some(push);transport_profile=Some(profile);transport_saved=Some(saved);},
                                Err(e)=>{transport_saved=Some(saved);emit(json!({"type":"restore_error","message":"The saved delivery identity needs repair. Its keys are retained; automatic replacement is blocked.","failure_stage":e.stage}));continue;}
                            }
                        }
                        emit(json!({"type":"restored","message":"Saved account session loaded. Live transport and phone-number authorization are pending.","test_attempt_reserved":transport_saved.as_ref().map(|v|!v["test_send"].is_null()&&v["test_send"]["confirmed_not_submitted"]!=true).unwrap_or(false),"test_recipient_acknowledged":transport_saved.as_ref().map(|v|v["test_send"]["recipient_transport_acknowledged"]==true).unwrap_or(false),"delivery_keys_saved":transport_saved.is_some()}));}
                    Err(_) => emit(json!({"type":"restore_error","message":"The saved session format could not be read. Sign in locally to refresh it."})),
                }
            }
            "check_ids" => {
                match ids_access::check(&mut account).await {
                    Ok(access) => {ids_access=Some(access);emit(json!({"type":"ids_access","message":"Apple granted iMessage account access. Push transport and your phone-number sender authorization are still pending.","ids_delegate_authorized":true}));}
                    Err(error) => emit(json!({"type":"ids_error","message":"The iMessage access check failed. Your account sign-in is saved; no turn was sent.","failure_stage":error.stage,"numeric_code":error.code})),
                }
                emit_session(&account,transport_saved.as_ref(),false);
            }
            "prepare_certificate" => {
                if account_certificate.is_some() {
                    emit(json!({"type":"certificate_ready","message":"Your app-owned account certificate is ready. Push activation and phone-number authorization are pending.","ids_delegate_authorized":true}));
                    continue;
                }
                if ids_access.is_none() {
                    match ids_access::check(&mut account).await {
                        Ok(access) => ids_access=Some(access),
                        Err(error) => {
                            emit(json!({"type":"certificate_error","message":"Account access must be refreshed before preparing the certificate. No turn was sent.","ids_delegate_authorized":false,"failure_stage":error.stage,"numeric_code":error.code}));
                            continue;
                        }
                    }
                }
                if let Some(access) = &ids_access {
                    match account_certificate::prepare(access, &account.client_info.mme_client_info).await {
                        Ok(certificate) => {
                            // Touch only validated metadata; private key/certificate never go to UI.
                            let bits=certificate.key.bits();
                            let binding=certificate.certificate.public_key().map(|k|k.public_eq(&certificate.key)).unwrap_or(false);
                            account_certificate=Some(certificate);
                            emit(json!({"type":"certificate_ready","message":"Apple issued an account certificate for this app’s own key. Push activation and phone-number authorization are still pending.","ids_delegate_authorized":true,"key_bits":bits,"certificate_key_matches":binding}));
                        }
                        Err(error) => emit(json!({"type":"certificate_error","message":"The account certificate check failed. Your sign-in is saved; no turn was sent.","ids_delegate_authorized":true,"failure_stage":error.stage,"numeric_code":error.code})),
                    }
                }
                emit_session(&account,transport_saved.as_ref(),false);
            }
            "check_sender_handles" => {
                // Read-only eligibility. Never register a sender or send a game.
                let result = async {
                    if ids_access.is_none() {ids_access=Some(ids_access::check(&mut account).await?);}
                    let access=ids_access.as_ref().ok_or(ids_access::fail("account_access"))?;
                    if transport_profile.as_ref().map(|p|p!=&access.profile).unwrap_or(false) {return Err(ids_access::fail("transport_account_binding"));}
                    if account_certificate.is_none() {account_certificate=Some(account_certificate::prepare(access,&account.client_info.mme_client_info).await?);}
                    if push_state.is_none() {push_state=Some(push_access::prepare()?);}
                    push_access::handles(access,account_certificate.as_ref().unwrap(),push_state.as_ref().unwrap()).await
                }.await;
                match result {
                    Ok(handles) => {
                        if let (Some(access),Some(auth),Some(push))=(&ids_access,&account_certificate,&push_state) {
                            if let Ok(mut snapshot)=transport_state::snapshot(&access.profile,auth,push,transport_saved.as_ref().and_then(|v|v.get("backend"))) {
                                for key in ["test_send","game_send"] {if let Some(previous)=transport_saved.as_ref().and_then(|v|v.get(key)) {snapshot[key]=previous.clone();}}
                                transport_profile=Some(access.profile.clone());transport_saved=Some(snapshot);
                            }
                        }
                        let phone_count=handles.iter().filter(|h|h.starts_with("tel:")).count();
                        emit(json!({"type":"sender_handles_ready","message":if phone_count>0 {"Apple lists a phone-number sender for this account. Delivery registration and GamePigeon acceptance still need testing."} else {"Push authentication passed, but Apple did not list a phone-number sender. Email will not be used as a fallback."},"handles":handles,"phone_handle_count":phone_count,"push_bootstrap_ready":true,"ids_delegate_authorized":true,"ids_account_certificate_prepared":true,"key_bits":account_certificate.as_ref().unwrap().key.bits(),"certificate_key_matches":true,"phone_number_authorized":false,"ids_registration_called":false,"send_called":false}));
                    }
                    Err(error) => emit(json!({"type":"sender_handles_error","message":"The push or sender-eligibility check failed. Your sign-in is saved; no turn was sent.","push_bootstrap_ready":push_state.is_some(),"ids_account_certificate_prepared":account_certificate.is_some(),"failure_stage":error.stage,"numeric_code":error.code})),
                }
                emit_session(&account,transport_saved.as_ref(),false);
            }
            "connect_delivery" => {
                let result=async {
                    if transport_saved.is_some()&&transport_profile.is_none() {return Err(ids_access::fail("saved_identity_repair_required"));}
                    if ids_access.is_none() {ids_access=Some(ids_access::check(&mut account).await?);}
                    let access=ids_access.as_ref().ok_or(ids_access::fail("account_access"))?;
                    if transport_profile.as_ref().map(|p|p!=&access.profile).unwrap_or(false) {return Err(ids_access::fail("transport_account_binding"));}
                    if account_certificate.is_none() {account_certificate=Some(account_certificate::prepare(access,&account.client_info.mme_client_info).await?);}
                    if push_state.is_none() {push_state=Some(push_access::prepare()?);}
                    let auth=account_certificate.as_ref().unwrap();let push=push_state.as_ref().unwrap();
                    let handles=push_access::handles(access,auth,push).await?;
                    let phones:Vec<_>=handles.iter().filter(|h|h.starts_with("tel:+")).collect();
                    if phones.len()!=1 {return Err(ids_access::fail("unique_phone_required"));}
                    let mut snapshot=transport_state::snapshot(&access.profile,auth,push,transport_saved.as_ref().and_then(|v|v.get("backend")))?;
                    if snapshot["backend"].is_null() {
                        let mut request=snapshot.clone();request["action"]=json!("prepare");request["phone"]=json!(phones[0]);
                        let mut prepared=delivery::worker(request)?;
                        if prepared["ok"]!=true {return Err(ids_access::fail("delivery_identity_prepare"));}
                        snapshot["backend"]=prepared["state"].take();
                    }
                    for key in ["test_send","game_send"] {if let Some(previous)=transport_saved.as_ref().and_then(|v|v.get(key)) {snapshot[key]=previous.clone();}}
                                transport_profile=Some(access.profile.clone());transport_saved=Some(snapshot);
                    save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    emit(json!({"type":"delivery_progress","message":"Delivery keys saved in Keychain. Registering your phone-number sender with Apple…","delivery_keys_saved":true,"send_called":false}));
                    let mut validation=ids_access::validation_data().await?;
                    let registered=delivery::worker(json!({"action":"register","state":transport_saved.as_ref().unwrap()["backend"],"keychain_saved":true,"validation":validation}));
                    validation.zeroize();
                    let mut registered=registered?;
                    if registered["state"].is_string() {
                        transport_saved.as_mut().unwrap()["backend"]=registered["state"].take();
                        save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    }
                    let successful=registered["ok"]==true&&registered["phone_number_authorized"]==true;
                    emit(json!({"type":if successful {"delivery_registered"} else {"delivery_error"},
                        "message":if successful {if transport_saved.as_ref().map(|v|v["test_send"]["recipient_transport_acknowledged"]==true).unwrap_or(false) {"Your phone-number delivery identity is restored. The earlier game-turn test was acknowledged."}else{"Apple registered your phone number for this app’s delivery identity. A compatible game turn has not been sent yet."}} else {"Apple did not complete delivery registration. Your keys are saved; no game turn was sent."},
                        "failure_stage":if successful {Value::Null} else {registered["stage"].clone()},"numeric_code":registered["numeric_code"],
                        "ids_registration_called":registered["ids_registration_called"],"phone_number_authorized":successful,"handles":handles,"ids_delegate_authorized":true,"push_bootstrap_ready":true,"ids_account_certificate_prepared":true,"certificate_key_matches":true,"key_bits":auth.key.bits(),"delivery_keys_saved":true,"send_called":false}));
                    Ok::<(),ids_access::Failure>(())
                }.await;
                if let Err(e)=result {emit(json!({"type":"delivery_error","message":"The delivery setup stopped before sending. Your saved session remains available.","failure_stage":e.stage,"numeric_code":e.code,"send_called":false}));}
            }
            "load_game" => {
                let loaded=(||->Result<Value,ids_access::Failure>{
                    let game=delivery::game(json!({"action":"load"}))?;
                    if let Some(saved)=transport_saved.as_ref() {
                        if let Some(prepared)=saved["game_send"].get("prepared_game") {
                            if prepared["new_invitation"]==true && saved["game_send"]["confirmed_not_submitted"]!=true && prepared["parent_url"]==game["url"] {
                                return delivery::game(json!({"action":"commit_invitation","state":prepared}));
                            }
                            let number=|v:&Value|v["board"]["num"].as_str().and_then(|n|n.parse::<u64>().ok());
                            if same_game(prepared,&game) && saved["game_send"]["confirmed_not_submitted"]!=true && number(prepared).zip(number(&game)).map(|(a,b)|a==b+1).unwrap_or(false) {
                                return delivery::game(json!({"action":"commit","state":prepared}));
                            }
                        }
                    }
                    Ok(game)
                })();
                match loaded {
                    Ok(game)=>emit(json!({"type":"game_loaded","game":game["board"],"can_play":game["can_play"],"own_player":game["own_player"],"recipient":game["recipient"],"message":if game["can_play"]==true {"Your turn."}else{"Waiting for your friend."}})),
                    Err(_)=>emit(json!({"type":"game_unavailable","message":"No saved game is available yet. Older Messages bubbles still need a scoped import."})),
                }
            }
            "send_game_move" | "send_native_turn" | "start_game" => {
                let mut worker_called=false;
                let result=async {
                    let saved=transport_saved.as_ref().ok_or(ids_access::fail("saved_identity_required"))?;
                    let invitation=command["action"]=="start_game";
                    let game=if invitation {
                        let current=delivery::game(json!({"action":"load"}))?;
                        if saved["game_send"]["prepared_game"]["new_invitation"]==true && saved["game_send"]["confirmed_not_submitted"]!=true && saved["game_send"]["prepared_game"]["parent_url"]==current["url"] {return Err(ids_access::fail("invitation_already_reserved"));}
                        delivery::game(json!({"action":"prepare_invitation","game":command["game"],"options":command["options"],"recipient":command["recipient"]}))?
                    }else {
                        let expected=command["expected_num"].as_u64().ok_or(ids_access::fail("turn_number"))?;
                        if command["action"]=="send_native_turn" {
                            delivery::game(json!({"action":"prepare_native","fields":command["fields"],"expected_num":expected}))?
                        }else {
                            let column=command["column"].as_u64().filter(|c|*c<7).ok_or(ids_access::fail("column"))?;
                            delivery::game(json!({"action":"prepare","column":column,"expected_num":expected}))?
                        }
                    };
                    let marker=format!("{:x}",Sha256::digest(game["url"].as_str().ok_or(ids_access::fail("game_url"))?.as_bytes()));
                    if same_game(&saved["game_send"]["prepared_game"],&game) && saved["game_send"]["prepared_game"]["board"]["num"]==game["board"]["num"] && saved["game_send"]["confirmed_not_submitted"]!=true {return Err(ids_access::fail("turn_already_reserved"));}
                    let validation=ids_access::validation_data().await?;
                    transport_saved.as_mut().unwrap()["game_send"]=json!({"marker":marker,"attempt_reserved":true,"prepared_game":game});
                    save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    worker_called=true;
                    let mut sent=delivery::worker(json!({"action":"send_turn","state":transport_saved.as_ref().unwrap()["backend"],"keychain_saved":true,"one_test_send_authorized":true,"replace_template_url":true,
                        "recipient":game["recipient"],"wire":game["wire"],"url":game["url"],"session_hex":game["session_hex"],"validation":validation,
                        "support_directory":PathBuf::from(std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?).join("Library/Application Support/MacPigeon Lab/Transport")}))?;
                    if sent["state"].is_string(){transport_saved.as_mut().unwrap()["backend"]=sent["state"].take();}
                    transport_saved.as_mut().unwrap()["game_send"]["recipient_transport_acknowledged"]=sent["recipient_transport_acknowledged"].clone();
                    transport_saved.as_mut().unwrap()["game_send"]["confirmed_not_submitted"]=sent["confirmed_not_submitted"].clone();
                    save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    let committed=if sent["confirmed_not_submitted"]!=true {delivery::game(json!({"action":if invitation {"commit_invitation"}else{"commit"},"state":game}))?}else{delivery::game(json!({"action":"load"}))?};
                    emit(json!({"type":"game_sent","game":committed["board"],"can_play":committed["can_play"],"own_player":committed["own_player"],"recipient":committed["recipient"],"recipient_transport_acknowledged":sent["recipient_transport_acknowledged"],"send_called":sent["send_called"],"confirmed_not_submitted":sent["confirmed_not_submitted"],"message":if sent["recipient_transport_acknowledged"]==true {if invitation {"Invitation sent. Waiting for your friend."}else{"Turn sent. Waiting for your friend."}}else if sent["confirmed_not_submitted"]==true {"Couldn’t connect. Your game was not sent."}else{"Delivery is unconfirmed. This game will not be resent automatically."}}));
                    Ok::<(),ids_access::Failure>(())
                }.await;
                if let Err(e)=result {emit(json!({"type":"game_error","send_called":worker_called,"failure_stage":e.stage,"message":if worker_called {"Delivery is uncertain. This move is reserved to prevent duplicate sends."}else{"The move could not start. Refresh the saved game before trying again."}}));}
            }
            "receive_game" => {
                let result=async {
                    let saved=transport_saved.as_ref().ok_or(ids_access::fail("saved_identity_required"))?;
                    let mut game=delivery::game(json!({"action":"load"}))?;
                    // Recover a turn reserved before a crash without retransmitting it.
                    if let Some(prepared)=saved["game_send"].get("prepared_game") {
                        if prepared["new_invitation"]==true && saved["game_send"]["confirmed_not_submitted"]!=true && prepared["parent_url"]==game["url"] {
                            game=delivery::game(json!({"action":"commit_invitation","state":prepared}))?;
                        }else if same_game(prepared,&game) && saved["game_send"]["confirmed_not_submitted"]!=true && prepared["board"]["num"].as_str().and_then(|n|n.parse::<u64>().ok()).zip(game["board"]["num"].as_str().and_then(|n|n.parse::<u64>().ok())).map(|(a,b)|a==b+1).unwrap_or(false) {
                            game=delivery::game(json!({"action":"commit","state":prepared}))?;
                        }
                    }
                    save_transport_ack(&account,saved,&mut input)?;
                    let validation=ids_access::validation_data().await?;
                    let exclusions=game["seen_url_hashes"].clone();
                    let mut received=delivery::worker(json!({"action":"receive_test","state":saved["backend"],"keychain_saved":true,"test_receive_authorized":true,"recipient":game["recipient"],"session_hex":game["session_hex"],"validation":validation,"excluded_url_hashes":exclusions,
                        "support_directory":PathBuf::from(std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?).join("Library/Application Support/MacPigeon Lab/Transport")}))?;
                    if received["state"].is_string(){transport_saved.as_mut().unwrap()["backend"]=received["state"].take();save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;}
                    if received["ok"]==true {
                        game=delivery::game(json!({"action":"receive","url":received["url"]}))?;
                        emit(json!({"type":"game_received","game":game["board"],"can_play":game["can_play"],"message":"Your friend played. Your turn."}));
                    }else{emit(json!({"type":"game_wait","game":game["board"],"can_play":game["can_play"],"message":"Waiting for your friend."}));}
                    Ok::<(),ids_access::Failure>(())
                }.await;
                if let Err(e)=result {emit(json!({"type":"game_receive_error","failure_stage":e.stage,"message":"Game connection paused. Use Reconnect to try again."}));}
            }
            "send_prepared_test" => {
                let mut worker_called=false;
                let result=async {
                    let saved=transport_saved.as_ref().ok_or(ids_access::fail("saved_identity_required"))?;
                    if !saved["backend"].is_string() {return Err(ids_access::fail("registered_identity_required"));}
                    if !saved["test_send"].is_null()&&!saved["test_send"]["confirmed_not_submitted"].as_bool().unwrap_or(false) {
                        // One-time development migration for the observed pre-parser-fix
                        // failure. It returned before IMClient.send, as recorded locally.
                        let proof=PathBuf::from(std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?).join("Library/Application Support/MacPigeon Lab/SelectedTest/mac-unsent-preflight-proof.json");
                        let proof=std::fs::read(proof).ok().filter(|b|b.len()<4096).and_then(|b|serde_json::from_slice::<Value>(&b).ok());
                        let safe=proof.as_ref().map(|p|p["source"]=="observed_previous_worker_preflight"&&p["confirmed_not_submitted"]==true&&p["send_called"]==false&&p["failure_stage"]=="push_connection_failed"&&p["wire_sha256"]==saved["test_send"]["wire_sha256"]).unwrap_or(false);
                        if !safe {return Err(ids_access::fail("test_already_attempted"));}
                    }
                    let home=std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?;
                    let folder=PathBuf::from(home).join("Library/Application Support/MacPigeon Lab/SelectedTest");
                    let read=|name:&str|->Result<Vec<u8>,ids_access::Failure>{
                        let p=folder.join(name);
                        if std::fs::metadata(&p).map_err(|_|ids_access::fail("test_fixture"))?.len()>262144 {return Err(ids_access::fail("test_fixture_limit"));}
                        std::fs::read(p).map_err(|_|ids_access::fail("test_fixture"))
                    };
                    let candidate:Value=serde_json::from_slice(&read("mac-reply-candidate-private.json")?).map_err(|_|ids_access::fail("test_fixture_schema"))?;
                    let selector:Value=serde_json::from_slice(&read("mac-test-selector.json")?).map_err(|_|ids_access::fail("test_fixture_schema"))?;
                    let friend=selector["sender"].as_str().filter(|s|s.starts_with('+')&&s[1..].bytes().all(|b|b.is_ascii_digit())).ok_or(ids_access::fail("test_recipient"))?;
                    let wire=read("rustpush-candidate-balloon.bin")?;
                    let validation=ids_access::validation_data().await?;
                    let marker=format!("{:x}",Sha256::digest(&wire));
                    // Consume the one-time no-submit migration before reserving a
                    // new attempt, so a crash during sending cannot reuse proof.
                    let proof=folder.join("mac-unsent-preflight-proof.json");
                    if proof.exists() {std::fs::rename(&proof,proof.with_extension("consumed.json")).map_err(|_|ids_access::fail("preflight_proof_consume"))?;}
                    transport_saved.as_mut().unwrap()["test_send"]=json!({"wire_sha256":marker,"attempt_reserved":true});
                    save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    emit(json!({"type":"delivery_progress","message":"Connecting the saved delivery identity and sending the prepared Four in a Row reply…","delivery_keys_saved":true}));
                    let home=std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?;
                    worker_called=true;
                    let mut sent=delivery::worker(json!({"action":"send_turn","state":transport_saved.as_ref().unwrap()["backend"],"keychain_saved":true,"one_test_send_authorized":true,
                        "recipient":format!("tel:{friend}"),"wire":STANDARD.encode(wire),"url":candidate["url"],"session_hex":candidate["session_identifier_hex"],"validation":validation,
                        "support_directory":PathBuf::from(home).join("Library/Application Support/MacPigeon Lab/Transport")}))?;
                    if sent["state"].is_string() {transport_saved.as_mut().unwrap()["backend"]=sent["state"].take();}
                    transport_saved.as_mut().unwrap()["test_send"]["recipient_transport_acknowledged"]=sent["recipient_transport_acknowledged"].clone();
                    transport_saved.as_mut().unwrap()["test_send"]["confirmed_not_submitted"]=sent["confirmed_not_submitted"].clone();
                    // Consume migration proof before any future retry decision. A
                    // started/unknown send never gains the no-submit guarantee.
                    let proof=PathBuf::from(std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?).join("Library/Application Support/MacPigeon Lab/SelectedTest/mac-unsent-preflight-proof.json");
                    let _=std::fs::rename(&proof,proof.with_extension("consumed.json"));
                    save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;
                    let acknowledged=sent["recipient_transport_acknowledged"]==true;
                    emit(json!({"type":if acknowledged {"test_transport_acknowledged"} else {"test_send_unconfirmed"},
                        "message":if acknowledged {"The prepared game turn received a recipient transport acknowledgement. GamePigeon’s acceptance still needs confirmation on the friend’s device."} else {"The prepared test did not receive a confirmed recipient acknowledgement. It will not be retried automatically."},
                        "failure_stage":if acknowledged {Value::Null}else{sent["stage"].clone()},"numeric_code":sent["numeric_code"],"send_called":sent["send_called"],"registered_connection_verified":sent["registered_connection_verified"],
                        "recipient_transport_acknowledged":acknowledged,"game_acceptance_verified":false}));
                    Ok::<(),ids_access::Failure>(())
                }.await;
                if let Err(e)=result {emit(json!({"type":"test_send_unconfirmed","message":if worker_called {"The test attempt ended without a confirmed result. Delivery is unknown; automatic retry is blocked."} else {"The test could not start, or was already attempted. No automatic retry was made."},"failure_stage":e.stage,"numeric_code":e.code,"send_called":worker_called,"game_acceptance_verified":false}));}
            }
            "receive_selected_test_reply" => {
                let result=async {
                    let saved=transport_saved.as_ref().ok_or(ids_access::fail("saved_identity_required"))?;
                    if !saved["backend"].is_string() {return Err(ids_access::fail("registered_identity_required"));}
                    let home=std::env::var("HOME").map_err(|_|ids_access::fail("support_path"))?;
                    let folder=PathBuf::from(&home).join("Library/Application Support/MacPigeon Lab/SelectedTest");
                    let read=|name:&str|->Result<Value,ids_access::Failure>{let p=folder.join(name);if std::fs::metadata(&p).map_err(|_|ids_access::fail("test_fixture"))?.len()>262144{return Err(ids_access::fail("test_fixture_limit"));}let b=std::fs::read(p).map_err(|_|ids_access::fail("test_fixture"))?;serde_json::from_slice(&b).map_err(|_|ids_access::fail("test_fixture_schema"))};
                    let selector=read("mac-test-selector.json")?;let candidate=read("mac-reply-candidate-private.json")?;
                    let friend=selector["sender"].as_str().filter(|s|s.starts_with('+')&&s[1..].bytes().all(|b|b.is_ascii_digit())).ok_or(ids_access::fail("test_recipient"))?;
                    save_transport_ack(&account,saved,&mut input)?;
                    let validation=ids_access::validation_data().await?;
                    let mut received=delivery::worker(json!({"action":"receive_test","state":saved["backend"],"keychain_saved":true,"test_receive_authorized":true,"recipient":format!("tel:{friend}"),"session_hex":candidate["session_identifier_hex"],"validation":validation,
                        "support_directory":PathBuf::from(&home).join("Library/Application Support/MacPigeon Lab/Transport")}))?;
                    if received["ok"]==true {
                        // Save the authorized matching URL before any renderer or
                        // Keychain operation can fail. It contains no other message.
                        use std::os::unix::fs::OpenOptionsExt;
                        let mut file=std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(folder.join("live-selected-game-private.json")).map_err(|_|ids_access::fail("selected_game_save"))?;
                        serde_json::to_writer(&mut file,&json!({"url":received["url"]})).map_err(|_|ids_access::fail("selected_game_save"))?;
                    }
                    if received["state"].is_string() {transport_saved.as_mut().unwrap()["backend"]=received["state"].take();save_transport_ack(&account,transport_saved.as_ref().unwrap(),&mut input)?;}
                    if received["ok"]==true {
                        let url=received["url"].take();let url=url.as_str().ok_or(ids_access::fail("received_game_schema"))?;
                        let board=delivery::decode_selected_turn(url)?;
                        let prior=delivery::decode_selected_turn(candidate["url"].as_str().ok_or(ids_access::fail("test_fixture_schema"))?)?;
                        let number=|v:&Value|v["num"].as_str().and_then(|n|n.parse::<u64>().ok());
                        if number(&board).zip(number(&prior)).map(|(next,prev)|next<=prev).unwrap_or(true) {return Err(ids_access::fail("received_turn_not_newer"));}
                        // Only the authorized same-session URL and sanitized board.
                        use std::os::unix::fs::OpenOptionsExt;
                        for (name,value) in [("live-selected-game-private.json",json!({"url":url})),("live-received-board.json",board)] {
                            let mut file=std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(folder.join(name)).map_err(|_|ids_access::fail("selected_game_save"))?;
                            serde_json::to_writer(&mut file,&value).map_err(|_|ids_access::fail("selected_game_save"))?;
                        }
                        emit(json!({"type":"test_reply_received","message":"Your friend’s reply arrived directly on the Mac in the same Four in a Row session.","received_board_path":folder.join("live-received-board.json"),"registered_connection_verified":true,"selected_game_received":true,"sender_and_session_filtered":true,"ordinary_message_contents_saved":false}));
                    } else {
                        emit(json!({"type":"test_receive_wait","message":"No verified reply from the selected game arrived during this receive window. No game turn was sent.","failure_stage":received["stage"],"numeric_code":received["numeric_code"],"registered_connection_verified":received["registered_connection_verified"]}));
                    }
                    Ok::<(),ids_access::Failure>(())
                }.await;
                if let Err(e)=result {emit(json!({"type":"test_receive_wait","message":"The scoped receive check stopped. No game turn was sent.","failure_stage":e.stage,"numeric_code":e.code}));}
            }
            "quit" => break,
            _ => {}
        }
    }
    drop(account_certificate);
    drop(ids_access);
}
