use {
    aargvark::{
        vark,
        Aargvark,
        AargvarkJson,
    },
    glue::{
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
    rand::{
        distributions::Alphanumeric,
        Rng,
    },
    serde::Deserialize,
    std::{
        collections::HashSet,
        fs::write,
        io::{
            stdin,
            BufRead,
            BufReader,
        },
        process::{
            Command,
        },
        thread::sleep,
        time::Duration,
    },
    tempfile::tempdir,
};

#[derive(Aargvark)]
struct Args {
    userdata: AargvarkJson<Userdata>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LsblkRoot {
    blockdevices: Vec<LsblkDevice>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LsblkDevice {
    //. /// alignment offset
    //. alignment: i64,
    //. /// * ID-LINK: the shortest udev /dev/disk/by-id link name
    //. #[serde(rename = "id-link")]
    //. id_link: Option<String>,
    //. /// udev ID (based on ID-LINK)
    //. id: Option<String>,
    //. /// filesystem size available
    //. fsavail: Option<i64>,
    //. /// mounted filesystem roots
    //. fsroots: Vec<Option<String>>,
    //. /// filesystem size
    //. fssize: Option<i64>,
    //. /// filesystem type
    //. fstype: Option<String>,
    //. /// filesystem size used
    //. fsused: Option<i64>,
    //. /// filesystem version
    //. fsver: Option<String>,
    //. /// group name
    //. group: String,
    //. /// removable or hotplug device (usb, pcmcia, ...)
    //. hotplug: bool,
    //. /// internal kernel device name.  This appears to be what is in `/dev`.
    //. kname: String,
    //. /// filesystem LABEL
    //. label: Option<String>,
    //. /// * LOG-SEC: logical sector size
    //. #[serde(rename = "log-sec")]
    //. log_sec: i64,
    //. /// * MAJ:MIN: major:minor device number
    //. #[serde(rename = "maj:min")]
    //. maj_min: String,
    //. /// * MIN-IO: minimum I/O size
    //. #[serde(rename = "min-io")]
    //. min_io: i64,
    //. /// device node permissions
    //. mode: String,
    //. /// device identifier
    //. model: Option<String>,
    //. /// device name.  This appears to be what is in `/dev/mapper`.
    //. name: String,
    //. /// * OPT-IO: optimal I/O size
    //. #[serde(rename = "opt-io")]
    //. opt_io: i64,
    //. /// user name
    //. owner: String,
    //. /// partition flags. Like `0x8000000000000000`
    //. partflags: Option<String>,
    //. /// partition LABEL
    //. partlabel: Option<String>,
    //. /// partition number as read from the partition table
    //. partn: Option<usize>,
    //. /// partition type code or UUID
    //. parttype: Option<String>,
    //. /// partition type name
    //. parttypename: Option<String>,
    //. /// partition UUID
    //. partuuid: Option<String>,
    /// path to the device node
    path: String,
    //. /// internal parent kernel device name
    //. pkname: Option<String>,
    //. /// partition table type
    //. pttype: Option<String>,
    //. /// partition table identifier (usually UUID)
    //. ptuuid: Option<String>,
    //. /// removable device
    //. rm: bool,
    //. /// read-only device
    //. ro: bool,
    //. /// disk serial number
    //. serial: Option<String>,
    //. /// size of the device in bytes.
    //. size: i64,
    //. /// partition start offset
    //. start: Option<usize>,
    //. /// state of the device
    //. state: Option<String>,
    /// de-duplicated chain of subsystems
    subsystems: String,
    //. /// where the device is mounted
    //. mountpoint: Option<String>,
    /// all locations where device is mounted
    mountpoints: Vec<Option<String>>,
    //. /// device transport type
    //. tran: Option<String>,
    /// device type
    #[serde(rename = "type")]
    type_: String,
    //. /// filesystem UUID. Not always a standard uuid, can be 8 characters.
    //. uuid: Option<String>,
    //. /// device vendor
    //. vendor: Option<String>,
    //. /// write same max bytes
    //. wsame: i64,
    //. /// unique storage identifier
    //. wwn: Option<String>,
    #[serde(default)]
    children: Vec<LsblkDevice>,
}

fn lsblk() -> Result<Vec<LsblkDevice>, loga::Error> {
    let res =
        run(
            Command::new("lsblk").arg("--bytes").arg("--json").arg("--output-all").arg("--tree"),
        ).context("Error looking up block devices to identify userdata device")?;
    let root =
        serde_json::from_slice::<LsblkRoot>(
            &res.stdout,
        ).context_with("lsblk produced invalid JSON output", ea!(output = String::from_utf8_lossy(&res.stdout)))?;
    return Ok(root.blockdevices);
}

fn candidates() -> Result<HashSet<String>, loga::Error> {
    return Ok(lsblk()?.into_iter().filter_map(|e| {
        if e.type_ != "disk" {
            return None;
        }
        if e.subsystems != "block:scsi:usb:pci" {
            return None;
        }

        fn in_use(candidate: &LsblkDevice) -> bool {
            if candidate.mountpoints.iter().filter(|p| p.is_some()).count() > 0 {
                return true;
            }
            for child in &candidate.children {
                if in_use(child) {
                    return true;
                }
            }
            return false;
        }

        if in_use(&e) {
            return None;
        }
        return Some(e.path);
    }).collect::<HashSet<_>>());
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
        let mut start_devs = candidates()?;
        println!("Insert the USB drive to flash as a userdata device.");
        let mut stdin_lines = BufReader::new(stdin()).lines();
        let dest = 'found : loop {
            sleep(Duration::from_secs(1));
            let current_devs = candidates()?;
            for dev in current_devs.difference(&start_devs) {
                let confirm =
                    rand::thread_rng().sample_iter(&Alphanumeric).take(5).map(char::from).collect::<String>();
                println!(
                    "Do you want to use [{}] as a userdata device? Its contents will be replaced.\nEnter [{}] to confirm or anything else to select another.",
                    dev,
                    confirm
                );
                print!("> ");
                let Some(line) = stdin_lines.next() else {
                    return Ok(());
                };
                let line = line.context("Error reading line from stdin")?;
                if line == confirm {
                    break 'found dev.clone();
                }
            }
            start_devs = current_devs;
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
