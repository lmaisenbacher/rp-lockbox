#!/bin/bash
# Install the build products of this checkout over the running installation
# and restart the services. Installs what was last BUILT in the tree:
# rebuild after a branch change.
#
# RUN IT FROM A ROOT LOGIN SHELL:
#
#     sudo -i
#     cd ~unitrap/rp-lockbox && scripts/update.sh
#
# like the other install scripts. The installation directories are on
# read-only file systems (/opt/redpitaya is its own vfat partition), and the
# `rw`/`ro` helpers that remount them are on root's PATH but not on the one
# `sudo <script>` hands out, so the script checks for them and stops before
# touching anything if they are missing.
#
# The lock lives in the gateware and survives a restart of the software
# alone: when the bitfile in the tree is the one already installed, the FPGA
# is not reprogrammed (a runtime drop-in empties the lockbox service's
# ExecStartPre for the starts made here) and the lock is kept. The SCPI
# server rewrites the PID registers from the saved pid_settings.conf at its
# start, so SAVE THE PARAMETERS first (web page, or LOCKbox:CONFig:SAVE) if
# they changed since the last save. A bitfile that differs from the
# installed one is installed and loaded, which drops the lock;
# --reload-fpga forces that.
set -e
cd "$(dirname "$0")/.."

BIT=fpga/prj/lockbox/out/red_pitaya.bit
INSTALLED_BIT=/opt/redpitaya/fpga/lockbox.bit
SETTINGS=/opt/redpitaya/pid_settings.conf
DROPIN_DIR=/run/systemd/system/lockbox.service.d
SERVICES="lockbox lockbox-monitor lockbox-web-interface"

#: Whether the services are stopped and not yet started again
stopped=0

on_exit() {
    status=$?
    if [ $status -ne 0 ]; then
        echo "update.sh: failed (exit $status)" >&2
        if [ $stopped -eq 1 ]; then
            # Never leave the lockbox without its software: the starts
            # below keep the lock, the drop-in is still in place
            echo "update.sh: starting the services again" >&2
            for s in $SERVICES; do
                systemctl start "$s" || true
            done
        fi
    fi
    # The keep-lock drop-in is for this script's starts only: the next
    # start (a reboot, a manual restart) reprograms the FPGA as usual
    rm -rf "$DROPIN_DIR"
    systemctl daemon-reload 2>/dev/null || true
}
trap on_exit EXIT

for helper in rw ro; do
    if ! command -v "$helper" >/dev/null 2>&1; then
        echo "update.sh: '$helper' is not on the PATH - run this from a root" >&2
        echo "           login shell: sudo -i, then scripts/update.sh" >&2
        exit 1
    fi
done

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

# Which path this run takes, before it takes it: the lock survives the
# software restart, not a reprogram of the gateware
if [ $reload -eq 1 ]; then
    echo "update.sh: the bitfile differs from the installed one - the FPGA"
    echo "           is reprogrammed and THE LOCK WILL DROP"
else
    echo "update.sh: the bitfile is the installed one - the FPGA is left"
    echo "           alone and the lock is kept"
fi
echo "update.sh: the SCPI server rewrites the PID registers from"
echo "           $SETTINGS at its start, so what was last SAVED is what"
echo "           the lockbox runs afterwards"

# The drop-in goes in BEFORE anything is stopped, so that every start from
# here on - this script's, or the recovery of a failed run - keeps the lock
if [ $reload -eq 0 ]; then
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\n' > "$DROPIN_DIR/keep-lock.conf"
    systemctl daemon-reload
fi

systemctl stop lockbox-web-interface
systemctl stop lockbox-monitor 2>/dev/null || true
systemctl stop lockbox
stopped=1

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

systemctl daemon-reload
systemctl enable lockbox-monitor >/dev/null 2>&1
systemctl start lockbox
systemctl start lockbox-monitor
systemctl start lockbox-web-interface
stopped=0
echo "update.sh: installed, services started"
