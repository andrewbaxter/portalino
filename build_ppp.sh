#!/usr/bin/env bash
set -xeu
# Build the PPP (bridge + NAT64 via PPPoE upstream) configuration.
# Required env vars: PPP_USER=user PPP_PASSWORD=password
# Optional env vars: SSH_AUTHORIZED_KEYS_DIR=/path/to/keys SSH_AUTHORIZED_KEY="ssh-ed25519 ..."
if [ -z "${PPP_USER:-}" ]; then
    echo "Error: PPP_USER is required" >&2
    exit 1
fi
if [ -z "${PPP_PASSWORD:-}" ]; then
    echo "Error: PPP_PASSWORD is required" >&2
    exit 1
fi
mkdir -p stage
args=(--argstr ppp_user "$PPP_USER" --argstr ppp_password "$PPP_PASSWORD")
if [ -n "${SSH_AUTHORIZED_KEYS_DIR:-}" ]; then
    args+=(--arg ssh_authorized_keys_dir "$SSH_AUTHORIZED_KEYS_DIR")
elif [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
    args+=(--argstr ssh_authorized_key "$SSH_AUTHORIZED_KEY")
fi
nix build -o stage/imageout -f source/os/main_ppp.nix "${args[@]}" config.system.build.myiso
