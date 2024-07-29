use {
    glue::{
        drive::select_usb_drive,
        notify,
        run,
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
        let Some(dest) = select_usb_drive("os")? else {
            return Ok(());
        };
        run(
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
