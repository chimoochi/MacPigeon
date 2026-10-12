//! Development transport worker, private pipes only; never shell interpolation.
use std::{io::Write,process::{Command,Stdio}};
use serde_json::Value;
use zeroize::Zeroize;
use crate::ids_access::{Failure,fail};
pub fn worker(request:Value)->Result<Value,Failure> {
    run_worker(request,None)
}
pub fn receive_validation(control:&crate::receive_control::ReceiveControl)->Result<String,Failure> {
    control.check()?;
    let exe=std::env::current_exe().map_err(|_|fail("delivery_worker_path"))?;
    let home=std::env::var("HOME").map_err(|_|fail("support_path"))?;
    // Native validation can block its thread on Apple's handshake. Isolate it
    // so cancelling a passive receive can stop that handshake immediately too.
    let child=Command::new(exe).arg("--receive-validation").env_clear()
        .env("HOME",home).env("LANG","en_US.UTF-8")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().map_err(|_|fail("delivery_worker_start"))?;
    let mut out=crate::receive_control::wait_output(child,control)?;
    let parsed=serde_json::from_slice::<Value>(&out.stdout);out.stdout.zeroize();
    let mut value=parsed.map_err(|_|fail("delivery_worker_schema"))?;
    if !out.status.success()||value["ok"]!=true {return Err(fail("receive_validation_failed"));}
    value["validation"].take().as_str().map(str::to_owned).ok_or(fail("delivery_worker_schema"))
}
pub fn receive_worker(request:Value,control:&crate::receive_control::ReceiveControl)->Result<Value,Failure> {
    control.check()?;
    run_worker(request,Some(control))
}
fn run_worker(mut request:Value,control:Option<&crate::receive_control::ReceiveControl>)->Result<Value,Failure> {
    let exe=std::env::current_exe().map_err(|_|fail("delivery_worker_path"))?;
    let path=exe.parent().ok_or(fail("delivery_worker_path"))?.join("macpigeon-transport");
    let mut child=Command::new(path).env_clear().env("LANG","en_US.UTF-8")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|_|fail("delivery_worker_start"))?;
    let mut input=child.stdin.take().ok_or(fail("delivery_worker_pipe"))?;
    let written=serde_json::to_writer(&mut input,&request).and_then(|_|input.write_all(b"\n").map_err(serde_json::Error::io));
    // Drop sensitive JSON immediately after private serialization.
    request.take();drop(input);
    if written.is_err(){let _=child.kill();let _=child.wait();return Err(fail("delivery_worker_pipe"));}
    let mut out=if let Some(control)=control {crate::receive_control::wait_output(child,control)?}else{child.wait_with_output().map_err(|_|fail("delivery_worker_exit"))?};
    if !out.status.success()||out.stdout.len()>1_048_576 {out.stdout.zeroize();return Err(fail("delivery_worker_exit"));}
    let parsed=serde_json::from_slice(&out.stdout);out.stdout.zeroize();parsed.map_err(|_|fail("delivery_worker_schema"))
}

pub fn python_game(request:Value,script:&str)->Result<Value,Failure> {
    let exe=std::env::current_exe().map_err(|_|fail("game_decoder_path"))?;
    let resources=exe.parent().and_then(|p|p.parent()).map(|p|p.join("Resources")).ok_or(fail("game_decoder_path"))?;
    let (python,scripts)=if resources.join(script).exists() {
        let runtime=std::fs::read_to_string(resources.join("python-runtime-path.txt")).map_err(|_|fail("game_decoder_path"))?;
        let python=if runtime.trim()=="@bundled" {resources.join("python-runtime")}else{std::path::PathBuf::from(runtime.trim())};
        (python,resources)
    } else {return Err(fail("game_resources_missing"));};
    let mut child=Command::new(python).arg("-I").arg("-B").arg("-c")
        .arg("import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_path(sys.argv[2],run_name='__main__')")
        .arg(&scripts).arg(scripts.join(script))
        .env_clear().stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|_|fail("game_decoder_start"))?;
    let mut input=child.stdin.take().ok_or(fail("game_decoder_pipe"))?;
    serde_json::to_writer(&mut input,&request).map_err(|_|fail("game_decoder_pipe"))?;
    input.write_all(b"\n").map_err(|_|fail("game_decoder_pipe"))?;drop(input);
    let mut out=child.wait_with_output().map_err(|_|fail("game_decoder_exit"))?;
    // Prepared states contain both URLs, replay fields and serialized wire data.
    // Their JSON reply can exceed the size of the incoming native request.
    if !out.status.success()||out.stdout.len()>1_048_576 {out.stdout.zeroize();return Err(fail("game_decoder_exit"));}
    let parsed=serde_json::from_slice::<Value>(&out.stdout);out.stdout.zeroize();let mut parsed=parsed.map_err(|_|fail("game_decoder_schema"))?;
    if parsed["ok"]!=true {return Err(fail("game_decoder_schema"));}Ok(parsed)
}

pub fn decode_selected_turn(url:&str)->Result<Value,Failure> {let mut v=python_game(serde_json::json!({"url":url}),"decode_one_live_turn.py")?;Ok(v["sanitized_game"].take())}
pub fn game(request:Value)->Result<Value,Failure>{let mut v=python_game(request,"game_session.py")?;Ok(v["state"].take())}
