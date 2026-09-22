#!/bin/bash
# Install the build products of this checkout over the running installation
# and restart the services. Run as root (the root file system is remounted
# writable for the copies; the targets are /opt/redpitaya and
# /etc/systemd/system). Installs what was last BUILT in the tree: rebuild
# after a branch change.
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
SETTINGS=/opt/redpitaya/pid_settings.conf
DROPIN_DIR=/run/systemd/system/lockbox.service.d

# The root file system is mounted read-only. `rw` and `ro` are shell
# FUNCTIONS of the interactive profile and are not defined in a script run
# under sudo, so the remounts are spelled out; the read-only state is
# restored only if that is how the file system was found.
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

systemctl stop lockbox-web-interface
systemctl stop lockbox-monitor 2>/dev/null || true
systemctl stop lockbox
remount_rw
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
remount_ro
if [ $reload -eq 0 ]; then
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\n' > "$DROPIN_DIR/keep-lock.conf"
fi
systemctl daemon-reload
systemctl enable lockbox-monitor >/dev/null 2>&1
systemctl start lockbox
systemctl start lockbox-monitor
systemctl start lockbox-web-interface
echo "update.sh: installed, services started"
if [ $reload -eq 0 ]; then
    # The next start of lockbox (a reboot, a manual restart) reprograms as usual
    rm -r "$DROPIN_DIR"
    systemctl daemon-reload
    echo "Installed without reprogramming the FPGA (bitfile unchanged): the lock is kept."
else
    echo "Installed and reprogrammed the FPGA: the lock was dropped, relock."
fi
