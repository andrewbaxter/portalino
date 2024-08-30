#!/usr/bin/bash -xeu
cargo run --manifest-path source/rust/glue/Cargo.toml --bin admin_build_os -- "$@"