#!/usr/bin/env bash
set -xeu
# Build the NAT64 (upstream NAT64) configuration.
# Optional env vars: SSH_AUTHORIZED_KEYS_DIR=/path/to/keys SSH_AUTHORIZED_KEY="ssh-ed25519 ..."
mkdir -p stage
args=()
if [ -n "${SSH_AUTHORIZED_KEYS_DIR:-}" ]; then
    args+=(--arg ssh_authorized_keys_dir "$SSH_AUTHORIZED_KEYS_DIR")
elif [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
    args+=(--argstr ssh_authorized_key "$SSH_AUTHORIZED_KEY")
fi
nix build -o stage/imageout -f source/os/main_nat64.nix "${args[@]}" config.system.build.myiso
