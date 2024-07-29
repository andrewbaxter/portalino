use {
    glue::{
        notify,
        run_,
    },
    loga::{
        fatal,
        ResultContext,
    },
    spaghettinuum::interface::config::{
        node::{
            node_config::{
                NodeConfig,
            },
            resolver_config::{
                DnsBridgeConfig,
                ResolverConfig,
            },
        },
        shared::{
            AdnSocketAddr,
            GlobalAddrConfig,
            IpVer,
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

fn main() {
    match (|| -> Result<(), loga::Error> {
        let root =
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../")
                .canonicalize()
                .context("Error getting project root absolute path")?;
        let stage_dir = root.join("stage");
        create_dir_all(&stage_dir).context("Error ensuring staging dir")?;
        run_(
            Command::new("nix")
                .arg("build")
                .arg("-f")
                .arg(root.join("source/os/main.nix"))
                .arg("-o")
                .arg(stage_dir.join("imageout"))
                .arg("--argstr")
                .arg("spagh_config")
                .arg(serde_json::to_string(&spaghettinuum::interface::config::node::Config {
                    identity: None,
                    global_addrs: vec![GlobalAddrConfig::FromInterface {
                        name: Some("eth1".to_string()),
                        ip_version: Some(IpVer::V6),
                    }],
                    node: NodeConfig::default(),
                    resolver: Some(ResolverConfig {
                        dns_bridge: Some(DnsBridgeConfig {
                            upstream: Some(vec![
                                //. .
                                AdnSocketAddr {
                                    ip: IpAddr::from_str("2606:4700:4700::64").unwrap(),
                                    port: Some(853),
                                    adn: Some("dns64.cloudflare-dns.com".to_string()),
                                },
                                AdnSocketAddr {
                                    ip: IpAddr::from_str("2606:4700:4700::6464").unwrap(),
                                    port: Some(853),
                                    adn: Some("dns64.cloudflare-dns.com".to_string()),
                                },
                                AdnSocketAddr {
                                    ip: IpAddr::from_str("2001:4860:4860::6464").unwrap(),
                                    port: Some(853),
                                    adn: Some("dns64.dns.google".to_string()),
                                },
                                AdnSocketAddr {
                                    ip: IpAddr::from_str("2001:4860:4860::64").unwrap(),
                                    port: Some(853),
                                    adn: Some("dns64.dns.google".to_string()),
                                }
                            ]),
                            ..Default::default()
                        }),
                        ..Default::default()
                    }),
                    ..Default::default()
                }).unwrap())
                .arg("config.system.build.myiso"),
        ).context("Building failed")?;
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
