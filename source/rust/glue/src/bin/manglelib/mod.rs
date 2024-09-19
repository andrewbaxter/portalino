use {
    flowcontrol::shed,
    std::net::Ipv6Addr,
};

#[cfg(test)]
mod test_modify_dhcp_ex1;
#[cfg(test)]
mod test_checksum;
#[cfg(test)]
mod test_ra_modify_mtu;
#[cfg(test)]
mod test_ra_inject_mtu;

#[inline]
fn checksum_roll(sum32: &mut u32, bytes: &[u8]) {
    let mut iter = bytes.chunks_exact(2);
    for x in &mut iter {
        *sum32 += u16::from_ne_bytes(x.try_into().unwrap()) as u32;
    }
    if let Some(remainder) = iter.remainder().first() {
        let pair = [*remainder, 0x00];
        *sum32 += u16::from_ne_bytes(pair) as u32;
    }
}

fn checksum_finish(sum32: u32) -> [u8; 2] {
    let high = (sum32 >> 16) as u16;
    let low = (sum32 & 0xFFFF) as u16;
    return (!(high + low).to_be()).to_be_bytes();
}

fn icmpv6_udp_checksum(source: &[u8]) -> Option<[u8; 2]> {
    // * IPv6 pseudo-header https://datatracker.ietf.org/doc/html/rfc2460#section-8.1
    //
    // * ICMP https://datatracker.ietf.org/doc/html/rfc4443#section-2.3
    //
    //   Pseudo header + whole body
    //
    // * UDP https://datatracker.ietf.org/doc/html/rfc768
    //
    //   Pseudo header + whole body
    let mut sum32 = 0u32;

    // Icmpv6 length (pseudo header)
    checksum_roll(&mut sum32, source.get(4 .. 6)?);

    // Next header (pseudo header)
    sum32 += u16::from_ne_bytes([0x00, *source.get(6)?]) as u32;

    // Source addr (pseudo header), dest addr (pseudo header), payload
    checksum_roll(&mut sum32, source.get(8..)?);

    // Then do some rfc magic
    return Some(checksum_finish(sum32));
}

pub fn modify(source: &[u8], ip: Ipv6Addr, mtu: Option<u32>) -> Option<Vec<u8>> {
    let mut ipv6_packet = vec![];
    ipv6_packet.reserve(source.len() + 128);
    ipv6_packet.extend_from_slice(source);

    #[must_use]
    fn splice(packet: &mut Vec<u8>, start: usize, end: Option<usize>, data: &[u8]) -> Option<()> {
        if start > packet.len() {
            return None;
        }
        if let Some(end) = end {
            if end > packet.len() {
                return None;
            }
            packet.splice(start .. end, data.iter().cloned());
        } else {
            packet.splice(start.., data.iter().cloned());
        }
        return Some(());
    }

    #[must_use]
    fn replace_u16(packet: &mut Vec<u8>, start: usize, data: &[u8; 2]) -> Option<()> {
        packet.get_mut(start .. start + 2)?.copy_from_slice(data);
        return Some(());
    }

    fn read_u16(packet: &[u8], start: usize) -> Option<u16> {
        return Some(u16::from_be_bytes(packet.get(start .. start + 2)?.try_into().unwrap()));
    }

    const IPV6_PAYLOAD_START: usize = 40;
    match *ipv6_packet.get(6)? {
        // ICMP
        //
        // * https://datatracker.ietf.org/doc/html/rfc4443
        //
        // RA
        //
        // * https://datatracker.ietf.org/doc/html/rfc4861#section-4.2
        //
        // Only replace RA if present.  If it's not present, it may come via DHCP so don't
        // add things here and confuse devices (also need the option for a lifetime to
        // copy).
        58 => {
            // Confirm it's RA
            let Some(type_) = ipv6_packet.get(IPV6_PAYLOAD_START) else {
                return None;
            };
            if *type_ != 134 {
                return None;
            }

            // Modify RA
            const OPT_MTU: u8 = 5;
            const OPT_RDNSS: u8 = 25;
            const RA_FIXED_HEADER_SIZE: usize = 16;
            const RA_OPTIONS_START: usize = IPV6_PAYLOAD_START + RA_FIXED_HEADER_SIZE;

            // Set other info flag
            *ipv6_packet.get_mut(IPV6_PAYLOAD_START + 5)? |= 0x40;

            // Copy options, find + filter out RDNSS
            struct FoundRdnss {
                lifetime: u16,
            }

            let mut found_rdnss = None;
            let mut at_option_start = RA_OPTIONS_START;
            let mut new_options = vec![];
            new_options.reserve(ipv6_packet.len() - IPV6_PAYLOAD_START);
            let mut modify = false;
            if mtu.is_some() {
                modify = true;
            }
            loop {
                if at_option_start == ipv6_packet.len() {
                    break;
                }
                let at_option_type = *ipv6_packet.get(at_option_start)?;
                let at_option_length = *ipv6_packet.get(at_option_start + 1)? as usize * 8;
                eprintln!("option type {} len {}; {:?}", at_option_type, at_option_length, mtu);
                shed!{
                    'next_option _;
                    if at_option_type == OPT_RDNSS {
                        found_rdnss = Some(FoundRdnss { lifetime: read_u16(&ipv6_packet, at_option_start + 4)? });
                        modify = true;
                        break 'next_option;
                    }
                    if mtu.is_some() && at_option_type == OPT_MTU {
                        break 'next_option;
                    }
                    // Keep anything we're not going to modify
                    new_options.extend_from_slice(ipv6_packet.get(at_option_start .. at_option_start + at_option_length)?);
                }
                at_option_start += at_option_length;
            }
            if !modify {
                return Some(source.to_vec());
            }

            // Create custom MTU
            if let Some(mtu) = mtu {
                new_options.push(OPT_MTU);
                new_options.push(1u8);
                new_options.extend_from_slice(&[0, 0]);
                new_options.extend(mtu.to_be_bytes());
            }

            // Generate custom RDNSS
            if let Some(found_rdnss) = found_rdnss {
                new_options.push(OPT_RDNSS);
                let lifetime_bytes = found_rdnss.lifetime.to_be_bytes();
                let ip_bytes = ip.octets();
                new_options.push(((1 + 1 + 2 + lifetime_bytes.len() + ip_bytes.len()) / 8) as u8);
                new_options.extend_from_slice(&[0, 0]);
                new_options.extend(lifetime_bytes);
                new_options.extend(ip_bytes);
            }

            // Replace options
            splice(&mut ipv6_packet, RA_OPTIONS_START, None, &new_options)?;

            // Update ipv6 payload length
            replace_u16(&mut ipv6_packet, 4, &((RA_FIXED_HEADER_SIZE + new_options.len()) as u16).to_be_bytes())?;

            // Recalc checksum
            ipv6_packet.get_mut(IPV6_PAYLOAD_START + 2 .. IPV6_PAYLOAD_START + 4)?.fill(0);
            let new_checksum = icmpv6_udp_checksum(&ipv6_packet)?;
            replace_u16(&mut ipv6_packet, IPV6_PAYLOAD_START + 2, &new_checksum)?;
        },
        // UDP (DHCPv6)
        //
        // * https://datatracker.ietf.org/doc/html/rfc8415
        17 => {
            const UDP_FIXED_HEADER_SIZE: usize = 8;

            // Confirm it's reply
            if *ipv6_packet.get(IPV6_PAYLOAD_START + UDP_FIXED_HEADER_SIZE)? != 7 {
                return None;
            }

            // Copy + filter out options
            const OPT_DNS: &[u8] = &[0x00, 0x17];
            const DHCP_FIXED_HEADER_SIZE: usize = 4;
            const DHCP_OPTIONS_START: usize = IPV6_PAYLOAD_START + UDP_FIXED_HEADER_SIZE + DHCP_FIXED_HEADER_SIZE;
            let mut at_option_start = DHCP_OPTIONS_START;
            let mut new_options = vec![];
            let mut found_dns = false;
            new_options.reserve(ipv6_packet.len() - IPV6_PAYLOAD_START);
            loop {
                if at_option_start == ipv6_packet.len() {
                    break;
                }
                let at_option_type = ipv6_packet.get(at_option_start .. at_option_start + 2)?;
                let at_option_length = read_u16(&ipv6_packet, at_option_start + 2)? as usize + 4;
                shed!{
                    'next_option _;
                    if at_option_type == OPT_DNS {
                        // Drop existing DNS
                        found_dns = true;
                        break 'next_option;
                    }
                    // Keep anything not DNS
                    new_options.extend_from_slice(ipv6_packet.get(at_option_start .. at_option_start + at_option_length)?);
                }
                at_option_start += at_option_length;
            }
            if !found_dns {
                return Some(source.to_vec());
            }

            // Generate custom DNS option
            new_options.extend_from_slice(OPT_DNS);
            new_options.extend_from_slice(
                // Length (16 bytes, 1 ip)
                &[0x00, 0x10],
            );
            let ip_bytes = ip.octets();
            new_options.extend(ip_bytes);

            // Replace options
            splice(&mut ipv6_packet, DHCP_OPTIONS_START, None, &new_options)?;

            // Update payload length in udp header
            let new_len = UDP_FIXED_HEADER_SIZE + DHCP_FIXED_HEADER_SIZE + new_options.len();
            replace_u16(&mut ipv6_packet, IPV6_PAYLOAD_START + 4, &(new_len as u16).to_be_bytes())?;

            // Update payload length in ipv6 header
            replace_u16(&mut ipv6_packet, 4, &(new_len as u16).to_be_bytes())?;

            // Recalc checksum
            ipv6_packet.get_mut(IPV6_PAYLOAD_START + 6 .. IPV6_PAYLOAD_START + 8)?.fill(0);
            let new_checksum = icmpv6_udp_checksum(&ipv6_packet)?;
            replace_u16(&mut ipv6_packet, IPV6_PAYLOAD_START + 6, &new_checksum)?;
        },
        _ => {
            return None;
        },
    }

    // Done
    return Some(ipv6_packet);
}
