#!/usr/bin/bash -xeu
# Flash the built ISO to a USB drive.
# Usage: flash_os.sh <device>  (e.g. /dev/sdb)
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <device>"
    echo "Example: $0 /dev/sdb"
    exit 1
fi
sudo cp --dereference stage/imageout/iso/disk.iso "$1"
