#!/bin/bash
# Install a built checkout over the running installation.
# Run from a root login shell (sudo -i): `rw` and `ro` remount the
# read-only installation directories (/opt/redpitaya is its own vfat
# partition) and are on root's PATH, not on the one `sudo <script>`
# hands out.
set -e
if [ "$(id -u)" -ne 0 ]; then
    echo "install_make.sh: run this as root, from a login shell: sudo -i, then" >&2
    echo "           scripts/install_make.sh" >&2
    exit 1
fi

for helper in rw ro; do
    if ! command -v "$helper" >/dev/null 2>&1; then
        echo "$(basename "$0"): '$helper' is not on the PATH - run this from" >&2
        echo "           a root login shell: sudo -i" >&2
        exit 1
    fi
done

rw
cp fpga/prj/lockbox/out/red_pitaya.bit /opt/redpitaya/fpga/lockbox.bit
cp api/lib/liblockbox.so /opt/redpitaya/lib/
cp scpi-server/lockbox-server /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockbox.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
ro
