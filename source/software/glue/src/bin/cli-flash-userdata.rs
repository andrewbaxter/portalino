use {
    aargvark::{
        vark,
        Aargvark,
        AargvarkJson,
    },
    glue::{
        drive::select_usb_drive,
        run,
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
        fs::write,
        process::Command,
    },
    tempfile::tempdir,
};

#[derive(Aargvark)]
struct Args {
    userdata: AargvarkJson<Userdata>,
}

fn main() {
    match (|| -> Result<(), loga::Error> {
        let args = vark::<Args>();
        let tempdir = tempdir().context("Error creating tempdir")?;
        let userdata_path = tempdir.path().join(USERDATA_FILENAME);
        write(
            &userdata_path,
            serde_json::to_string_pretty(&args.userdata.value).unwrap(),
        ).context_with("Error staging userdata config", ea!(path = userdata_path.to_string_lossy()))?;
        let Some(dest) = select_usb_drive("userdata")? else {
            return Ok(());
        };
        run(
            Command::new("mkfs.erofs")
                .arg("-U")
                .arg(USERDATA_UUID)
                .arg("--all-root")
                .arg(dest)
                .arg(tempdir.path()),
        ).context("Error flashing userdata device")?;
        return Ok(());
    })() {
        Ok(_) => { },
        Err(e) => {
            fatal(e);
        },
    }
}
