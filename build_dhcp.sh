#!/usr/bin/bash -xeu
# Build the DHCP (bridge + NAT64 via DHCP upstream) configuration.
# Optional nix args: --arg override_mtu 1492 --arg ssh_authorized_keys_dir /path/to/keys
mkdir -p stage
nix build -o stage/imageout -f source/os/main_dhcp.nix "$@" config.system.build.myiso
