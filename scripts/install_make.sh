#!/bin/bash
# Install a built checkout over the running installation. Run as root.
set -e

# The root file system is mounted read-only, and `rw`/`ro` are shell
# FUNCTIONS of the interactive profile: absent in a script run under sudo,
# so the remounts are spelled out here. The read-only state is restored
# only if that is how the file system was found.
root_was_ro=0
case ",$(findmnt -no OPTIONS / 2>/dev/null)," in
    *,ro,*) root_was_ro=1 ;;
esac

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    if [ "$root_was_ro" -eq 1 ]; then
        mount -o remount,ro /
    fi
}

remount_rw
cp fpga/prj/lockbox/out/red_pitaya.bit /opt/redpitaya/fpga/lockbox.bit
cp api/lib/liblockbox.so /opt/redpitaya/lib/
cp scpi-server/lockbox-server /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockbox.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
remount_ro
