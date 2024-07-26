use {
    glue::{
        run,
        Ipv4Mode,
        Userdata,
        USERDATA_FILENAME,
        USERDATA_UUID,
    },
    loga::{
        ea,
        fatal,
        ResultContext,
    },
    std::{
        fs::{
            create_dir_all,
            read,
            write,
        },
        path::PathBuf,
        process::Command,
    },
};

fn start_nat64() -> Result<(), loga::Error> {
    run(Command::new("systemctl").arg("start").arg("jool-nat64-default")).context("Error starting nat64")?;
    return Ok(());
}

fn main() {
    match (|| -> Result<(), loga::Error> {
        // Mount and read userdata
        let userdata_root = format!("/mnt/userdata");
        run(
            Command::new("mount").arg(format!("/dev/disk/by-uuid/{}", USERDATA_UUID)).arg(&userdata_root),
        ).context("Error mounting userdata")?;
        let userdata_path = format!("/mnt/userdata/{}", USERDATA_FILENAME);
        let userdata =
            serde_json::from_slice::<Userdata>(
                &read(&userdata_path).context_with("Error reading userdata", ea!(path = userdata_path))?,
            ).context_with("Error parsing JSON in userdata", ea!(path = userdata_path))?;

        // Setup ipv4
        match userdata.ipv4_mode {
            Ipv4Mode::IspNat64 => {
                // Nothing to do
            },
            Ipv4Mode::Dhcp => {
                run(Command::new("dhcpcd").arg("/dev/eth0")).context("Error starting DHCP for IPv4 address")?;
                start_nat64()?;
            },
            Ipv4Mode::Ppp(config) => {
                let dyn_dir = PathBuf::from("/run/pppdynamic");
                create_dir_all(
                    &dyn_dir,
                ).context_with("Error creating dir for dynamic ppp config", ea!(path = dyn_dir.to_string_lossy()))?;
                let dyn_config_path = dyn_dir.join("config");
                write(
                    &dyn_config_path,
                    format!("name \"{}\"", config.username),
                ).context_with("Error writing dynamic config", ea!(path = dyn_config_path.to_string_lossy()))?;
                let dyn_secrets_path = dyn_dir.join("secrets");
                write(
                    &dyn_secrets_path,
                    format!("{} * {}", config.username, config.password).as_bytes(),
                ).context_with("Failed to write PPP secrets", ea!(path = dyn_secrets_path.to_string_lossy()))?;
                for secrets_mountpoint in ["etc-ppp-pap-secrets", "etc-ppp-chap-secrets"] {
                    run(
                        Command::new("systemctl").arg("start").arg(secrets_mountpoint),
                    ).context_with("Error binding dynamic PPP secrets", ea!(unit = secrets_mountpoint))?;
                }
                run(Command::new("systemctl").arg("start").arg("pppd-main")).context("Error starting pppd")?;
                start_nat64()?;
            },
        }

        // Setup wifi
        if let Some(wifi) = userdata.wifi {
            let dyn_dir = PathBuf::from("/run/wifidynamic");
            create_dir_all(
                &dyn_dir,
            ).context_with("Error creating dir for dynamic wifi config", ea!(path = dyn_dir.to_string_lossy()))?;
            let dyn_config_path = dyn_dir.join("config");
            write(
                &dyn_config_path,
                format!("ssid = {}", wifi.ssid).as_bytes(),
            ).context_with("Failed to write extra wifi config", ea!(path = dyn_config_path.to_string_lossy()))?;
            let dyn_password_path = dyn_dir.join("password");
            write(
                &dyn_password_path,
                wifi.password.as_bytes(),
            ).context_with("Failed to write wifi password", ea!(path = dyn_password_path.to_string_lossy()))?;
        }
        return Ok(());
    })() {
        Ok(_) => { },
        Err(e) => {
            fatal(e);
        },
    }
}
