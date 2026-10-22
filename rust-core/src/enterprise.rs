//! Local signing with a user-supplied enterprise certificate.
//!
//! The .p12 is parsed on the Swift side (Security framework), so
//! the certificate and RSA private key arrive here as DER files,
//! alongside the .mobileprovision. No Apple ID and no network:
//! the identity and profile are built directly and handed to
//! isideload's signer — the same code path the Apple-ID flow
//! ends in. The bundle ID is left untouched (an enterprise
//! profile authorizes the app as it is, unlike a development
//! profile tied to registered App IDs).

use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use isideload::dev::app_ids::Profile;
use isideload::dev::teams::DeveloperTeam;
use isideload::sideload::application::Application;
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::sideload::sign;
use rsa::{pkcs8::DecodePrivateKey, RsaPrivateKey};
use x509_cert::{der::Decode, Certificate};

use crate::error_text::report_text;
use crate::ffi_util::{cstr, opt_str};

/// DER length octets for a content of `len` bytes.
fn der_len(len: usize) -> Vec<u8> {
    if len < 0x80 {
        vec![len as u8]
    } else if len < 0x100 {
        vec![0x81, len as u8]
    } else {
        vec![0x82, (len >> 8) as u8, len as u8]
    }
}

/// Wrap a PKCS#1 RSA private key in a PKCS#8 PrivateKeyInfo, so
/// the rsa crate's PKCS#8 decoder accepts it (Swift's
/// SecKeyCopyExternalRepresentation hands out PKCS#1 for RSA).
fn wrap_pkcs1_in_pkcs8(pkcs1: &[u8]) -> Vec<u8> {
    // AlgorithmIdentifier: rsaEncryption (1.2.840.113549.1.1.1) + NULL
    const ALG_ID: [u8; 15] = [
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
    ];
    let mut body = Vec::with_capacity(pkcs1.len() + 32);
    body.extend_from_slice(&[0x02, 0x01, 0x00]); // version 0
    body.extend_from_slice(&ALG_ID);
    body.push(0x04); // OCTET STRING
    body.extend_from_slice(&der_len(pkcs1.len()));
    body.extend_from_slice(pkcs1);
    let mut out = vec![0x30]; // SEQUENCE
    out.extend_from_slice(&der_len(body.len()));
    out.extend_from_slice(&body);
    out
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Extract the XML plist embedded verbatim in a .mobileprovision
/// (a CMS blob) and parse it into a dictionary.
fn provision_dict(bytes: &[u8]) -> Result<plist::Dictionary, String> {
    let start = find_subslice(bytes, b"<?xml").ok_or("描述文件里找不到 plist")?;
    let tail = find_subslice(bytes, b"</plist>").ok_or("描述文件里找不到 plist 结尾")?;
    let end = tail + "</plist>".len();
    let value = plist::Value::from_reader(std::io::Cursor::new(&bytes[start..end]))
        .map_err(|e| format!("描述文件解析失败：{e}"))?;
    value
        .as_dictionary()
        .cloned()
        .ok_or_else(|| "描述文件格式不对".to_string())
}

fn dict_string(dict: &plist::Dictionary, key: &str) -> String {
    dict.get(key)
        .and_then(|v| v.as_string())
        .unwrap_or("")
        .to_string()
}

/// Optional pre-signing modifications plus a signed-.ipa output,
/// passed from Swift as one JSON object; every field is optional
/// and an absent/empty field leaves the app as it is:
/// `{name, bundleId, version, minOS, iconPng, outIpa}`.
#[derive(Default)]
struct SignMods {
    name: Option<String>,
    bundle_id: Option<String>,
    version: Option<String>,
    min_os: Option<String>,
    icon_png: Option<String>,
    out_ipa: Option<String>,
}

fn parse_mods(json: &str) -> SignMods {
    let mut mods = SignMods::default();
    if json.trim().is_empty() {
        return mods;
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return mods;
    };
    let get = |key: &str| {
        value
            .get(key)
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
    };
    mods.name = get("name");
    mods.bundle_id = get("bundleId");
    mods.version = get("version");
    mods.min_os = get("minOS");
    mods.icon_png = get("iconPng");
    mods.out_ipa = get("outIpa");
    mods
}

/// Overwrite the app's icon files with one PNG. The icon file names
/// come from the Info.plist (CFBundleIcons → CFBundlePrimaryIcon →
/// CFBundleIconFiles); each existing scale variant gets the PNG.
/// Apps whose icons live only in Assets.car have no loose files to
/// replace — that case silently keeps the original icon.
fn apply_icon(app: &Application, icon_path: &str) -> Result<(), String> {
    let png = std::fs::read(icon_path).map_err(|e| format!("读图标失败：{e}"))?;
    let mut bases: Vec<String> = Vec::new();
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        if let Some(files) = app
            .bundle
            .app_info
            .get(key)
            .and_then(|v| v.as_dictionary())
            .and_then(|d| d.get("CFBundlePrimaryIcon"))
            .and_then(|v| v.as_dictionary())
            .and_then(|d| d.get("CFBundleIconFiles"))
            .and_then(|v| v.as_array())
        {
            for file in files {
                if let Some(name) = file.as_string() {
                    bases.push(name.to_string());
                }
            }
        }
    }
    if bases.is_empty() {
        bases.push("AppIcon60x60".to_string());
    }
    let dir = &app.bundle.bundle_dir;
    for base in &bases {
        let stem = base.strip_suffix(".png").unwrap_or(base);
        for suffix in ["", "@2x", "@3x", "~ipad", "@2x~ipad", "@3x~ipad"] {
            let candidate = dir.join(format!("{stem}{suffix}.png"));
            if candidate.exists() {
                std::fs::write(&candidate, &png).map_err(|e| format!("写图标失败：{e}"))?;
            }
        }
    }
    Ok(())
}

/// Apply the requested modifications, then persist every bundle's
/// Info.plist the same way the account flow does before signing.
fn apply_mods(app: &mut Application, mods: &SignMods) -> Result<(), String> {
    if let Some(new_id) = &mods.bundle_id {
        let old_id = app.main_bundle_id().map_err(|e| report_text(&e))?;
        if old_id != *new_id {
            app.update_bundle_id(&old_id, new_id)
                .map_err(|e| report_text(&e))?;
        }
    }
    if let Some(name) = &mods.name {
        app.bundle.app_info.insert(
            "CFBundleDisplayName".to_string(),
            plist::Value::String(name.clone()),
        );
    }
    if let Some(version) = &mods.version {
        app.bundle.app_info.insert(
            "CFBundleShortVersionString".to_string(),
            plist::Value::String(version.clone()),
        );
    }
    if let Some(min_os) = &mods.min_os {
        app.bundle.app_info.insert(
            "MinimumOSVersion".to_string(),
            plist::Value::String(min_os.clone()),
        );
    }
    if let Some(icon_path) = &mods.icon_png {
        apply_icon(app, icon_path)?;
    }
    app.bundle.write_info().map_err(|e| report_text(&e))?;
    for ext in app.bundle.app_extensions_mut() {
        ext.write_info().map_err(|e| report_text(&e))?;
    }
    for fw in app.bundle.frameworks_mut() {
        fw.write_info().map_err(|e| report_text(&e))?;
    }
    Ok(())
}

/// Zip a signed .app bundle back into an .ipa at `out_ipa`,
/// keeping each file's unix mode (the executable bit matters when
/// the archive is extracted again).
fn zip_bundle(bundle_dir: &std::path::Path, out_ipa: &str) -> Result<(), String> {
    let app_name = bundle_dir
        .file_name()
        .ok_or("签名包目录不对")?
        .to_string_lossy()
        .to_string();
    let mut entries: Vec<PathBuf> = Vec::new();
    let mut stack = vec![bundle_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let read = std::fs::read_dir(&dir).map_err(|e| format!("读签名包失败：{e}"))?;
        for entry in read {
            let entry = entry.map_err(|e| format!("读签名包失败：{e}"))?;
            let path = entry.path();
            if path.is_dir() {
                stack.push(path.clone());
            }
            entries.push(path);
        }
    }
    entries.sort();
    let file = std::fs::File::create(out_ipa).map_err(|e| format!("建已签 IPA 失败：{e}"))?;
    let mut zip = zip::ZipWriter::new(file);
    let make_options = || {
        zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
    };
    for path in &entries {
        let rel = path.strip_prefix(bundle_dir).unwrap_or(path);
        let name = format!("Payload/{}/{}", app_name, rel.to_string_lossy());
        if path.is_dir() {
            zip.add_directory(format!("{name}/"), make_options())
                .map_err(|e| format!("打包失败：{e}"))?;
        } else {
            #[cfg(unix)]
            let mode = {
                use std::os::unix::fs::PermissionsExt;
                path.metadata().map(|m| m.permissions().mode()).unwrap_or(0o644)
            };
            #[cfg(not(unix))]
            let mode = 0o644;
            zip.start_file(name, make_options().unix_permissions(mode))
                .map_err(|e| format!("打包失败：{e}"))?;
            let mut source = std::fs::File::open(path).map_err(|e| format!("打包失败：{e}"))?;
            std::io::copy(&mut source, &mut zip).map_err(|e| format!("打包失败：{e}"))?;
        }
    }
    zip.finish().map_err(|e| format!("打包失败：{e}"))?;
    Ok(())
}

fn sign_with_cert(
    ipa_path: &str,
    cert_der_path: &str,
    key_der_path: &str,
    provision_path: &str,
) -> Result<String, String> {
    sign_with_cert_mods(
        ipa_path,
        cert_der_path,
        key_der_path,
        provision_path,
        &SignMods::default(),
    )
}

fn sign_with_cert_mods(
    ipa_path: &str,
    cert_der_path: &str,
    key_der_path: &str,
    provision_path: &str,
    mods: &SignMods,
) -> Result<String, String> {
    let cert_der = std::fs::read(cert_der_path).map_err(|e| format!("读证书失败：{e}"))?;
    let key_der = std::fs::read(key_der_path).map_err(|e| format!("读私钥失败：{e}"))?;
    let provision_bytes =
        std::fs::read(provision_path).map_err(|e| format!("读描述文件失败：{e}"))?;

    let certificate =
        Certificate::from_der(&cert_der).map_err(|e| format!("证书解析失败：{e}"))?;
    let private_key = RsaPrivateKey::from_pkcs8_der(&key_der)
        .or_else(|_| RsaPrivateKey::from_pkcs8_der(&wrap_pkcs1_in_pkcs8(&key_der)))
        .map_err(|e| format!("私钥解析失败：{e}"))?;

    let dict = provision_dict(&provision_bytes)?;
    let team_id = dict
        .get("TeamIdentifier")
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .and_then(|v| v.as_string())
        .unwrap_or("")
        .to_string();
    if team_id.is_empty() {
        return Err("描述文件里没有 TeamIdentifier".into());
    }
    let date_expire = match dict.get("ExpirationDate") {
        Some(plist::Value::Date(d)) => d.clone(),
        _ => return Err("描述文件里没有 ExpirationDate".into()),
    };

    let profile = Profile {
        encoded_profile: plist::Data::new(provision_bytes),
        filename: "enterprise.mobileprovision".to_string(),
        provisioning_profile_id: String::new(),
        name: dict_string(&dict, "Name"),
        status: "Active".to_string(),
        r#type: "Distribution".to_string(),
        distribution_method: String::new(),
        pro_pro_platorm: None,
        uuid: dict_string(&dict, "UUID"),
        date_expire,
        managing_app: None,
        app_id_id: String::new(),
        is_template_profile: false,
        is_team_profile: None,
        is_free_provisioning_profile: Some(false),
    };
    let team = DeveloperTeam {
        name: Some(dict_string(&dict, "TeamName")),
        team_id,
        r#type: Some("Distribution".to_string()),
        status: None,
    };
    let identity = CertificateIdentity {
        machine_id: "enterprise".to_string(),
        machine_name: "enterprise".to_string(),
        private_key,
        certificate,
    };

    let mut app = Application::new(PathBuf::from(ipa_path)).map_err(|e| report_text(&e))?;
    apply_mods(&mut app, mods)?;
    sign::sign(&mut app, &identity, &profile, &None, &team).map_err(|e| report_text(&e))?;
    if let Some(out_ipa) = &mods.out_ipa {
        if let Some(parent) = PathBuf::from(out_ipa).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        zip_bundle(&app.bundle.bundle_dir, out_ipa)?;
    }
    Ok(app.bundle.bundle_dir.to_string_lossy().to_string())
}

/// Extract an .ipa and return its .app bundle directory (in the
/// shared extraction folder `Application::new` uses). Used to
/// install an already-signed IPA without signing it again.
///
/// # Safety
/// Same contract as `sign_ipa_with_cert`.
pub unsafe fn extract_ipa(
    ipa_path: *const c_char,
    out_bundle_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let ipa = opt_str(ipa_path, "");
    let result = catch_unwind(AssertUnwindSafe(|| {
        Application::new(PathBuf::from(&ipa))
            .map(|app| app.bundle.bundle_dir.to_string_lossy().to_string())
            .map_err(|e| report_text(&e))
    }));
    match result {
        Ok(Ok(path)) => {
            *out_bundle_path = cstr(path);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during IPA extraction");
            2
        }
    }
}

/// Like `sign_ipa_with_cert`, plus a JSON options object with the
/// optional modifications and signed-.ipa output (see `SignMods`).
///
/// # Safety
/// Same contract as `sign_ipa_with_cert`; `options_json` may be
/// null for no modifications.
pub unsafe fn sign_ipa_with_cert_ex(
    ipa_path: *const c_char,
    cert_der_path: *const c_char,
    key_der_path: *const c_char,
    provision_path: *const c_char,
    options_json: *const c_char,
    out_signed_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let ipa = opt_str(ipa_path, "");
    let cert = opt_str(cert_der_path, "");
    let key = opt_str(key_der_path, "");
    let provision = opt_str(provision_path, "");
    let json = opt_str(options_json, "");
    let result = catch_unwind(AssertUnwindSafe(|| {
        let mods = parse_mods(&json);
        sign_with_cert_mods(&ipa, &cert, &key, &provision, &mods)
    }));
    match result {
        Ok(Ok(path)) => {
            *out_signed_path = cstr(path);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during enterprise signing");
            2
        }
    }
}

/// Sign an IPA with an enterprise certificate, locally. Returns 0
/// on success and sets `*out_signed_path` to the signed bundle's
/// directory; on failure returns nonzero and sets `*out_error`.
///
/// # Safety
/// All `*const c_char` args must be null or valid C strings; the
/// out pointers must be valid and writable.
pub unsafe fn sign_ipa_with_cert(
    ipa_path: *const c_char,
    cert_der_path: *const c_char,
    key_der_path: *const c_char,
    provision_path: *const c_char,
    out_signed_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let ipa = opt_str(ipa_path, "");
    let cert = opt_str(cert_der_path, "");
    let key = opt_str(key_der_path, "");
    let provision = opt_str(provision_path, "");
    let result = catch_unwind(AssertUnwindSafe(|| sign_with_cert(&ipa, &cert, &key, &provision)));
    match result {
        Ok(Ok(path)) => {
            *out_signed_path = cstr(path);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during enterprise signing");
            2
        }
    }
}
