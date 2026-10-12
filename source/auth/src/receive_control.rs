//! Cancellation and a total deadline for passive receive checks only.
use std::{io::Read, path::PathBuf, process::{Child, Output}, time::{Duration, Instant}};
use zeroize::Zeroize;
use crate::ids_access::{Failure, fail};

pub struct ReceiveControl {
    cancel_path: Option<PathBuf>,
    deadline: Instant,
}
impl ReceiveControl {
    pub fn new(id: Option<&str>) -> Result<Self, Failure> {
        let cancel_path = match id {
            Some(id) => {
                let id = uuid::Uuid::parse_str(id).map_err(|_| fail("receive_id"))?;
                let home = std::env::var("HOME").map_err(|_| fail("support_path"))?;
                Some(PathBuf::from(home).join("Library/Application Support/MacPigeon/Transport")
                    .join(format!("receive-cancel-{}", id.to_string().to_uppercase())))
            }
            None => None,
        };
        Ok(Self { cancel_path, deadline: Instant::now() + Duration::from_secs(30) })
    }
    pub fn check(&self) -> Result<(), Failure> {
        if self.cancel_path.as_ref().map(|p| p.exists()).unwrap_or(false) {
            return Err(fail("receive_cancelled"));
        }
        if Instant::now() >= self.deadline { return Err(fail("receive_check_timeout")); }
        Ok(())
    }
}
impl Drop for ReceiveControl {
    fn drop(&mut self) {
        if let Some(path) = &self.cancel_path { let _ = std::fs::remove_file(path); }
    }
}

pub fn wait_output(mut child: Child, control: &ReceiveControl) -> Result<Output, Failure> {
    let stdout = child.stdout.take().ok_or(fail("delivery_worker_pipe"))?;
    // Drain while polling: a normal state reply can be larger than the pipe buffer.
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take(1_048_577).read_to_end(&mut bytes);
        (result, bytes)
    });
    let status = loop {
        if let Err(error) = control.check() {
            let _ = child.kill(); let _ = child.wait();
            if let Ok((_, mut bytes)) = reader.join() { bytes.zeroize(); }
            return Err(error);
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
            Err(_) => {
                let _ = child.kill(); let _ = child.wait();
                if let Ok((_, mut bytes)) = reader.join() { bytes.zeroize(); }
                return Err(fail("delivery_worker_exit"));
            }
        }
    };
    let (read, mut stdout) = reader.join().map_err(|_| fail("delivery_worker_exit"))?;
    if read.is_err() { stdout.zeroize(); return Err(fail("delivery_worker_exit")); }
    Ok(Output { status, stdout, stderr: Vec::new() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    fn control(path: Option<PathBuf>, millis: u64) -> ReceiveControl {
        ReceiveControl { cancel_path: path, deadline: Instant::now() + Duration::from_millis(millis) }
    }
    #[test]
    fn stuck_worker_is_killed_at_total_deadline() {
        let child = Command::new("/bin/sleep").arg("30").stdout(Stdio::piped()).spawn().unwrap();
        let started = Instant::now();
        let error = wait_output(child, &control(None, 100)).err().unwrap();
        assert_eq!(error.stage, "receive_check_timeout");
        assert!(started.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn invitation_cancels_a_stuck_worker_without_waiting_for_deadline() {
        let path = std::env::temp_dir().join(format!("macpigeon-cancel-test-{}", uuid::Uuid::new_v4()));
        let child = Command::new("/bin/sleep").arg("30").stdout(Stdio::piped()).spawn().unwrap();
        let sender_path = path.clone();
        let sender = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100)); std::fs::write(sender_path, b"").unwrap();
        });
        let started = Instant::now();
        let error = wait_output(child, &control(Some(path.clone()), 30_000)).err().unwrap();
        sender.join().unwrap();
        assert_eq!(error.stage, "receive_cancelled");
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(!path.exists());
    }
    #[test]
    fn large_normal_reply_does_not_block_on_pipe_capacity() {
        let child = Command::new("python3").args(["-c", "import sys;sys.stdout.write('x'*200000)"])
            .stdout(Stdio::piped()).spawn().unwrap();
        let output = wait_output(child, &control(None, 5000)).unwrap_or_else(|_| panic!("normal reply failed"));
        assert!(output.status.success()); assert_eq!(output.stdout.len(), 200000);
    }
}
