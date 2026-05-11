#!/usr/bin/env bash
set -xeu
# Build the DHCP (bridge + NAT64 via DHCP upstream) configuration.
# Optional env vars: OVERRIDE_MTU=1492 SSH_AUTHORIZED_KEYS_DIR=/path/to/keys SSH_AUTHORIZED_KEY="ssh-ed25519 ..."
mkdir -p stage
args=()
if [ -n "${OVERRIDE_MTU:-}" ]; then
    args+=(--arg override_mtu "$OVERRIDE_MTU")
fi
if [ -n "${SSH_AUTHORIZED_KEYS_DIR:-}" ]; then
    args+=(--arg ssh_authorized_keys_dir "$SSH_AUTHORIZED_KEYS_DIR")
elif [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
    args+=(--argstr ssh_authorized_key "$SSH_AUTHORIZED_KEY")
fi
nix build -o stage/imageout -f source/os/main_dhcp.nix "${args[@]}" config.system.build.myiso
