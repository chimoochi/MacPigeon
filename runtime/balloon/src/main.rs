// Local serializer only. No account, APNS, IDS, or network modules.
mod serializer;
use serializer::{Balloon, BalloonLayout, NSDictionaryClass, ExtensionApp, gzip};
use std::io::{Read,Write};
use serde_json::{Value,json};
fn run()->Result<(),()> {
 let mut raw=Vec::new();std::io::stdin().take(1_048_577).read_to_end(&mut raw).map_err(|_|())?;
 if raw.len()>1_048_576{return Err(());}let v:Value=serde_json::from_slice(&raw).map_err(|_|())?;
 let routing="com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext";
 let mut app=if v["mode"]=="new_invitation" {
  let session=uuid::Uuid::parse_str(v["session"].as_str().ok_or(())?).map_err(|_|())?.to_string();
  let url=v["url"].as_str().filter(|s|s.starts_with("data:?")&&s.len()<131072).ok_or(())?.to_owned();
  ExtensionApp{name:"GamePigeon".into(),app_id:None,bundle_id:routing.into(),balloon:Some(Balloon{url,session:Some(session),layout:None,ld_text:None,is_live:false,icon:None})}
 }else{
  let payload:Vec<u8>=v["payload"].as_array().ok_or(())?.iter().map(|b|b.as_u64().filter(|n|*n<256).map(|n|n as u8).ok_or(())).collect::<Result<_,_>>()?;
  if payload.len()>262144 || !payload.starts_with(b"bplist00"){return Err(());}
  ExtensionApp::from_bp(&gzip(&payload).map_err(|_|())?,routing).map_err(|_|())?
 };
 let balloon=app.balloon.as_mut().ok_or(())?;
 let session=balloon.session.clone().ok_or(())?;
 if uuid::Uuid::parse_str(&session).map_err(|_|())?!=uuid::Uuid::parse_str(v["session"].as_str().ok_or(())?).map_err(|_|())?{return Err(());}
 balloon.url=v["url"].as_str().filter(|s|s.starts_with("data:?")&&s.len()<131072).ok_or(())?.to_owned();
 let url=balloon.url.clone();balloon.icon=None;balloon.is_live=false;balloon.ld_text=None;
 let caption=v["caption"].as_str().unwrap_or("Four in a Row");
 // Game support is checked by the adapters; serialization only bounds display text.
 if caption.is_empty() || caption.len()>128 || caption.chars().any(char::is_control){return Err(());}
 balloon.layout=Some(BalloonLayout::TemplateLayout{image_subtitle:String::new(),image_title:String::new(),caption:caption.into(),secondary_subcaption:String::new(),tertiary_subcaption:String::new(),subcaption:String::new(),class:NSDictionaryClass::NSMutableDictionary});
 let (_,wire)=app.to_raw(false).map_err(|_|())?;let wire=wire.ok_or(())?;
 let checked=ExtensionApp::from_bp(&wire,routing).map_err(|_|())?;let b=checked.balloon.ok_or(())?;
 if b.url!=url || b.session!=Some(session) || b.icon.is_some() || b.is_live{return Err(());}
 serde_json::to_writer(std::io::stdout(),&json!({"wire":wire})).map_err(|_|())?;std::io::stdout().write_all(b"\n").map_err(|_|())?;Ok(())
}
fn main(){if run().is_err(){eprintln!("Selected game serialization failed.");std::process::exit(1);}}
