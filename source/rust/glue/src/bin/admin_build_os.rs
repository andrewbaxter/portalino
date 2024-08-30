use {
    aargvark::{
        vark,
        Aargvark,
    },
    glue::{
        admin::notify,
        command::run_,
    },
    loga::{
        fatal,
        ResultContext,
    },
    spaghettinuum::interface::config::{
        content::{
            ContentConfig,
            ServeMode,
        },
        node::{
            api_config::ApiConfig,
            node_config::NodeConfig,
            publisher_config::PublisherConfig,
            resolver_config::{
                DnsBridgeConfig,
                ResolverConfig,
            },
        },
        shared::{
            AdnSocketAddr,
            GlobalAddrConfig,
            IdentitySecretArg,
            IpVer,
            StrSocketAddr,
        },
    },
    std::{
        fs::create_dir_all,
        net::IpAddr,
        path::PathBuf,
        process::Command,
        str::FromStr,
    },
};

#[derive(Aargvark)]
enum Ipv4Mode {
    UpstreamNat64,
    Dhcp,
    Ppp {
        #[vark(flag = "--user")]
        user: String,
        #[vark(flag = "--password")]
        password: String,
    },
}

impl Default for Ipv4Mode {
    fn default() -> Self {
        return Self::UpstreamNat64;
    }
}

#[derive(Aargvark)]
#[vark(break_help)]
struct Args {
    #[vark(flag = "--ipv4-mode")]
    ipv4_mode: Option<Ipv4Mode>,
    ssh_authorized_keys_dir: Option<String>,
}

fn main() {
    match (|| -> Result<(), loga::Error> {
        let args = vark::<Args>();
        let root =
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../")
                .canonicalize()
                .context("Error getting project root absolute path")?;
        let stage_dir = root.join("stage");
        create_dir_all(&stage_dir).context("Error ensuring staging dir")?;
        let mut command = Command::new("nix");
        command.arg("build").arg("-o").arg(stage_dir.join("imageout"));

        //. command.arg("--offline");
        match args.ipv4_mode.unwrap_or_default() {
            Ipv4Mode::UpstreamNat64 => {
                command.arg("-f").arg("source/os/main_nat64.nix");
            },
            Ipv4Mode::Dhcp => {
                command.arg("-f").arg("source/os/main_dhcp.nix");
            },
            Ipv4Mode::Ppp { user, password } => {
                command.arg("-f").arg("source/os/main_ppp.nix");
                command.arg("--argstr").arg("ppp_user").arg(user);
                command.arg("--argstr").arg("ppp_password").arg(password);
            },
        }
        command
            .arg("--argstr")
            .arg("spaghettinuum_config")
            .arg(serde_json::to_string_pretty(&spaghettinuum::interface::config::node::Config {
                identity: Some(IdentitySecretArg::Local(PathBuf::from("/mnt/persistent/portalino.ident"))),
                global_addrs: vec![GlobalAddrConfig::FromInterface {
                    name: Some("br0".to_string()),
                    ip_version: Some(IpVer::V6),
                }],
                api: Some(ApiConfig::default()),
                node: NodeConfig::default(),
                publisher: Some(PublisherConfig::default()),
                resolver: Some(ResolverConfig {
                    dns_bridge: Some(DnsBridgeConfig {
                        upstream: Some(vec![
                            //. .
                            AdnSocketAddr {
                                ip: IpAddr::from_str("2606:4700:4700::64").unwrap(),
                                port: None,
                                adn: Some("dns64.cloudflare-dns.com".to_string()),
                            },
                            AdnSocketAddr {
                                ip: IpAddr::from_str("2606:4700:4700::6464").unwrap(),
                                port: None,
                                adn: Some("dns64.cloudflare-dns.com".to_string()),
                            },
                            AdnSocketAddr {
                                ip: IpAddr::from_str("2001:4860:4860::64").unwrap(),
                                port: None,
                                adn: Some("dns64.dns.google".to_string()),
                            },
                            AdnSocketAddr {
                                ip: IpAddr::from_str("2001:4860:4860::6464").unwrap(),
                                port: None,
                                adn: Some("dns64.dns.google".to_string()),
                            }
                        ]),
                        synthetic_self_record: Some("portalino".to_string()),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                content: Some(vec![ContentConfig {
                    bind_addrs: vec![StrSocketAddr::new("[::]:443")],
                    mode: ServeMode::StaticFiles { content_dir: PathBuf::from("/run/my_infohtml") },
                }]),
                ..Default::default()
            }).unwrap());
        if let Some(d) = args.ssh_authorized_keys_dir {
            command.arg("--arg").arg("ssh_authorized_keys_dir").arg(d);
        }
        command.arg("config.system.build.myiso");
        run_(&mut command).context("Building failed")?;
        return Ok(());
    })() {
        Err(e) => {
            notify("Build failed.");
            fatal(e)
        },
        Ok(_) => {
            notify("Build succeeded.");
        },
    }
}
