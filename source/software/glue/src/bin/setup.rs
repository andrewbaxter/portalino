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
    loga::{
        ea,
        fatal,
        ResultContext,
    },
    rand::distributions::{
        Alphanumeric,
        DistString,
    },
    std::{
        fs::{
            create_dir_all,
            write,
        },
        path::PathBuf,
    },
};

#[derive(Aargvark)]
#[vark(id = "IPV4-MODE")]
enum Ipv4Mode {
    UpstreamNat64,
    Dhcp,
}

#[derive(Aargvark)]
struct Args {}

fn main() {
    match (|| -> Result<(), loga::Error> {
        _ = vark::<Args>();

        // Setup wifi
        {
            let ssid = format!("portalino-{}", Alphanumeric.sample_string(&mut rand::thread_rng(), 8));
            let password = Alphanumeric.sample_string(&mut rand::thread_rng(), 16);
            let dyn_dir = PathBuf::from("/run/wifidynamic");
            create_dir_all(
                &dyn_dir,
            ).context_with("Error creating dir for dynamic wifi config", ea!(path = dyn_dir.to_string_lossy()))?;
            let dyn_config_path = dyn_dir.join("config");
            write(
                &dyn_config_path,
                format!("ssid = {}", ssid).as_bytes(),
            ).context_with("Failed to write extra wifi config", ea!(path = dyn_config_path.to_string_lossy()))?;
            let dyn_password_path = dyn_dir.join("password");
            write(
                &dyn_password_path,
                &password,
            ).context_with("Failed to write wifi password", ea!(path = dyn_password_path.to_string_lossy()))?;

            #[derive(askama::Template)]
            #[template(path = "wifi.jinja.html", ext = "html")]
            struct Template<'a> {
                qr: &'a str,
                ssid: &'a str,
                password: &'a str,
            }

            let dyn_html_dir = dyn_dir.join("html");
            create_dir_all(
                &dyn_html_dir,
            ).context_with("Error creating html dir for serving wifi page", ea!(path = dyn_dir.to_string_lossy()))?;
            let dyn_html_path = dyn_html_dir.join("index.html");
            write(
                &dyn_html_path,
                Template {
                    qr: &format!(
                        "data:image/svg+xml,{}",
                        urlencode(
                            &SvgBuilder::default()
                                .shape(Shape::Circle)
                                .to_str(
                                    &QRBuilder::new(format!("WIFI:T:WPA;S:{};P:{};;", ssid, password))
                                        .build()
                                        .unwrap(),
                                ),
                        ).unwrap()
                    ),
                    ssid: &ssid,
                    password: &password,
                }.render().unwrap(),
            ).context_with("Failed to write wifi html", ea!(path = dyn_html_path.to_string_lossy()))?;
        }
        return Ok(());
    })() {
        Ok(_) => { },
        Err(e) => {
            fatal(e);
        },
    }
}
