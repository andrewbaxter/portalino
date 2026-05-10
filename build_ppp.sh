#!/usr/bin/bash -xeu
# Build the PPP (bridge + NAT64 via PPPoE upstream) configuration.
# Required nix args: --argstr ppp_user USER --argstr ppp_password PASSWORD
# Optional nix args: --arg override_mtu 1492 --arg ssh_authorized_keys_dir /path/to/keys
mkdir -p stage
nix build -o stage/imageout -f source/os/main_ppp.nix "$@" config.system.build.myiso
