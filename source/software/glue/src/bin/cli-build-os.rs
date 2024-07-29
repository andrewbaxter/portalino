use {
    glue::{
        notify,
        run_,
    },
    loga::{
        fatal,
        ResultContext,
    },
    std::{
        fs::remove_dir_all,
        path::PathBuf,
        process::Command,
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
        remove_dir_all(stage_dir.join("image")).context("Error removing old image")?;
        run_(
            Command::new("nix")
                .arg("build")
                .arg("-f")
                .arg(root.join("source/os/main.nix"))
                .arg("-o")
                .arg(stage_dir.join("imageout"))
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
