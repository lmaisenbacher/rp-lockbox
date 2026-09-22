#!/bin/bash
# Install the build products of this checkout over the running installation
# and restart the services. Installs what was last BUILT in the tree:
# rebuild after a branch change.
#
# RUN IT FROM A ROOT LOGIN SHELL:
#
#     sudo -i
#     cd rp-lockbox          # or wherever the checkout is
#     scripts/update.sh
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
# ExecStartPre for the starts made here) and the lock is kept. A bitfile
# that differs from the installed one is installed and loaded, which drops
# the lock; --reload-fpga forces that.
#
# EVERY path restarts the SCPI server, and the server rewrites the PID
# registers from the saved pid_settings.conf at its start: whatever was
# changed since the last save is lost. So the script states what this run
# will do and waits for a confirmation, leaving time to save the parameters
# (web page, or LOCKbox:CONFig:SAVE) and start again; -y skips the question.
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

if [ "$(id -u)" -ne 0 ]; then
    echo "update.sh: run this as root, from a login shell: sudo -i, then" >&2
    echo "           scripts/update.sh in the checkout" >&2
    exit 1
fi

for helper in rw ro; do
    if ! command -v "$helper" >/dev/null 2>&1; then
        echo "update.sh: '$helper' is not on the PATH - run this from a root" >&2
        echo "           login shell: sudo -i, then scripts/update.sh" >&2
        exit 1
    fi
done

confirm() {
    local answer
    if [ "$assume_yes" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "update.sh: no terminal to ask - pass -y to run it anyway" >&2
        exit 1
    fi
    while true; do
        printf '  [c] continue, [q] quit: '
        read -r answer || answer=q
        case "$answer" in
            c|C|'') return 0 ;;
            q|Q) echo "update.sh: nothing was changed"; exit 0 ;;
        esac
    done
}

for f in "$BIT" api/lib/liblockbox.so scpi-server/lockbox-server monitor/lockbox-monitor; do
    if [ ! -f "$f" ]; then
        echo "update.sh: $f is missing - build first (make api scpi monitor)" >&2
        exit 1
    fi
done

reload=0
assume_yes=0
for arg in "$@"; do
    case "$arg" in
        --reload-fpga) reload=1 ;;
        -y|--yes) assume_yes=1 ;;
        *) echo "update.sh: unknown argument '$arg'" >&2; exit 1 ;;
    esac
done
if [ ! -f "$INSTALLED_BIT" ] || ! cmp -s "$BIT" "$INSTALLED_BIT"; then
    reload=1
fi

# What this run will do, before it does it
echo "update.sh: about to install and restart the lockbox software."
if [ $reload -eq 1 ]; then
    echo "  - the bitfile differs from the installed one: the FPGA is"
    echo "    reprogrammed and THE LOCK WILL DROP"
else
    echo "  - the bitfile is the installed one: the FPGA is left alone and"
    echo "    the lock is kept"
fi
echo "  - the SCPI server restores $SETTINGS"
echo "    at its start: PID settings changed since the last save are lost"
confirm
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
