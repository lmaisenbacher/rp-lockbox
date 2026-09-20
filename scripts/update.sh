#!/bin/bash
# Install the build products of this checkout over the running installation
# and restart the services. Run as root (rw/ro remount the root file system,
# the targets are /opt/redpitaya and /etc/systemd/system). Installs what was
# last BUILT in the tree: rebuild after a branch change.
#
# The lock lives in the gateware and survives a restart of the software
# alone: when the bitfile in the tree is the one already installed, the FPGA
# is not reprogrammed (a runtime drop-in empties the lockbox service's
# ExecStartPre for this one start) and the lock is kept. The SCPI server
# rewrites the PID registers from the saved pid_settings.conf at its start,
# so SAVE THE PARAMETERS first (web page, or LOCKbox:CONFig:SAVE) if they
# changed since the last save. A bitfile that differs from the installed one
# is installed and loaded, which drops the lock; --reload-fpga forces that.
set -e
cd "$(dirname "$0")/.."

BIT=fpga/prj/lockbox/out/red_pitaya.bit
INSTALLED_BIT=/opt/redpitaya/fpga/lockbox.bit
DROPIN_DIR=/run/systemd/system/lockbox.service.d

for f in "$BIT" api/lib/liblockbox.so scpi-server/lockbox-server monitor/lockbox-monitor; do
    if [ ! -f "$f" ]; then
        echo "update.sh: $f is missing - build first (make api scpi monitor)" >&2
        exit 1
    fi
done

reload=0
if [ "$1" = "--reload-fpga" ] || [ ! -f "$INSTALLED_BIT" ] || ! cmp -s "$BIT" "$INSTALLED_BIT"; then
    reload=1
fi

systemctl stop lockbox-web-interface
systemctl stop lockbox-monitor 2>/dev/null || true
systemctl stop lockbox
rw
if [ $reload -eq 1 ]; then
    cp "$BIT" "$INSTALLED_BIT"
fi
cp api/lib/liblockbox.so /opt/redpitaya/lib/
cp scpi-server/lockbox-server /opt/redpitaya/bin/
cp monitor/lockbox-monitor /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockbox.service /etc/systemd/system/
cp systemd/lockbox-monitor.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
ro
if [ $reload -eq 0 ]; then
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\n' > "$DROPIN_DIR/keep-lock.conf"
fi
systemctl daemon-reload
systemctl enable lockbox-monitor >/dev/null 2>&1
systemctl start lockbox
systemctl start lockbox-monitor
systemctl start lockbox-web-interface
if [ $reload -eq 0 ]; then
    # The next start of lockbox (a reboot, a manual restart) reprograms as usual
    rm -r "$DROPIN_DIR"
    systemctl daemon-reload
    echo "Installed without reprogramming the FPGA (bitfile unchanged): the lock is kept."
else
    echo "Installed and reprogrammed the FPGA: the lock was dropped, relock."
fi
