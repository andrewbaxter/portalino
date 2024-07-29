use {
    loga::{
        ea,
        DebugDisplay,
        Log,
        ResultContext,
    },
    serde::{
        Deserialize,
        Serialize,
    },
    std::process::{
        Command,
        Stdio,
    },
};

pub mod drive;

pub const USERDATA_UUID: &str = "0f718580-e2ba-461e-89e2-4e6a448ab87f";
pub const USERDATA_FILENAME: &str = "userdata.json";

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct PppConfig {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Ipv4Mode {
    IspNat64,
    Dhcp,
    Ppp(PppConfig),
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct WifiConfig {
    pub ssid: String,
    pub password: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Userdata {
    pub ipv4_mode: Ipv4Mode,
    pub wifi: Option<WifiConfig>,
}

pub fn run_(command: &mut Command) -> Result<std::process::Output, loga::Error> {
    return Ok((|| -> Result<std::process::Output, loga::Error> {
        let p = command.spawn()?;
        let res = p.wait_with_output()?;
        if !res.status.success() {
            return Err(loga::err_with("Command exited with error code", ea!(output = res.dbg_str())));
        }
        return Ok(res);
    })().context_with("Error executing command", ea!(command = command.dbg_str()))?);
}

pub fn run(command: &mut Command) -> Result<std::process::Output, loga::Error> {
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    return run_(command);
}

pub fn notify(text: &str) {
    run(
        Command::new("notify-send").arg(text),
    ).log(&Log::new_root(loga::INFO), loga::WARN, "Failed to send notification");
}
