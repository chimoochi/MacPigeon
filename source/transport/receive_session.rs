//! Keep the push connection alive; polling supplies only the selected game scope.
use super::*;
use std::{collections::VecDeque, io::Read, path::PathBuf};
use tokio::sync::{broadcast, mpsc};

struct Scope { recipient:String, session:String, excluded:Vec<String> }
impl Scope {
    fn read(v:&Json)->Result<Self>{
        let recipient=v["recipient"].as_str().filter(|s|s.starts_with("tel:+")&&s.len()>5&&s[5..].bytes().all(|b|b.is_ascii_digit())).ok_or("recipient_schema")?.to_owned();
        let session=uuid::Uuid::parse_str(v["session_hex"].as_str().ok_or("session_schema")?).map_err(|_|"session_schema")?.to_string();
        let excluded=v["excluded_url_hashes"].as_array().map(|a|a.iter().filter_map(|v|v.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        Ok(Self{recipient,session,excluded})
    }
    fn matches(&self,msg:&rustpush::APSMessage,phone:&str)->bool {
        let rustpush::APSMessage::Notification{payload,..}=msg else{return false};
        let Some(outer)=payload.as_dictionary() else{return false};
        outer.get("sP").and_then(Value::as_string)==Some(self.recipient.as_str())&&
            outer.get("tP").and_then(Value::as_string)==Some(phone)&&
            outer.get("c").and_then(Value::as_unsigned_integer)==Some(100)&&
            outer.get("P").and_then(Value::as_data).map(|b|b.len()<=262144).unwrap_or(false)
    }
}
fn poll_scope(v:&Json)->Result<Scope>{
    if v.get("validation").is_some()||v.get("state").is_some(){return Err("poll_setup_not_allowed");}
    if v["keychain_saved"]!=true||v["test_receive_authorized"]!=true{return Err("receive_authorization_required");}
    Scope::read(v)
}
struct LiveReceiver {
    saved:Saved,
    snapshot:Arc<Mutex<SoftwareKeystoreState>>,
    conn:rustpush::APSConnection,
    client:rustpush::IMClient,
    messages:broadcast::Receiver<rustpush::APSMessage>,
    pending:VecDeque<rustpush::APSMessage>,
    scope:Scope,
    directory:PathBuf,
    history_gap:bool,
}
impl LiveReceiver {
    async fn connect(v:&Json)->Result<Self>{
        if v["keychain_saved"]!=true||v["test_receive_authorized"]!=true {return Err("receive_authorization_required");}
        let scope=Scope::read(v)?;
        let saved:Saved=plist::from_bytes(&b64(v,"state")?).map_err(|_|"state_schema")?;
        if saved.version!=1||saved.user.registration.get("com.apple.madrid").map(|r|r.handles!=vec![saved.phone.clone()]).unwrap_or(true) {return Err("registered_phone_required");}
        let snapshot=store(copy_store(&saved.store));
        let mut config=Config::read(b64(v,"validation")?)?;config.phone=saved.phone.clone();let config:Arc<dyn OSConfig>=Arc::new(config);
        let (conn,error)=tokio::time::timeout(Duration::from_secs(25),rustpush::APSConnectionResource::new(config.clone(),Some(saved.push.clone()))).await.map_err(|_|"push_connection_timeout")?;
        if let Some(error)=error {return Err(connection_error(&error).0);}
        let messages=conn.subscribe().await;
        let directory=PathBuf::from(v["support_directory"].as_str().ok_or("cache_path")?);
        std::fs::create_dir_all(&directory).map_err(|_|"cache_path")?;
        use std::os::unix::fs::{PermissionsExt,OpenOptionsExt};
        std::fs::set_permissions(&directory,std::fs::Permissions::from_mode(0o700)).map_err(|_|"cache_permissions")?;
        let cache=directory.join("delivery-cache.plist");
        std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&cache).map_err(|_|"cache_path")?;
        std::fs::set_permissions(&cache,std::fs::Permissions::from_mode(0o600)).map_err(|_|"cache_permissions")?;
        static SERVICES:&[&rustpush::IDSService]=&[&MADRID_SERVICE];
        let client=rustpush::IMClient::new(conn.clone(),vec![saved.user.clone()],saved.identity.clone(),SERVICES,cache,config,Box::new(|_|{})).await;
        if client.identity.get_handles().await!=vec![saved.phone.clone()] {return Err("sender_binding");}
        Ok(Self{saved,snapshot,conn,client,messages,pending:VecDeque::new(),scope,directory,history_gap:false})
    }
    fn enqueue(&mut self,msg:rustpush::APSMessage){
        if self.scope.matches(&msg,&self.saved.phone) {
            if self.pending.len()==64 {self.history_gap=true;return;}
            self.pending.push_back(msg);
        }
    }
    async fn snapshot(&mut self)->Result<String>{
        self.saved.push=self.conn.state.read().await.clone();
        self.saved.user=self.client.identity.users.read().await[0].clone();
        self.saved.store=copy_store(&self.snapshot.lock().unwrap());
        Ok(STANDARD.encode(bin(&self.saved)?))
    }
    async fn decode(&self,msg:rustpush::APSMessage)->(Option<String>,bool){
        let routing="com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext";
        let Ok(Some(mut received))=self.client.identity.receive_message(msg,&["com.apple.madrid"]).await else{return (None,false)};
        if received.verification_failed {return (None,true);}
        let Some(body)=received.message_unenc.take() else{return (None,false)};
        let Ok(inner)=body.plist::<Value>() else{return (None,false)};
        let Some(inner)=inner.as_dictionary() else{return (None,false)};
        if inner.get("bid").and_then(Value::as_string)!=Some(routing) {return (None,false);}
        let Some(bp)=inner.get("bp").and_then(Value::as_data).filter(|b|b.len()<262144) else{return (None,false)};
        let Ok(app)=rustpush::ExtensionApp::from_bp(bp,routing) else{return (None,false)};
        let Some(balloon)=app.balloon else{return (None,false)};
        if balloon.session.as_deref()!=Some(self.scope.session.as_str()) {return (None,false);}
        let digest=format!("{:x}",sha2::Sha256::digest(balloon.url.as_bytes()));
        if self.scope.excluded.iter().any(|hash|hash==&digest) {return (None,false);}
        (Some(balloon.url),false)
    }
    async fn poll(&mut self,v:&Json)->Result<Json>{
        // A message poll cannot inject fresh credentials or trigger validation.
        self.scope=poll_scope(v)?;
        if matches!(*self.conn.resource_state.borrow(),rustpush::ResourceState::Failed(_)|rustpush::ResourceState::Closed) {
            return Err("receive_connection_closed");
        }
        if matches!(*self.client.identity.resource_state.borrow(),rustpush::ResourceState::Failed(_)|rustpush::ResourceState::Closed) {
            return Err("receive_connection_closed");
        }
        if self.history_gap{return Err("receive_history_gap");}
        self.pending.retain(|msg|self.scope.matches(msg,&self.saved.phone));
        let cancel_path=match v["receive_id"].as_str() {
            Some(id)=>Some(self.directory.join(format!("receive-cancel-{}",uuid::Uuid::parse_str(id).map_err(|_|"receive_id")?.to_string().to_uppercase()))),
            None=>None,
        };
        let deadline=tokio::time::sleep(Duration::from_secs(1));tokio::pin!(deadline);
        let mut matched=None;let mut verification_failed=false;let mut cancelled=false;
        loop {
            if cancel_path.as_ref().map(|p|p.exists()).unwrap_or(false){cancelled=true;break;}
            if deadline.is_elapsed(){break;}
            let msg=if let Some(msg)=self.pending.pop_front(){msg}else{
                tokio::select!{
                    biased;
                    _=&mut deadline=>break,
                    _=tokio::time::sleep(Duration::from_millis(25))=>continue,
                    msg=self.messages.recv()=>match msg {
                        Ok(msg)=>msg,
                        Err(broadcast::error::RecvError::Lagged(_))=>return Err("receive_history_gap"),
                        Err(broadcast::error::RecvError::Closed)=>return Err("receive_connection_closed"),
                    },
                }
            };
            if !self.scope.matches(&msg,&self.saved.phone){continue;}
            let backup=msg.clone();
            // Preserve the packet if cancellation interrupts key lookup/decryption.
            let decoded=tokio::select! {
                biased;
                _=cancelled_at(&cancel_path)=>None,
                value=tokio::time::timeout(Duration::from_secs(10),self.decode(msg))=>Some(value),
            };
            match decoded {
                None=>{self.pending.push_front(backup);cancelled=true;break;}
                Some(Err(_))=>{self.pending.push_front(backup);return Err("receive_decode_timeout");}
                Some(Ok((url,failed)))=>{verification_failed|=failed;if url.is_some(){matched=url;break;}}
            }
        }
        Ok(json!({"ok":matched.is_some(),"stage":if cancelled{"receive_cancelled"}else if matched.is_some(){"selected_game_received"}else{"receive_window_ended"},
            "state":self.snapshot().await?,"url":matched,"connection_alive":true,"registered_connection_verified":true,
            "ordinary_message_contents_saved":false,"sender_and_session_filtered":true,"verification_failed":verification_failed,"send_called":false}))
    }
}
async fn cancelled_at(path:&Option<PathBuf>){
    loop {
        if path.as_ref().map(|p|p.exists()).unwrap_or(false){return;}
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}
pub async fn serve(){
    // Stdin is read on a separate thread so socket and keepalive tasks continue
    // running while the parent is idle or handling other app commands.
    let (send,mut commands)=mpsc::channel(2);
    std::thread::spawn(move||{
        let mut input=io::stdin().lock();
        loop {
            let mut bytes=Vec::new();
            let read=Read::by_ref(&mut input).take(1_048_577).read_until(b'\n',&mut bytes);
            if read.is_err()||bytes.is_empty()||bytes.len()>1_048_576{break;}
            let Ok(value)=serde_json::from_slice::<Json>(&bytes) else{break;};
            if send.blocking_send(value).is_err(){break;}
        }
    });
    let Some(mut first)=commands.recv().await else{return;};
    let id=first["request_id"].clone();
    if first["action"]!="connect_receive"{emit(json!({"ok":false,"stage":"receive_connect_required","request_id":id,"connection_alive":false}));return;}
    let mut live=match LiveReceiver::connect(&first).await{
        Ok(live)=>live,
        Err(stage)=>{emit(json!({"ok":false,"stage":stage,"request_id":id,"connection_alive":false,"send_called":false}));return;}
    };
    first.take();
    emit(json!({"ok":true,"stage":"receive_connected","request_id":id,"connection_alive":true,"send_called":false}));
    loop {tokio::select!{
        command=commands.recv()=>{
            let Some(command)=command else{break;};
            let id=command["request_id"].clone();
            if command["action"]!="poll_receive"{emit(json!({"ok":false,"stage":"receive_poll_required","request_id":id,"connection_alive":true,"send_called":false}));continue;}
            match live.poll(&command).await {
                Ok(mut reply)=>{reply["request_id"]=id;emit(reply);}
                Err(stage)=>{
                    let retryable=stage=="receive_decode_timeout";
                    emit(json!({"ok":false,"stage":stage,"request_id":id,"connection_alive":retryable,"send_called":false}));
                    if !retryable{break;}
                }
            }
        }
        message=live.messages.recv()=>match message {
            Ok(message)=>live.enqueue(message),
            Err(broadcast::error::RecvError::Lagged(_))=>break,
            Err(broadcast::error::RecvError::Closed)=>break,
        },
    }}
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request()->Json {json!({"keychain_saved":true,"test_receive_authorized":true,"recipient":"tel:+15555550123","session_hex":uuid::Uuid::new_v4().to_string()})}
    fn message(sender:&str,target:&str,kind:u64)->rustpush::APSMessage{
        rustpush::APSMessage::Notification{id:1,topic:[0;20],token:None,channel:None,
            payload:dict([("sP",Value::String(sender.into())),("tP",Value::String(target.into())),("c",Value::Integer(kind.into())),("P",Value::Data(vec![0]))])}
    }
    #[test]
    fn message_polls_cannot_perform_setup_or_supply_credentials(){
        let base=request();assert!(poll_scope(&base).is_ok());
        for field in ["validation","state"]{
            let mut v=base.clone();v[field]=json!("not accepted during a message poll");
            assert_eq!(poll_scope(&v).err(),Some("poll_setup_not_allowed"));
        }
    }
    #[test]
    fn routing_excludes_other_senders_targets_and_commands_before_decryption(){
        let scope=Scope::read(&request()).unwrap();let phone="tel:+15555550999";
        assert!(scope.matches(&message(&scope.recipient,phone,100),phone));
        assert!(!scope.matches(&message("tel:+15555550000",phone,100),phone));
        assert!(!scope.matches(&message(&scope.recipient,"tel:+15555550000",100),phone));
        assert!(!scope.matches(&message(&scope.recipient,phone,101),phone));
    }
}
