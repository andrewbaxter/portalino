use {
    glue::{
        admin::{
            interactive_select_usb_drive,
            notify,
        },
        command::run_,
    },
    loga::{
        fatal,
        ResultContext,
    },
    std::{
        path::PathBuf,
        process::Command,
    },
};

fn main() {
    match (|| -> Result<(), loga::Error> {
        let root =
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../")
                .canonicalize()
                .context("Error getting project root absolute path")?;
        let Some(dest) = interactive_select_usb_drive()? else {
            return Ok(());
        };
        run_(
            Command::new("sudo")
                .arg("cp")
                .arg("--dereference")
                .arg(root.join("stage/imageout/iso/disk.iso"))
                .arg(dest),
        )?;
        return Ok(());
    })() {
        Err(e) => {
            notify("Flashing failed.");
            fatal(e)
        },
        Ok(_) => {
            notify("Flashing succeeded.");
        },
    }
}
