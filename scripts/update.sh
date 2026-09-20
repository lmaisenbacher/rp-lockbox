#!/bin/bash
# Install the build products of this checkout over the running installation
# and restart the services. Run as root (rw/ro remount the root file system,
# the targets are /opt/redpitaya and /etc/systemd/system). Stopping lockbox
# reloads the bitstream on the next start, which drops the lock: run this at
# a relock window. Installs what was last BUILT in the tree: rebuild after a
# branch change.
systemctl stop lockbox-web-interface
systemctl stop lockbox-monitor
systemctl stop lockbox
rw
cp fpga/prj/lockbox/out/red_pitaya.bit /opt/redpitaya/fpga/lockbox.bit
cp api/lib/liblockbox.so /opt/redpitaya/lib/
cp scpi-server/lockbox-server /opt/redpitaya/bin/
cp monitor/lockbox-monitor /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockbox.service /etc/systemd/system/
cp systemd/lockbox-monitor.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
ro
systemctl daemon-reload
systemctl start lockbox
systemctl start lockbox-monitor
systemctl start lockbox-web-interface
