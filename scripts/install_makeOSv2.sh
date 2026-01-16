#!/bin/bash
rw
cp fpga/prj/lockbox/out/red_pitaya.bit.bin /opt/redpitaya/fpga/lockbox.bit.bin
cp api/lib/liblockbox.so /opt/redpitaya/lib/
cp scpi-server/lockbox-server /opt/redpitaya/bin/
cp -r web-interface /opt/redpitaya/
cp systemd/lockboxOSv2.service /etc/systemd/system/
cp systemd/lockbox-web-interface.service /etc/systemd/system/
ro
