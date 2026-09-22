#!/bin/bash
# Install the release archive over the running installation.
# Run from a root shell (sudo -i): `rw` and `ro` remount the
# read-only installation directories (/opt/redpitaya is its own vfat
# partition) and are on root's PATH, not on the one `sudo <script>`
# hands out.
set -e
for helper in rw ro; do
    if ! command -v "$helper" >/dev/null 2>&1; then
        echo "$(basename "$0"): '$helper' is not on the PATH - run this from" >&2
        echo "           a root shell: sudo -i" >&2
        exit 1
    fi
done

rw
cp fpga/lockbox.bit /opt/redpitaya/fpga/
cp lib/liblockbox.so /opt/redpitaya/lib/
cp bin/lockbox-server /opt/redpitaya/bin/
cp bin/lockbox-monitor /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockbox.service /etc/systemd/system/
cp systemd/lockbox-monitor.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
ro
