//! A private, persistent receive worker. Validation is supplied only at connect.
use std::{io::{BufRead, BufReader, Read, Write}, process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver}, time::{Duration, Instant}};
use serde_json::{json, Value};
use zeroize::Zeroize;
use crate::{ids_access::{Failure, fail}, receive_control::ReceiveControl};

pub struct ReceiveSession {
    child: Child,
    input: ChildStdin,
    output: Receiver<Value>,
    healthy: bool,
}
impl ReceiveSession {
    pub fn connect(request: Value, control: &ReceiveControl) -> Result<Self, Failure> {
        let exe=std::env::current_exe().map_err(|_|fail("delivery_worker_path"))?;
        let path=exe.parent().ok_or(fail("delivery_worker_path"))?.join("macpigeon-transport");
        let mut command=Command::new(path);
        command.arg("--receive-session").env_clear().env("LANG","en_US.UTF-8");
        let mut session=Self::spawn(command)?;
        let reply=session.request(request,control)?;
        if reply["ok"]!=true {return Err(fail("receive_connect_failed"));}
        Ok(session)
    }
    fn spawn(mut command: Command) -> Result<Self, Failure> {
        let mut child=command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
            .spawn().map_err(|_|fail("delivery_worker_start"))?;
        let input=child.stdin.take().ok_or(fail("delivery_worker_pipe"))?;
        let stdout=child.stdout.take().ok_or(fail("delivery_worker_pipe"))?;
        let (send,output)=mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut reader=BufReader::new(stdout);
            loop {
                let mut bytes=Vec::new();
                let read=Read::by_ref(&mut reader).take(1_048_577).read_until(b'\n',&mut bytes);
                if read.is_err()||bytes.is_empty()||bytes.len()>1_048_576 {bytes.zeroize();break;}
                let parsed=serde_json::from_slice::<Value>(&bytes);bytes.zeroize();
                match parsed {Ok(value)=>if send.send(value).is_err(){break},Err(_)=>break}
            }
        });
        Ok(Self{child,input,output,healthy:true})
    }
    pub fn healthy(&self)->bool {self.healthy}
    pub fn request(&mut self,mut request:Value,control:&ReceiveControl)->Result<Value,Failure> {
        if !self.healthy {return Err(fail("receive_connection_closed"));}
        control.check()?;
        let id=uuid::Uuid::new_v4().to_string();request["request_id"]=json!(id);
        let polling=request["action"]=="poll_receive";
        let written=serde_json::to_writer(&mut self.input,&request)
            .and_then(|_|self.input.write_all(b"\n").map_err(serde_json::Error::io));
        request.take();
        if written.is_err(){self.healthy=false;return Err(fail("delivery_worker_pipe"));}
        let mut cancellation_deadline=None;
        loop {
            match self.output.recv_timeout(Duration::from_millis(25)) {
                Ok(reply)=>{
                    if reply["request_id"].as_str()!=Some(id.as_str()) {
                        self.healthy=false;return Err(fail("delivery_worker_schema"));
                    }
                    if reply["connection_alive"]==false {self.healthy=false;}
                    return Ok(reply);
                }
                Err(mpsc::RecvTimeoutError::Disconnected)=>{
                    self.healthy=false;return Err(fail("receive_connection_closed"));
                }
                Err(mpsc::RecvTimeoutError::Timeout)=>{}
            }
            if let Err(error)=control.check() {
                // The live worker notices the same cancellation marker. Give it
                // time to return a framed reply without destroying the connection.
                if polling&&error.stage=="receive_cancelled" {
                    let deadline=cancellation_deadline.get_or_insert(Instant::now()+Duration::from_secs(2));
                    if Instant::now()<*deadline {continue;}
                }
                self.healthy=false;let _=self.child.kill();let _=self.child.wait();return Err(error);
            }
        }
    }
}
impl Drop for ReceiveSession {
    fn drop(&mut self){let _=self.child.kill();let _=self.child.wait();}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repeated_polls_reuse_one_connection_and_never_include_validation(){
        let script=r#"import sys,json
connects=0
for line in sys.stdin:
 v=json.loads(line)
 if v['action']=='connect_receive':
  assert 'validation' in v;connects+=1
 elif v['action']=='poll_receive':
  assert connects==1 and 'validation' not in v and 'state' not in v
 else: raise Exception('unexpected action')
 print(json.dumps(dict(ok=True,request_id=v['request_id'],connects=connects,connection_alive=True)),flush=True)
"#;
        let mut command=Command::new("python3");command.args(["-u","-c",script]);
        let mut session=ReceiveSession::spawn(command).unwrap_or_else(|_|panic!("worker start"));
        let control=ReceiveControl::new(None).unwrap_or_else(|_|panic!("control"));
        let connected=session.request(json!({"action":"connect_receive","validation":"offline fixture"}),&control)
            .unwrap_or_else(|_|panic!("connect"));
        assert_eq!(connected["connects"],1);
        for _ in 0..5 {
            let reply=session.request(json!({"action":"poll_receive"}),&control).unwrap_or_else(|_|panic!("poll"));
            assert_eq!(reply["connects"],1);assert!(session.healthy());
        }
    }
    #[test]
    fn cancelling_a_poll_preserves_the_worker_for_the_next_poll(){
        let path=std::env::temp_dir().join(format!("macpigeon-live-cancel-{}",uuid::Uuid::new_v4()));
        let script=r#"import sys,json,time,pathlib
marker=pathlib.Path(sys.argv[1])
connected=False
for line in sys.stdin:
 v=json.loads(line)
 if v['action']=='connect_receive': connected=True
 else:
  assert connected and 'validation' not in v
  if v.get('wait_cancel'):
   while not marker.exists(): time.sleep(.01)
 print(json.dumps(dict(ok=False,request_id=v['request_id'],connection_alive=True,stage='receive_cancelled' if v.get('wait_cancel') else 'receive_window_ended')),flush=True)
"#;
        let mut command=Command::new("python3");command.args(["-u","-c",script,path.to_str().unwrap()]);
        let mut session=ReceiveSession::spawn(command).unwrap_or_else(|_|panic!("worker start"));
        let control=ReceiveControl::for_test(None);
        session.request(json!({"action":"connect_receive"}),&control).unwrap_or_else(|_|panic!("connect"));
        let cancel=ReceiveControl::for_test(Some(path.clone()));
        let sender_path=path.clone();
        let sender=std::thread::spawn(move||{std::thread::sleep(Duration::from_millis(100));std::fs::write(sender_path,b"").unwrap();});
        let reply=session.request(json!({"action":"poll_receive","wait_cancel":true}),&cancel).unwrap_or_else(|_|panic!("cancel reply"));
        sender.join().unwrap();assert_eq!(reply["stage"],"receive_cancelled");assert!(session.healthy());
        drop(cancel);assert!(!path.exists());
        session.request(json!({"action":"poll_receive"}),&control).unwrap_or_else(|_|panic!("poll after cancel"));
        assert!(session.healthy());
    }
    #[test]
    fn a_closed_worker_is_invalidated_instead_of_reusing_a_dead_connection(){
        let mut command=Command::new("python3");command.args(["-c","import sys;sys.stdin.readline()"]);
        let mut session=ReceiveSession::spawn(command).unwrap_or_else(|_|panic!("worker start"));
        let control=ReceiveControl::new(None).unwrap_or_else(|_|panic!("control"));
        assert!(session.request(json!({"action":"poll_receive"}),&control).is_err());
        assert!(!session.healthy());
    }
}
