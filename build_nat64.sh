#!/usr/bin/bash -xeu
# Build the NAT64 (upstream NAT64) configuration.
# Optional nix args: --arg ssh_authorized_keys_dir /path/to/keys
mkdir -p stage
nix build -o stage/imageout -f source/os/main_nat64.nix "$@" config.system.build.myiso
