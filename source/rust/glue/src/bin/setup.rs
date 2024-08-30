use {
    aargvark::{
        vark,
        Aargvark,
    },
    askama::{
        filters::urlencode,
        Template,
    },
    fast_qr::{
        convert::{
            svg::SvgBuilder,
            Builder,
            Shape,
        },
        QRBuilder,
    },
    flowcontrol::superif,
    glue::command::run,
    loga::{
        ea,
        fatal,
        DebugDisplay,
        ErrContext,
        Log,
        ResultContext,
    },
    rand::distributions::{
        uniform::SampleRange,
        Alphanumeric,
        DistString,
    },
    serde::{
        Deserialize,
        Serialize,
    },
    spaghettinuum::interface::config::identity::LocalIdentitySecret,
    std::{
        fs::{
            create_dir_all,
            read,
            write,
        },
        io::ErrorKind,
        path::PathBuf,
        process::Command,
    },
};

#[derive(Aargvark)]
struct Args {}

fn main() {
    match (|| -> Result<(), loga::Error> {
        _ = vark::<Args>();
        let log = Log::new_root(loga::INFO);

        // Create identity
        let identity_path = PathBuf::from("/mnt/persistent/portalino.ident");
        let identity = superif!({
            let raw = match read(&identity_path) {
                Ok(r) => r,
                Err(e) => {
                    if e.kind() == ErrorKind::NotFound {
                        // nop
                    } else {
                        log.log_err(loga::WARN, e.context("Error reading existing identity - regenerating"));
                    }
                    break 'create;
                },
            };
            let secret = match serde_json::from_slice::<LocalIdentitySecret>(&raw) {
                Ok(c) => c,
                Err(e) => {
                    log.log_err(loga::WARN, e.context("Error parsing existing identity - regenerating"));
                    break 'create;
                },
            };
            break secret.identity();
        } 'create {
            let (identity, ident_secret) = LocalIdentitySecret::new();
            write(
                &identity_path,
                &serde_json::to_vec_pretty(&ident_secret).unwrap(),
            ).context_with("Failed to write spaghettinuum identity", ea!(path = identity_path.dbg_str()))?;
            break identity;
        });

        // Set hostname
        run(
            Command::new("hostnamectl").arg("hostname").arg(format!("{}.s", identity)),
        ).log(&log, loga::WARN, "Failed to change hostname to spagh identity");

        // Setup base wifi config
        let wifi_path = PathBuf::from("/mnt/persistent/wificonfig.json");

        #[derive(Serialize, Deserialize)]
        struct WifiConfig {
            ssid: String,
            password: String,
        }

        let wifi_config = superif!({
            let raw = match read(&wifi_path) {
                Ok(r) => r,
                Err(e) => {
                    if e.kind() == ErrorKind::NotFound {
                        // nop
                    } else {
                        log.log_err(loga::WARN, e.context("Error reading existing wifi config - regenerating"));
                    }
                    break 'create;
                },
            };
            let config = match serde_json::from_slice::<WifiConfig>(&raw) {
                Ok(c) => c,
                Err(e) => {
                    log.log_err(loga::WARN, e.context("Error parsing existing wifi config - regenerating"));
                    break 'create;
                },
            };
            break config;
        } 'create {
            let config = WifiConfig {
                ssid: format!(
                    "portalino{}",
                    (0 .. 6).map(|_| ('0' ..= '9').sample_single(&mut rand::thread_rng())).collect::<String>()
                ),
                password: Alphanumeric.sample_string(&mut rand::thread_rng(), 16),
            };
            write(
                &wifi_path,
                serde_json::to_vec_pretty(&config).unwrap(),
            ).log_with(&log, loga::WARN, "Error writing wifi config", ea!(path = wifi_path.dbg_str()));
            break config;
        });

        // Generate dynamic hostapd config
        {
            let dyn_dir = PathBuf::from("/run/my_hostapd");
            create_dir_all(
                &dyn_dir,
            ).context_with("Error creating dir for dynamic wifi config", ea!(path = dyn_dir.to_string_lossy()))?;
            let dyn_config_path = dyn_dir.join("config");
            write(
                &dyn_config_path,
                format!("ssid={}", wifi_config.ssid).as_bytes(),
            ).context_with("Failed to write extra wifi config", ea!(path = dyn_config_path.to_string_lossy()))?;
            let dyn_password_path = dyn_dir.join("password");
            write(
                &dyn_password_path,
                &wifi_config.password,
            ).context_with("Failed to write wifi password", ea!(path = dyn_password_path.to_string_lossy()))?;
        }

        // Setup info page
        {
            #[derive(askama::Template)]
            #[template(path = "info.jinja.html", ext = "html")]
            struct Template<'a> {
                wifi_qr: &'a str,
                wifi_ssid: &'a str,
                wifi_password: &'a str,
                identity_qr: &'a str,
                identity_id: &'a str,
            }

            let dyn_html_dir = PathBuf::from("/run/my_infohtml");
            create_dir_all(
                &dyn_html_dir,
            ).context_with(
                "Error creating html dir for serving info page",
                ea!(path = dyn_html_dir.to_string_lossy()),
            )?;
            let dyn_html_path = dyn_html_dir.join("index.html");

            fn qr_str(text: &str) -> String {
                return format!(
                    "data:image/svg+xml,{}",
                    urlencode(
                        &SvgBuilder::default().shape(Shape::Square).to_str(&QRBuilder::new(text).build().unwrap()),
                    ).unwrap()
                );
            }

            write(
                &dyn_html_path,
                Template {
                    wifi_qr: &qr_str(&format!("WIFI:T:WPA;S:{};P:{};;", wifi_config.ssid, wifi_config.password)),
                    wifi_ssid: &wifi_config.ssid,
                    wifi_password: &wifi_config.password,
                    identity_qr: &qr_str(&format!("https://{}.s", identity.to_string())),
                    identity_id: &identity.to_string(),
                }.render().unwrap(),
            ).context_with("Failed to write info html", ea!(path = dyn_html_path.to_string_lossy()))?;
        }
        return Ok(());
    })() {
        Ok(_) => { },
        Err(e) => {
            fatal(e);
        },
    }
}
