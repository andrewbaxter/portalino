# Portalino

This is a Spaghettinuum-enabled IPv6 only drop in network router/gateway image. Just flash a drive, plug it in, and boot.

It has several features:

- Spaghettinuum node with DNS resolver set up to use DNS64 upstream servers

- Automatic wireless access point setup

  A SSID and password is randomly generated at first boot (you can reset it by wiping the disk or SSHing in and deleting the relevant files in `/mnt/persistent`, then rebooting)

- An info page at `http://portalino.internal` showing SSID and password, a wireless setup QR code, and the spaghettinuum ID

- In the bridged images, sets up a local NAT64 resolver

- In the bridged images, injects the gateway as RDNSS/DNS options in RA and DHCPv6 packets

  This means devices on the network will automatically use the local NAT64 gateway. (Devices must not be configured to use static non-DNS64 servers)

This should work on any linux-capable hardware with 2 ethernet ports and an attached disk.

The OS is immutable (aside from limited config and caches stored on a persistent disk). To upgrade, flash a new version to the USB drive and reboot.

## Images

There are several configurations, depending on your ISP:

- ISP-provided NAT64, DHCPv6 PD

  This image is zero-configuration. (no pre-built image yet)

- DHCP + bridged IPv6

  This is if you're piggybacking off another router and your ISP doesn't provide DHCPv6 PD, or if your ISP provides IPv4 via DHCP.

  This image is zero-configuration. (no pre-built image yet)

- PPP + bridged IPv6

  You need to build the image: `./build_os.sh --ipv4-mode ppp --user abcd@efgh.ijkl --password hunter2`

  Then flash it: `./flash_os.sh`

  For more details see "Building" below.

## Building

In order to build the image locally you'll need Rust (+cargo) and Nix.

Build the image with `./build_os.sh`

For additional build options see `./build_os.sh -h`.

Flash it with `./flash_os.sh` (glorified copy). It looks for newly inserted drives, so don't insert your USB drive until it prompts you.

### Additional options

- `--ssh-authorized-keys-dir` - this is a directory of SSH public keys, one per file, to be installed in the image for remote access.
