#!/bin/bash
# End-to-end test of the lockbox monitor daemon on a development host: the
# daemon runs against the stub liblockbox (stub_lockbox.c) with a scripted
# sequence of lock flags, and `readmon` reads the shared block back through
# the library's reader. Run by `make test`.
set -u
cd "$(dirname "$0")"

CONF=./lockbox-monitor-test.conf
rm -f "$CONF"

fail=0
check() {
    # check <description> <actual> <expected>
    if [ "$2" != "$3" ]; then
        echo "FAIL: $1: got '$2', expected '$3'"
        fail=1
    fi
}
check_near() {
    # check_near <description> <actual> <expected> <tolerance>
    if ! awk -v a="$2" -v e="$3" -v t="$4" 'BEGIN { exit !((a - e) <= t && (e - a) <= t) }'; then
        echo "FAIL: $1: got '$2', expected '$3' within $4"
        fail=1
    fi
}
value() {
    # value <readmon output> <key>
    echo "$1" | sed -n "s/^$2=//p"
}

# Timeline (1 ms per poll): 0.7 s locked (the 0.5 s grace passes), a 3 ms
# drop of PID 0, 0.3 s locked, two 4 ms dips 2 ms apart (one merged drop of
# 10 ms), then locked with PID 1 scanning (hold on) and its flag flickering
SCRIPT="700:f:0,3:e:0,300:f:0,4:e:0,2:f:0,4:e:0,200:f:2,100:d:2,100:f:2,100:d:2,100000:f:2"
STUB_SCRIPT="$SCRIPT" ./lockbox-monitor-host --grace-s 0.5 --conf "$CONF" &
daemon=$!
trap 'kill $daemon 2>/dev/null' EXIT
sleep 3

out=$(./readmon)
status=$?
check "readmon exit status while running" "$status" "0"
check "alive" "$(value "$out" monitor.alive)" "1"
check "PID 0 drops" "$(value "$out" pid0.unlocks_total)" "2"
check "PID 0 raw edges" "$(value "$out" pid0.raw_unlock_edges)" "3"
check "PID 0 locked again" "$(value "$out" pid0.locked)" "1"
check "PID 0 no open drop" "$(value "$out" pid0.drop_open)" "0"
check "PID 0 servo on" "$(value "$out" pid0.servo_on)" "1"
check "PID 0 drops since servo on" "$(value "$out" pid0.unlocks_since_servo)" "2"
check_near "PID 0 last drop 10 ms" "$(value "$out" pid0.last_unlock_s)" "0.010" "0.0015"
check_near "PID 0 unlocked total 13 ms" "$(value "$out" pid0.unlocked_total_s)" "0.013" "0.002"
check_near "PID 0 longest since servo" "$(value "$out" pid0.longest_since_servo_s)" "0.010" "0.0015"
check "PID 1 scanning: no drops" "$(value "$out" pid1.unlocks_total)" "0"
check "PID 1 servo off" "$(value "$out" pid1.servo_on)" "0"
check "PID 1 servo age -1" "$(value "$out" pid1.servo_age_s)" "-1.000"
check "PID 2 untouched" "$(value "$out" pid2.unlocks_total)" "0"
check "PID 3 untouched" "$(value "$out" pid3.unlocks_total)" "0"
check "stats decimation default" "$(value "$out" monitor.stats_decimation)" "1024"
check "input 1 decimation" "$(value "$out" in1.decimation)" "1024"
check_near "input 1 mean" "$(value "$out" in1.mean_v)" "0.5" "0.0005"
check_near "input 1 sd" "$(value "$out" in1.sd_v)" "0.001" "0.0001"
check_near "input 2 sd" "$(value "$out" in2.sd_v)" "0.002" "0.0002"
check_near "input 1 window" "$(value "$out" in1.window_s)" "1.074" "0.01"

events=$(./readmon --events 0)
check "two events in the ring" "$(value "$events" events.n)" "2"
check_near "event 1 duration" "$(echo "$events" | sed -n 's/^event\.1=[^,]*,//p')" "0.003" "0.0015"
check_near "event 2 duration" "$(echo "$events" | sed -n 's/^event\.2=[^,]*,//p')" "0.010" "0.0015"

# The bandwidth request reaches the statistics thread and the settings file
./readmon --set-decimation 4096 > /dev/null
check "invalid decimation refused" "$?" "1"
./readmon --set-decimation 8192 > /dev/null
check "valid decimation accepted" "$?" "0"
sleep 2.5
out=$(./readmon)
check "stats decimation switched" "$(value "$out" monitor.stats_decimation)" "8192"
check "settings file written" "$(cat "$CONF" 2>/dev/null)" "stats_decimation=8192"

# A clean stop: readers see the monitor gone, the block is unlinked
kill -TERM $daemon
wait $daemon
check "daemon exit status" "$?" "0"
./readmon > /dev/null 2>&1
check "readmon exit status after the stop" "$?" "1"
if [ -e /dev/shm/lockbox-monitor ]; then
    echo "FAIL: /dev/shm/lockbox-monitor still exists"
    fail=1
fi

# The saved decimation is read back at the next start
STUB_SCRIPT="10:f:0" ./lockbox-monitor-host --grace-s 0.1 --conf "$CONF" &
daemon=$!
sleep 0.5
out=$(./readmon)
check "decimation restored from the settings file" "$(value "$out" monitor.stats_decimation)" "8192"
kill -TERM $daemon
wait $daemon
rm -f "$CONF"

if [ $fail -ne 0 ]; then
    echo "run_host_test: FAILED"
    exit 1
fi
echo "run_host_test: all checks passed"
