use {
    infra::{
        notify,
        run_,
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
            node_config::NodeConfig,
            resolver_config::{
                DnsBridgeConfig,
                ResolverConfig,
            },
        },
        shared::{
            AdnSocketAddr,
            GlobalAddrConfig,
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

fn main() {
    match (|| -> Result<(), loga::Error> {
        let root =
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../")
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
                            upstream: Some(vec![AdnSocketAddr {
                                ip: IpAddr::from_str("127.0.0.53").unwrap(),
                                port: None,
                                adn: None,
                            }]),
                            ..Default::default()
                        }),
                        ..Default::default()
                    }),
                    content: Some(vec![ContentConfig {
                        bind_addrs: vec![StrSocketAddr::new("[::]:443")],
                        mode: ServeMode::StaticFiles { content_dir: PathBuf::from("/run/wifidynamic") },
                    }]),
                    ..Default::default()
                }).unwrap())
                .arg("--argstr")
                .arg("ipv4_mode")
                .arg("dhcp")
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
