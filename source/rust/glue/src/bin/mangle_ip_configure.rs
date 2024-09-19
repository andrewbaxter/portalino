use {
    aargvark::{
        vark,
        Aargvark,
    },
    glue::unstable_ip::UnstableIpv6,
    loga::{
        fatal,
        ResultContext,
    },
    manglelib::modify,
    network_interface::{
        NetworkInterface,
        NetworkInterfaceConfig,
    },
    nfq::{
        Queue,
        Verdict,
    },
    std::{
        panic,
        process,
        sync::{
            Arc,
            Mutex,
        },
        thread::{
            sleep,
            spawn,
        },
        time::Duration,
    },
};

mod manglelib;

#[derive(Aargvark)]
struct Args {
    /// Name of address to get ipv6 address from to add to RDNSS
    #[vark(flag = "--interface")]
    interface: String,
    /// How often (seconds) to recheck the interface for a new IP. Defaults to 60s.
    recheck_period: Option<u64>,
    /// Which netfilter queue to read from
    #[vark(flag = "--nf-queue")]
    nf_queue: u16,
    /// Mark packets after modification - you must use this in your nftables rule to
    /// prevent re-processing the same packet (feedback loop).
    #[vark(flag = "--nf-mark")]
    nf_mark: u32,
    /// Override/inject RA MTU
    mtu: Option<u32>,
}

fn main() {
    match || -> Result<(), loga::Error> {
        let orig_hook = panic::take_hook();
        panic::set_hook(Box::new(move |panic_info| {
            orig_hook(panic_info);
            process::exit(1);
        }));
        let args = vark::<Args>();
        let recheck_period = args.recheck_period.unwrap_or(60);
        let mut nf_queue = Queue::open().context("Error opening netfilter queue")?;
        nf_queue.bind(args.nf_queue).context("Error binding netfilter queue")?;
        let ip_rxtx = Arc::new(Mutex::new(None));

        // Wait for initial ip, or get next ip
        spawn({
            let ip_rxtx = ip_rxtx.clone();
            let want_iface = args.interface;
            move || {
                let mut found_first = false;
                loop {
                    let mut found = None;
                    for iface in NetworkInterface::show()
                        .context("Failure listing network interfaces")
                        .unwrap()
                        .iter() {
                        if want_iface != iface.name {
                            continue;
                        }
                        for addr in &iface.addr {
                            let std::net::IpAddr::V6(addr) = addr.ip() else {
                                continue;
                            };
                            if !addr.unstable_is_global() {
                                continue;
                            }
                            found = Some(addr);
                            found_first = true;
                        }
                    }
                    if found.is_none() {
                        eprintln!("Interface not found or no global ipv6 address found on interface.");
                    }
                    *ip_rxtx.lock().unwrap() = Some(found);
                    if !found_first {
                        sleep(Duration::from_secs(5));
                    } else {
                        sleep(Duration::from_secs(recheck_period));
                    }
                }
            }
        });

        // Drop messages until we get an ip
        eprintln!("Starting, waiting for first packet, then dropping packets until global IP found");
        let (mut nf_queue_msg, mut ip) = loop {
            let mut nf_queue_msg = nf_queue.recv().context("Error reading netfilter queue")?;
            if let Some(Some(ip)) = ip_rxtx.lock().unwrap().take() {
                break (nf_queue_msg, ip);
            }
            nf_queue_msg.set_verdict(Verdict::Drop);
            nf_queue.verdict(nf_queue_msg).context("Error setting netfilter message verdict")?;
        };
        loop {
            eprintln!("Found global IP {}, switching from dropping to rewriting packets", ip);

            // Replace RDNSS in subsequent RAs (continue with last msg of previous loop).
            // Until we lose the ip again.
            loop {
                // Modify
                match modify(nf_queue_msg.get_payload(), ip, args.mtu) {
                    Some(ipv6_packet) => {
                        nf_queue_msg.set_payload(ipv6_packet);
                        nf_queue_msg.set_nfmark(args.nf_mark);
                        nf_queue_msg.set_verdict(Verdict::Repeat);
                        nf_queue.verdict(nf_queue_msg).context("Error setting netfilter message verdict")?;
                    },
                    None => {
                        // Bad, not a real packet, or undocumented headers or other issues
                        nf_queue_msg.set_verdict(Verdict::Drop);
                        nf_queue.verdict(nf_queue_msg).context("Error setting netfilter message verdict")?;
                    },
                }

                // Wait for next msg
                nf_queue_msg = nf_queue.recv().context("Error reading netfilter queue")?;

                // Check for ips changes
                if let Some(update) = ip_rxtx.lock().unwrap().take() {
                    match update {
                        Some(new_ip) => {
                            ip = new_ip;
                        },
                        None => {
                            break;
                        },
                    }
                }
            }
            eprintln!("Lost IP, switching from modifying packets to dropping them");

            // Drop messages again
            loop {
                nf_queue_msg = nf_queue.recv().context("Error reading netfilter queue")?;
                if let Some(Some(new_ip)) = ip_rxtx.lock().unwrap().take() {
                    ip = new_ip;
                    break;
                }
                nf_queue_msg.set_verdict(Verdict::Drop);
                nf_queue.verdict(nf_queue_msg).context("Error setting netfilter message verdict")?;
            };
        }
    }() {
        Ok(_) => (),
        Err(e) => fatal(e),
    }
}
