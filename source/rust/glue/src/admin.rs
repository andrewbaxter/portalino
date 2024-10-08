use {
    crate::command::run,
    flowcontrol::shed,
    loga::{
        ea,
        Log,
        ResultContext,
    },
    rand::{
        distributions::Uniform,
        Rng,
    },
    serde::Deserialize,
    std::{
        collections::HashSet,
        fs::{
            read_dir,
            read_link,
        },
        io::{
            stdin,
            stdout,
            BufRead,
            BufReader,
            Write,
        },
        path::PathBuf,
        process::{
            Command,
        },
        thread::sleep,
        time::Duration,
    },
};

pub fn notify(text: &str) {
    run(
        Command::new("notify-send").arg(text),
    ).log(&Log::new_root(loga::INFO), loga::WARN, "Failed to send notification");
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

pub fn interactive_select_usb_drive() -> Result<Option<PathBuf>, loga::Error> {
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

    let by_id_dir = PathBuf::from("/dev/disk/by-id");
    let mut start_devs = candidates()?;
    println!("Insert USB into flash drive.");
    let mut stdin_lines = BufReader::new(stdin()).lines();
    let dest = 'found : loop {
        sleep(Duration::from_secs(1));
        let current_devs = candidates()?;
        for dev in current_devs.difference(&start_devs) {
            let dest = PathBuf::from(dev);

            // Try to find a more verbose name
            let dest = shed!{
                'found_long _;
                for e in read_dir(
                    &by_id_dir,
                ).context_with("Error reading", ea!(path = by_id_dir.to_string_lossy()))? {
                    let Ok(e) = e else {
                        continue;
                    };
                    let Ok(link_dest) = read_link(e.path()) else {
                        continue;
                    };
                    let Ok(link_dest) = by_id_dir.join(link_dest).canonicalize() else {
                        continue;
                    };
                    if link_dest == dest {
                        break 'found_long e.path();
                    }
                }
                break 'found_long dest;
            };

            // Generate typo-prevention code
            let confirm = rand::thread_rng().sample_iter(Uniform::new('a', 'z')).take(5).map(char::from).collect::<String>();

            // Confirm
            println!(
                "Do you want to use [{}]? Its contents will be replaced.\nEnter [{}] to confirm or anything else to try again.",
                dest.to_string_lossy(),
                confirm
            );
            print!("> ");
            stdout().flush().unwrap();
            let Some(line) = stdin_lines.next() else {
                return Ok(None);
            };
            let line = line.context("Error reading line from stdin")?;
            if line == confirm {
                break 'found dest;
            }
        }
        start_devs = current_devs;
    };
    return Ok(Some(dest));
}
