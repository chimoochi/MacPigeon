// Extracted from pinned OpenBubbles/RustPush; see LICENSE files.
#![allow(dead_code)]
use std::{collections::HashMap, io::{Cursor, Read, Write}, ops::Deref, str::FromStr};
use serde::{Serialize, Deserialize, ser::Serializer};
use plist::{Value, Dictionary, Data, Uid, Error};
use uuid::Uuid;
use libflate::gzip::{HeaderBuilder, EncodeOptions, Encoder, Decoder};
macro_rules! debug { ($($arg:tt)*) => {}; }
#[derive(Debug, thiserror::Error)]
pub enum PushError {
    #[error("archive failure")] KeyedArchiveError(String),
    #[error("plist failure")] Plist(#[from] plist::Error),
    #[error("compression failure")] Io(#[from] std::io::Error),
}
#[derive(Serialize, Deserialize)]
struct KeyedArchiveClass {
    #[serde(rename = "$classname")]
    classname: String,
    #[serde(rename = "$classes", default)]
    classes: Vec<String>,
    #[serde(rename = "$classhints", default, skip_serializing_if = "Vec::is_empty")]
    class_hints: Vec<String>,
}

#[derive(Serialize, Deserialize)]
pub struct KeyedArchive {
    #[serde(rename = "$version")]
    version: u64,
    #[serde(rename = "$objects")]
    objects: Vec<Value>,
    #[serde(rename = "$archiver")]
    archiver: String,
    #[serde(rename = "$top")]
    top: HashMap<String, Uid>,

    #[serde(skip)]
    class_uids: HashMap<String, (Uid, &'static ClassData)>,
}

struct ClassData {
    name: &'static str,
    classes: &'static [&'static str],
    uid_fields: &'static [&'static str],
}

const CLASS_SPECS: &[ClassData] = &[
    ClassData {
        name: "NSMutableDictionary",
        classes: &["NSMutableDictionary", "NSDictionary", "NSObject"],
        uid_fields: &[],
    },
    ClassData {
        name: "NSDictionary",
        classes: &["NSDictionary", "NSObject"],
        uid_fields: &[],
    },
    ClassData {
        name: "NSURL",
        classes: &["NSURL", "NSObject"],
        uid_fields: &["NS.base", "NS.relative"],
    },
    ClassData {
        name: "NSMutableData",
        classes: &["NSMutableData", "NSData", "NSObject"],
        uid_fields: &[],
    },
    ClassData {
        name: "NSUUID",
        classes: &["NSUUID", "NSObject"],
        uid_fields: &[],
    },
    ClassData {
        name: "NSMutableArray",
        classes: &["NSMutableArray", "NSArray", "NSObject"],
        uid_fields: &["NS.objects"],
    },
    ClassData {
        name: "LPLinkMetadata",
        classes: &["LPLinkMetadata", "NSObject"],
        uid_fields: &[
            "imageMetadata",
            "iconMetadata",
            "originalURL",
            "URL",
            "title",
            "summary",
            "image",
            "icon",
            "images",
            "icons",
            "specialization2"
        ]
    },
    ClassData {
        name: "LPPasswordsInviteMetadata",
        classes: &["LPPasswordsInviteMetadata", "LPSpecializationMetadata", "NSObject"],
        uid_fields: &[
            "groupName",
            "urlParameters"
        ]
    },
    ClassData {
        name: "RichLink",
        classes: &["RichLink", "NSObject"],
        uid_fields: &["richLinkMetadata"],
    },
    ClassData {
        name: "LPImageMetadata",
        classes: &["LPImageMetadata", "NSObject"],
        uid_fields: &["size", "URL"],
    },
    ClassData {
        name: "LPIconMetadata",
        classes: &["LPIconMetadata", "NSObject"],
        uid_fields: &["URL"],
    },
    ClassData {
        name: "RichLinkImageAttachmentSubstitute",
        classes: &["RichLinkImageAttachmentSubstitute", "LPImage", "NSObject"],
        uid_fields: &["MIMEType"],
    },
    ClassData {
        name: "NSArray",
        classes: &["NSArray", "NSObject"],
        uid_fields: &["NS.objects"],
    },
    ClassData {
        name: "PRPosterTitleStyleConfiguration",
        classes: &["PRPosterTitleStyleConfiguration", "NSObject"],
        uid_fields: &[
            "preferredTitleLayout",
            "preferredTitleAlignment",
            "titleColor",
            "contentsLuminence",
            "groupName",
            "timeFontConfiguration",
            "timeNumberingSystem",
            "titleContentStyle",
        ]
    },
    ClassData {
        name: "PRPosterColor",
        classes: &["PRPosterColor", "NSObject"],
        uid_fields: &["preferredStyle", "identifier", "color"],
    },
    ClassData {
        name: "UIColor",
        classes: &["UIColor", "NSObject"],
        uid_fields: &[],
    },
    ClassData {
        name: "PRPosterContentDiscreteColorsStyle",
        classes: &["PRPosterContentDiscreteColorsStyle", "NSObject"],
        uid_fields: &["colors"],
    },
    ClassData {
        name: "PRPosterContentVibrantMaterialStyle",
        classes: &["PRPosterContentVibrantMaterialStyle", "NSObject"],
        uid_fields: &[]
    },
    ClassData {
        name: "PRPosterSystemTimeFontConfiguration",
        classes: &["PRPosterSystemTimeFontConfiguration", "PRPosterTimeFontConfiguration", "NSObject"],
        uid_fields: &["timeFontIdentifier", "weight"],
    },
    ClassData {
        name: "PFPosterMedia",
        classes: &["PFPosterMedia", "NSObject"],
        uid_fields: &["assetUUID", "editConfiguration", "subpath"],
    },
    ClassData {
        name: "PFPosterEditConfiguration",
        classes: &["PFPosterEditConfiguration", "NSObject"],
        uid_fields: &["style", "visibleFrame", "landscapeVisibleFrame"],
    },
    ClassData {
        name: "PFParallaxLayerStyle",
        classes: &["PFParallaxLayerStyle", "NSObject"],
        uid_fields: &["kind", "colorSuggestions", "parameters"],
    },
    ClassData {
        name: "PFParallaxColor",
        classes: &["PFParallaxColor", "NSObject"],
        uid_fields: &["rgbValues"],
    },
    ClassData {
        name: "PFWallpaperCompoundDeviceConfiguration",
        classes: &["PFWallpaperCompoundDeviceConfiguration", "NSObject"],
        uid_fields: &["portrait", "landscape"],
    },
    ClassData {
        name: "PFParallaxLayoutConfiguration",
        classes: &["PFParallaxLayoutConfiguration", "NSObject"],
        uid_fields: &["inactiveTimeRect", "timeRect", "screenSize", "parallaxPadding"],
    },
    ClassData {
        name: "PFPosterConfiguration",
        classes: &["PFPosterConfiguration", "NSObject"],
        uid_fields: &["media", "layoutConfiguration", "editConfiguration", "identifier", "userInfo"],
    },
    ClassData {
        name: "PRPosterContentGradientStyle",
        classes: &["PRPosterContentGradientStyle", "NSObject"],
        uid_fields: &["colors", "startPoint", "locations", "endPoint"],
    }
];

struct LegacyClassData {
    name: &'static str,
    classes: &'static [&'static str],
    version: u32
}

const LEGACY_SPECS: &[LegacyClassData] = &[
    LegacyClassData {
        name: "NSAttributedString",
        classes: &["NSAttributedString", "NSObject"],
        version: 0,
    },
    LegacyClassData {
        name: "NSString",
        classes: &["NSString", "NSObject"],
        version: 1,
    },
    LegacyClassData {
        name: "NSNumber",
        classes: &["NSNumber", "NSValue", "NSObject"],
        version: 0,
    },
    LegacyClassData {
        name: "NSDictionary",
        classes: &["NSDictionary", "NSObject"],
        version: 0,
    },
];

impl Default for KeyedArchive {
    fn default() -> Self {
        KeyedArchive {
            version: 100000,
            objects: vec![Value::String("$null".to_string())],
            archiver: "NSKeyedArchiver".to_string(),
            top: HashMap::from_iter([
                ("root".to_string(), Uid::new(0))
            ]),
            class_uids: HashMap::new(),
        }
    }
}

impl KeyedArchive {
    pub fn expand(archive: &[u8]) -> Result<HashMap<String, Value>, PushError> {
        let parsed: KeyedArchive = plist::from_bytes(archive)?;

        parsed.top.clone().into_iter().map(|(n, k)| Ok((n, parsed.expand_key(k)?))).collect()
    }

    pub fn expand_root(archive: &[u8]) -> Result<Value, PushError> {
        Ok(Self::expand(archive)?.remove("root").unwrap())
    }

    fn expand_dict(&self, value: &Value) -> Result<Dictionary, PushError> {
        #[derive(Serialize, Deserialize, Default)]
        struct ArchiveDict {
            #[serde(rename = "NS.keys")]
            keys: Vec<String>,
            #[serde(rename = "NS.objects")]
            objects: Vec<Value>,
        }
        
        let dict: ArchiveDict = plist::from_value(&value)?;
        
        let mut second = dict.objects.into_iter();
        let mut dict_result = Dictionary::new();
        for key in dict.keys.into_iter() {
            dict_result.insert(key, second.next().expect("different lengths?"));
        }

        Ok(dict_result)
    }

    fn expand_obj(&self, obj: &mut Value) -> Result<(), PushError> {
        let mut my_class = None;
        match obj {
            Value::Array(items) => {
                for item in items {
                    self.expand_obj(item)?
                }
            },
            Value::Dictionary(dict) => {
                for (key, item) in dict.iter_mut() {
                    if let ("$class", Value::Uid(uid)) = (key.as_str(), &item) {
                        let class: KeyedArchiveClass = plist::from_value(&self.objects[uid.get() as usize])?;
                        my_class = Some(class.classname.clone());
                        *item = Value::String(class.classname);
                        continue;
                    }
                    self.expand_obj(item)?
                }
            },
            Value::Uid(uid) => {
                *obj = self.expand_key(*uid)?;
            },
            _ => { /* nothing to do */ }
        }

        match my_class.as_ref().map(|i| i.as_str()) {
            Some("NSMutableDictionary") | Some("NSDictionary") => {
                let mut dict = self.expand_dict(obj)?;
                dict.insert("$class".to_string(), Value::String(my_class.clone().unwrap()));
                *obj = Value::Dictionary(dict);
            },
            _ => { /* nothing to do */ }
        }

        Ok(())
    }

    fn expand_key(&self, key: Uid) -> Result<Value, PushError> {
        let mut obj = self.objects[key.get() as usize].clone();

        self.expand_obj(&mut obj)?;

        Ok(obj)
    }

    fn archive_dict(&mut self, dict: Dictionary, class: &str) -> Result<Value, PushError> {
        #[derive(Serialize, Deserialize, Default)]
        struct ArchiveDict {
            #[serde(rename = "NS.keys")]
            keys: Vec<Uid>,
            #[serde(rename = "NS.objects")]
            objects: Vec<Uid>,
            #[serde(rename = "$class")]
            class: Option<Uid>,
        }
        let mut archive = ArchiveDict::default();

        for (key, item) in dict {
            if key == "$class" {
                continue
            }
            archive.keys.push(self.archive_key(Value::String(key), true)?);
            archive.objects.push(self.archive_key(item, true)?);
        }

        archive.class = Some(self.get_class_key(class)?.0);

        Ok(plist::to_value(&archive)?)
    }

    fn archive_key(&mut self, mut item: Value, archive: bool) -> Result<Uid, PushError> {
        match &item {
            Value::String(str) if str == "$null" => {
                return Ok(Uid::new(0))
            },
            _ => {}
        }
        if archive {
            self.archive_obj(&mut item)?;
        }
        let new_id = self.objects.len();
        self.objects.push(item);
        Ok(Uid::new(new_id as u64))
    }

    fn get_class_key(&mut self, class_name: &str) -> Result<(Uid, &'static ClassData), PushError> {
        if let Some(uid) = self.class_uids.get(class_name) {
            return Ok(*uid);
        }
        let spec = CLASS_SPECS.iter().find(|spec| spec.name == class_name).ok_or(PushError::KeyedArchiveError(format!("No spec found for {class_name}!")))?;
        let class = KeyedArchiveClass {
            classes: spec.classes.iter().map(|i| i.to_string()).collect(),
            classname: spec.name.to_string(),
            class_hints: if spec.name == "UIColor" { vec!["NSColor".to_string()] } else { vec![] },
        };
        let key = self.archive_key(plist::to_value(&class)?, false)?;
        self.class_uids.insert(class_name.to_string(), (key, spec));
        Ok((key, spec))
    }

    fn archive_obj(&mut self, item: &mut Value) -> Result<(), PushError> {
        match item {
            Value::Dictionary(dict) => {
                let Some(Value::String(class)) = dict.get("$class") else { panic!("No class?") };
                match class.as_str() {
                    "NSMutableDictionary" | "NSDictionary" => {
                        *item = self.archive_dict(dict.clone(), class)?;
                    },
                    _class => {
                        let (uid, class) = self.get_class_key(&_class)?;
                        dict.insert("$class".to_string(), Value::Uid(uid));
                        for item in class.uid_fields {
                            let Some(item_value) = dict.get_mut(*item) else { continue };
                            if let Value::Array(arr) = item_value {
                                for item in arr {
                                    *item = Value::Uid(self.archive_key(item.clone(), true)?)
                                }
                            } else {
                                *item_value = Value::Uid(self.archive_key(item_value.clone(), true)?);
                            }
                        }
                    }
                }
            },
            Value::Array(arr) => {
                for item in arr {
                    self.archive_obj(item)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    pub fn archive(items: HashMap<String, Value>) -> Result<Value, PushError> {
        if let Ok(archive) = plist_to_string(&items) { debug!("archiving {}", archive); }
        let mut archive = KeyedArchive::default();

        archive.top = items.into_iter().map(|(k, v)| Ok((k, archive.archive_key(v, true)?))).collect::<Result<HashMap<_, _>, PushError>>()?;

        Ok(plist::to_value(&archive)?)
    }

    pub fn archive_item(item: Value) -> Result<Value, PushError> {
        Self::archive(HashMap::from_iter([("root".to_string(), item)]))
    }

}



#[repr(C)]
#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum NSArrayClass {
    NSArray,
    NSMutableArray,
}

#[repr(C)]
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NSArray<T> {
    #[serde(rename = "NS.objects")]
    pub objects: Vec<T>,
    #[serde(rename = "$class")]
    pub class: NSArrayClass,
}

impl<T> Deref for NSArray<T> {
    type Target = Vec<T>;
    fn deref(&self) -> &Self::Target {
        &self.objects
    }
}

#[repr(C)]
#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum NSDictionaryClass {
    NSDictionary,
    NSMutableDictionary,
}

#[derive(Deserialize, Debug)]
pub struct NSDictionary<T> {
    #[serde(rename = "$class")]
    pub class: NSDictionaryClass,
    #[serde(flatten)]
    pub item: T,
}

impl<T: Serialize> Serialize for NSDictionary<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer {
        let mut serialized = plist::to_value(&self.item).map_err(serde::ser::Error::custom)?;
        let Some(dict) = serialized.as_dictionary_mut() else { panic!("not a dictionary!") };

        dict.insert("$class".to_string(), plist::to_value(&self.class).map_err(serde::ser::Error::custom)?);
        
        serialized.serialize(serializer)
    }
}

impl<T> Deref for NSDictionary<T> {
    type Target = T;
    fn deref(&self) -> &Self::Target {
        &self.item
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub enum NSDataClass {
    NSMutableData,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct NSData {
    #[serde(rename = "NS.data")]
    pub data: Data,
    #[serde(rename = "$class")]
    pub class: NSDataClass,
}

impl Deref for NSData {
    type Target = [u8];
    fn deref(&self) -> &Self::Target {
        &self.data.as_ref()
    }
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "$class")]
pub struct NSUUID {
    #[serde(rename = "NS.uuidbytes")]
    data: Data,
}

impl From<Uuid> for NSUUID {
    fn from(value: Uuid) -> Self {
        NSUUID { data: value.into_bytes().to_vec().into() }
    }
}

impl Into<Uuid> for NSUUID {
    fn into(self) -> Uuid {
        Uuid::from_bytes((*self).try_into().unwrap())
    }
}

impl Deref for NSUUID {
    type Target = [u8];
    fn deref(&self) -> &Self::Target {
        &self.data.as_ref()
    }
}


#[repr(C)]
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "$class")]
pub struct NSURL {
    #[serde(rename = "NS.base")]
    pub base: String,
    #[serde(rename = "NS.relative")]
    pub relative: String,
}

impl Into<String> for NSURL {
    fn into(mut self) -> String {
        if self.base == "$null" {
            self.base = "".to_string();
        }
        format!("{}{}", self.base, self.relative)
    }
}




pub fn plist_to_string<T: serde::Serialize>(value: &T) -> Result<String, Error> {
    plist_to_buf(value).map(|val| String::from_utf8(val).unwrap())
}

pub fn plist_to_buf<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_xml(writer, &value)?;
    Ok(buf)
}

pub fn plist_to_bin<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_binary(writer, &value)?;
    Ok(buf)
}

pub fn gzip(bytes: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    let header = HeaderBuilder::new().modification_time(0).finish();
    let options = EncodeOptions::new().header(header);
    let mut encoder = Encoder::with_options(Vec::new(), options)?;
    encoder.write_all(bytes)?;
    Ok(encoder.finish().into_result()?)
}

pub fn gzip_normal(bytes: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    let mut encoder = Encoder::new(Vec::new())?;
    encoder.write_all(bytes)?;
    Ok(encoder.finish().into_result()?)
}

pub fn ungzip(bytes: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    let mut decoder = Decoder::new(bytes)?;
    let mut decoded_data = Vec::new();
    decoder.read_to_end(&mut decoded_data)?;
    Ok(decoded_data)
}


#[derive(Deserialize, Serialize, Debug)]
#[serde(untagged)]
pub enum BalloonRawData {
    Wire(NSData),       // Gzipped/NSData
    Backup(Data),       // CloudKit
}

impl BalloonRawData {
    fn compress(mut self) -> Self {
        match &mut self {
            Self::Wire(data) => {
                data.data = gzip(data.data.as_ref()).unwrap().into();
            },
            Self::Backup(data) => { },
        }
        self
    }

    fn decompress(mut self) -> Self {
        match &mut self {
            Self::Wire(data) => {
                data.data = ungzip(data.data.as_ref()).unwrap().into();
            },
            Self::Backup(data) => { },
        }
        self
    }

    fn bytes(&self) -> &[u8] {
        match self {
            Self::Wire(data) => data.data.as_ref(),
            Self::Backup(data) => data.as_ref(),
        }
    }

    fn into_bytes(self) -> Vec<u8> {
        match self {
            Self::Wire(data) => data.data.into(),
            Self::Backup(data) => data.into(),
        }
    }

    fn new(data: Vec<u8>, is_backup: bool) -> Self {
        if is_backup {
            Self::Backup(data.into())
        } else {
            Self::Wire(NSData {
                data: data.into(),
                class: NSDataClass::NSMutableData
            })
        }
    }
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct RawBalloonData {
    ldtext: Option<String>,
    #[serde(flatten)]
    layout: Option<BalloonLayout>,
    #[serde(rename = "an")]
    app_name: String,
    #[serde(rename = "ai")]
    app_icon: Option<BalloonRawData>,
    session_identifier: Option<NSUUID>,
    live_layout_info: Option<BalloonRawData>,
    #[serde(rename = "URL")]
    url: NSURL,
    appid: Option<u64>,
}

impl Serialize for RawBalloonData {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer {
        let mut dict = Dictionary::from_iter([
            ("an".to_string(), self.app_name.clone().into()),
            ("URL".to_string(), plist::to_value(&self.url).map_err(serde::ser::Error::custom)?)
        ]);

        if let Some(layout) = &self.layout {
            let serialized = plist::to_value(&layout).map_err(serde::ser::Error::custom)?;
            let Some(d) = serialized.into_dictionary() else { panic!("not a dictionary!") };
            dict.extend(d)
        }

        if let Some(app_icon) = &self.app_icon {
            dict.insert("ai".to_string(), plist::to_value(&app_icon).map_err(serde::ser::Error::custom)?);
        }

        if let Some(appid) = &self.appid {
            dict.insert("appid".to_string(), appid.into());
        }

        if let Some(ldtext) = &self.ldtext {
            dict.insert("ldtext".to_string(), ldtext.clone().into());
        }

        if let Some(session_identifier) = &self.session_identifier {
            dict.insert("sessionIdentifier".to_string(), plist::to_value(&session_identifier).map_err(serde::ser::Error::custom)?);
        }

        if let Some(live_layout_info) = &self.live_layout_info {
            dict.insert("liveLayoutInfo".to_string(), plist::to_value(&live_layout_info).map_err(serde::ser::Error::custom)?);
        }
        
        dict.serialize(serializer)
    }
}


#[repr(C)]
#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "kebab-case")]
pub struct ExtensionApp {
    pub name: String,
    #[serde(rename = "adam-id")]
    pub app_id: Option<u64>,
    pub bundle_id: String,

    #[serde(skip)]
    pub balloon: Option<Balloon>,
}


impl ExtensionApp {
    fn from_ati(ati: &[u8], bp: Option<&[u8]>) -> Result<ExtensionApp, PushError> {
        let expanded = KeyedArchive::expand_root(&ungzip(&ati)?)?;
        debug!("ati: {:?}", plist_to_string(&expanded));
        let raw_ext: NSArray<NSDictionary<ExtensionApp>> = plist::from_value(&expanded)?;
        let mut ext = raw_ext.objects.into_iter().next().unwrap().item;

        if let Some(bp) = bp {
            ext.balloon = Some(Balloon::from_raw(Balloon::unpack_raw(bp)?)?);
        }

        Ok(ext)
    }

    pub fn from_bp(bp: &[u8], bid: &str) -> Result<ExtensionApp, PushError> {
        let raw = Balloon::unpack_raw(bp)?;

        Ok(ExtensionApp {
            name: raw.app_name.clone(),
            app_id: raw.appid.clone(),
            bundle_id: bid.to_string(),
            balloon: Some(Balloon::from_raw(raw)?)
        })
    }

    pub fn to_raw(&self, is_backup: bool) -> Result<(Vec<u8>, Option<Vec<u8>>), PushError> {
        let arr = NSArray {
            objects: vec![NSDictionary {
                class: NSDictionaryClass::NSDictionary,
                item: self
            }],
            class: NSArrayClass::NSMutableArray,
        };
        let collapse = gzip(&plist_to_bin(&KeyedArchive::archive_item(plist::to_value(&arr)?)?)?)?;
        let mut balloon = None;
        if let Some(balloon_obj) = &self.balloon {
            balloon = Some(balloon_obj.to_raw(self, is_backup)?);
        }

        Ok((collapse, balloon))
    }
}

#[repr(C)]
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all_fields = "kebab-case", tag = "layoutClass", content = "userInfo")]
pub enum BalloonLayout {
    #[serde(rename = "MSMessageTemplateLayout")]
    TemplateLayout {
        image_subtitle: String,
        image_title: String,
        caption: String,
        secondary_subcaption: String,
        tertiary_subcaption: String,
        subcaption: String,
        #[serde(rename = "$class")]
        class: NSDictionaryClass,
    }
}

#[repr(C)]
#[derive(Clone)]
pub struct Balloon {
    pub url: String,
    pub session: Option<String>, // UUID
    pub layout: Option<BalloonLayout>,
    pub ld_text: Option<String>,
    pub is_live: bool,

    pub icon: Option<Vec<u8>>,
}

impl Balloon {
    fn decode_raw(bp: &[u8]) -> Result<Balloon, PushError> {
        Balloon::from_raw(Balloon::unpack_raw(bp)?)
    }

    fn unpack_raw(bp: &[u8]) -> Result<RawBalloonData, PushError> {
        let unpacked: NSDictionary<RawBalloonData> = plist::from_value(&KeyedArchive::expand_root(&ungzip(&bp)?)?)?;
        let NSDictionary { class: _, item: unpacked } = unpacked;
        Ok(unpacked)
    }

    fn from_raw(unpacked: RawBalloonData) -> Result<Balloon, PushError> {
        let uuid: Option<Uuid> = unpacked.session_identifier.map(|i| i.into());
        Ok(Balloon {
            url: unpacked.url.into(),
            session: uuid.map(|u| u.to_string()),
            layout: unpacked.layout,
            ld_text: unpacked.ldtext,
            is_live: unpacked.live_layout_info.is_some(),
            icon: unpacked.app_icon.map(|a| a.decompress().into_bytes()),
        })
    }

    fn to_raw(&self, app: &ExtensionApp, is_backup: bool) -> Result<Vec<u8>, PushError> {
        let raw = NSDictionary {
            item: RawBalloonData {
                ldtext: self.ld_text.clone(),
                layout: self.layout.clone(),
                app_icon: self.icon.as_ref().map(|icon| BalloonRawData::new(icon.clone(), is_backup).compress()),
                app_name: app.name.clone(),
                session_identifier: self.session.as_ref().map(|session| Uuid::from_str(&session).unwrap().into()),
                live_layout_info: if self.is_live {
                    Some(BalloonRawData::new(include_bytes!("livelayout.bplist").to_vec(), is_backup))
                } else { None },
                url: NSURL {
                    base: "$null".to_string(),
                    relative: self.url.clone()
                },
                appid: app.app_id.clone(),
            },
            class: NSDictionaryClass::NSMutableDictionary
        };

        Ok(gzip(&plist_to_bin(&KeyedArchive::archive_item(plist::to_value(&raw)?)?)?)?)
    }
}

