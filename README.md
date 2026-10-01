# rp-lockbox
rp-lockbox is a gateware and software package for the [Red Pitaya STEMlab 125-14](https://www.redpitaya.com/) FPGA boards, turning it
into a feedback controller (lockbox) optimized for optics experiments.

Note that only the versions of the STEMlab 125-14 using the Xilinx Zynq 7010 SoC are currently supported. Use of the STEMlab 125-14 Low Noise is highly recommended over the standard STEMlab 125-14. The FPGA gateware will not run on variants using the Xilinx Zynq 7020 SoC, with some adjustments necessary to the gateware (contact me for details). Red Pitaya 1.04 OS is required (tested with version 1.04-28), 2.00 OS is not supported at this time.

The original project by Fabian Schmid can be found [here](https://github.com/schmidf/rp-lockbox).

## Features
* Multiple-input, multiple-output PID (proportional-integral-derivative) controller
* Second integrator for additional gain at low frequencies
* Web interface for configuration
* Automatic relock (e.g., using the transmission signal of a cavity)
* Remote control via Ethernet using SCPI commands
* Autonomous operation (connection to a PC is only required for configuration)
* Output and reset of lock status on digital pins (allowing cascaded control schemes)

## Installation
Build the software and FPGA configuration from source (see below) or download a binary archive
(`rp-lockbox.tar.gz`) [here](https://github.com/lmaisenbacher/rp-lockbox/releases/latest).

Set up the Red Pitaya following the [official manual](https://redpitaya.readthedocs.io/en/latest/index.html).

Copy the firmware tarball to the Red Pitaya using a [SCP](https://en.wikipedia.org/wiki/Secure_copy)
client:
```
scp rp-lockbox.tar.gz root@<RPHOSTNAME>:/root/
```
where `<RPHOSTNAME>` is the host name (or IP) of the Red Pitaya.

Connect to the Linux system running on the Red Pitaya using [SSH](https://redpitaya.readthedocs.io/en/latest/developerGuide/os/ssh/ssh.html).

(On the Red Pitaya) unpack the tarball and run the install script from a root login shell:
```
sudo -i
tar xf rp-lockbox.tar.gz
cd rp-lockbox
./install.sh
```
The install scripts use the `rw`/`ro` helpers to remount the read-only installation directories,
and those are on root's PATH but not on the one `sudo <script>` hands out; a script started
without them stops before it copies anything.

Then, to stop the default Red Pitaya web server and instead start the lockbox SCPI command server, the lockbox monitor and the web interface, run:
```
systemctl stop redpitaya_nginx
systemctl start lockbox
systemctl start lockbox-monitor
systemctl start lockbox-web-interface
```

If you want to automatically start the SCPI server instead of the web server on system boot, execute
the following commands:
```
systemctl disable redpitaya_nginx
systemctl enable lockbox
systemctl enable lockbox-monitor
systemctl enable lockbox-web-interface
```

The following commands revert to the default configuration:
```
systemctl disable lockbox
systemctl disable lockbox-monitor
systemctl disable lockbox-web-interface
systemctl enable redpitaya_nginx
```

Note that starting `lockbox` loads the FPGA configuration, which resets the lockbox: a running lock
is lost whenever the service (re)starts.

## Usage
The lockbox can be configured using the included web interface which runs on the default HTTP port
(80). Just navigate with your browser to the host name or IP address of the Red Pitaya.

It is also possible to remote control the lockbox by sending SCPI commands via a TCP/IP connection
on port 5000.
See the [official documentation](https://redpitaya.readthedocs.io/en/latest/appsFeatures/remoteControl/remoteControl.html)
for examples how to do this in various programming languages.

The available SCPI commands are documented [here](doc/SCPI_commands.rst).

A Python module and example GUI application for controlling the lockbox can be found in the
[examples/python](examples/python) folder.

### PIDs
The FPGA implements four PID controllers that connect the two inputs of the Red Pitaya with the two
outputs in all possible combinations.

A PID is switched between locking and scanning its output with the signal generator by
`PID:IN<n>:OUT<n>:LOCK ON|OFF` (`rp_PIDSetLock`), and by the button "Toggle Lock/Scan" on the web
page. To scan, the PID is held, its integrators are reset and its output is switched off, all in one
register write, so in the same clock cycle; then the generator is switched on. To lock, the
generator is switched off first, then the same three settings are reversed in one write, and the
PID starts from reset integrators. A PID locks, as `PID:IN<n>:OUT<n>:LOCK?` reports it, while its
output is on and it is neither held nor its integrators reset.

### Lock monitoring and status
Each of the PID controllers monitors the voltage on one of the Red Pitaya auxiliary analog inputs
(which input to use is user-configurable).
If the voltage leaves a user-defined window, the PID is considered unlocked, otherwise it is
considered locked. This lock status is output on digital output pins (see below) and used as input
for the relock feature (see below).
Note that the lock status is always monitored, independent of whether the relock feature is enabled
or not.
The voltage can, e.g., the signal from a photodetector monitoring the transmission of a cavity
to whose resonance a laser is locked (or vice versa).
The lock status can also be queried via SCPI (`PID:IN<n>:OUT<n>:LOCKED?`, see [SCPI commands](doc/SCPI_commands.rst)).

### Lockbox monitor: lock drops and input noise
The lock status above is a register bit, set by the gateware as long as the input is inside the
window.
The `lockbox-monitor` service (`monitor/`) samples the lock and hold bits of all four PID
controllers every millisecond and keeps, per PID, the lock state with its age, the time since the
servo was switched on (i.e., the hold switched off), and the lock drops with their durations,
counted while the servo is on, in total and since it was switched on. A drop ends once the bit has
read locked for 10 ms in a row, so the flicker while the relock feature re-finds the resonance
counts as one drop, not many.

The FPGA counts every change of the lock status from locked to unlocked while the hold is off, at
its own clock (8 ns). The monitor reads that count at every poll, and a rise tells it that the lock
was lost since the previous poll. If both polls read locked, the lock was lost and found again
between them: a short drop, which counts as a drop that began at the previous poll, so its recorded
duration is one poll interval. During an open drop, such a loss restarts the 10 ms that close it.
The web page shows how many of the drops since the servo was switched on were short
("3 (1 < 1 ms)"), and SCPI offers the count (`PID:IN<n>:OUT<n>:UNLock:SHORt?`).

The monitor also measures the ac rms noise of the two fast analog inputs.
Its bandwidth (the scope decimation, 54 kHz by default) is selectable under Options on the web page
and over SCPI.

The web interface shows both per PID, and SCPI offers `PID:IN<n>:OUT<n>:MONitor?`,
`ANALOG:IN<n>:STATs?` and the related commands (see [SCPI commands](doc/SCPI_commands.rst)); while
the service is not running they report the error "Lockbox monitor not running".

### Relock
Each of the PID controllers contains an automatic relock feature. When the feature is enabled and
the lock status is asserted as not locked by the lock monitoring feature, the
internal state of the PID controller is frozen and a triangular voltage sweep with user-defined slew
rate and increasing amplitude is generated on the output. The sweep starts with an amplitude of 256
times the voltage step per clock cycle and doubles it every period up to full scale, for any slew
rate up to 977 kV/s. Once the lock status is asserted as locked, the PID controller is engaged
again.

### Two parameter sets switched by a digital input
Each PID controller holds two parameter sets, "parameter set 1" and "parameter set 2". Each set
has its own setpoint, global gain, KP, KI, KII and KD, and its own lock-monitoring window (min and
max) with a holdoff. A controller uses one set always, or the one the level of its digital input
selects, either way round:

| Set in use                  | Input low | Input high |
| --------------------------- | --------- | ---------- |
| Param. set 1                | 1         | 1          |
| Param. set 2                | 2         | 2          |
| Input high → param. set 2   | 1         | 2          |
| Input high → param. set 1   | 2         | 1          |

The gains switch 72 ns (9 clock cycles) after an edge of the input. This is meant for switching the
power in an optical cavity: the slope of the error signal and the level of the transmission scale
with the power, and each set holds the parameters for one power. Shared by both sets are the relock
settings (enable, slew rate, input), the inversion, the integrator switches and the output limits.

A switch does not make the output jump:
* The global gain enters before the integrators, as the products KG·KP, KG·KI and KG·KD with which
  the error is multiplied. The integrators therefore hold the output value itself and continue from
  it at the new rate. Changing the global gain of the set in use does not make the output jump
  either.
* The D term acts on the change of the input, not of the error, so a new setpoint or a new KD gives
  no derivative kick.
* The P term (KG·KP times the error) changes at once. It is small while the loop is locked; a new
  setpoint moves the error and with it the P term.

To follow a change of the error signal's slope by a factor r, e.g. r times the power in the cavity,
divide the global gain of the set for the higher power by r and leave its other gains as in the
other set.
This scales the whole loop gain, the second integrator included. A global gain of 0 freezes the
output at its value; the output enable switches a controller off.

Each set has its own lock window, because the monitored transmission scales with the power. For
the holdoff time of the set a controller switches into, its lock status cannot go from locked to
unlocked: a transient outside the new window neither counts as a lock drop nor starts the relock
sweep, and the automatic integrator reset is off. An unlocked controller can still lock during the
holdoff. Choose the holdoff longer than the power ramp plus the build-up time of the cavity; the
auxiliary analog inputs update about every 10 µs. The holdoff time is set per set, as "Holdoff
after switch" under Lock monitoring on the web page (0 ms, the default, means no holdoff).

The web page shows under "Last holdoff" what the monitored input did during the holdoff after the
last switch. "Input stayed inside the window": the switch would not have counted as a lock drop
even without the holdoff. "Input went outside the window": the holdoff kept a lock drop from being
counted. If
the lock status then drops as the holdoff ends, the holdoff is too short (or the lock was lost).
Every switch starts the holdoff again, so an input that switches more often than the holdoff lasts
keeps lock-loss detection off altogether.

The FPGA counts, per controller and since it was loaded, the switches of the parameter set, the
holdoffs during which the input went outside the window, and the holdoffs that ended with it outside the
window. The web page shows them in the Parameter set box, and `PID:IN<n>:OUT<n>:COUNTers?` returns
them with the FPGA's unlock count, for loggers to take differences.

Parameter set 2 and the set selection show on the web page when "Show both parameter sets" is
checked under Options (a setting of the browser). A controller that uses anything but parameter set
1 shows them in any case, so the page never hides what is in use.

The digital input is one of DIO5_P, DIO6_P, DIO7_P, DIO0_N, DIO5_N, DIO6_N and DIO7_N on extension
connector E1, chosen per controller. It is synchronized to the FPGA clock, and a new level counts
once it has lasted 4 clock cycles (32 ns), which rejects glitches. These inputs have pull-down
resistors, so an unconnected input reads low.

**The digital inputs take 3.3 V logic (absolute maximum 3.85 V).** A 5 V logic signal needs a
level shifter (e.g. a 74LVC1T45) or a low-resistance divider such as 1 kΩ/2 kΩ: the pull-down
resistor would pull the output of a high-resistance divider below the input threshold.

In SCPI, the parameters of parameter set 2 carry `:PSET2` after the PID (e.g.
`PID:IN1:OUT1:PSET2:KG 0.088`); without a set node, or with `:PSET1`, a command addresses parameter
set 1 as before. `PID:IN<n>:OUT<n>:PSET:MODE PSET1|PSET2|HIGH2|HIGH1` (`HIGH<n>`: input high
selects set n), `PSET:INPut DIO7_P` and `PSET:ACTive?` select and report the set, and
`PSET:COPY PSET1` copies the setpoint, the gains and the lock window of set 1 into set 2 (`PSET2`
the other way round; see [SCPI commands](doc/SCPI_commands.rst)).

### External lock reset
An external digital input can be used to reset each of the PID controllers. If the lock reset is enabled, all output from the controller is suppressed, including the from the relock feature, when the lock reset input is asserted high. In addition, the internal integrator registers are cleared, that is, the integrators are reset. When the lock reset input is asserted low, controller operation proceeds as if the lock had just been engaged. The digital input can be DIO5_P, DIO6_P, DIO7_P or DIO0_N, all of which are located on the GPIO pins of extension connector E1.
These inputs have pull-down resistors, so an unconnected input reads low.
By connecting the lock status output of one of the PID controllers (e.g., PID11) to the lock reset input of another PID controller (e.g., PID22), the controllers can be cascaded: e.g., PID22 is only active when PID11 is asserted locked.

### Input and output configuration
The table below shows the input and output configuration for each of the four PID controllers:

| Name  | (Fast analog) Output  | (Fast analog) Input  | Relock AI  | Lock status DO  | Inverted lock status DO  |
| ------------- | ------------- | ------------- | ------------- | ------------- | ------------- |
| PID11  | 1  | 1  | AIN0-3 (user-selectable)  | DIO1_N  | DIO1_P  |
| PID12  | 1  | 2  | AIN0-3 (user-selectable)  | DIO2_N  | DIO2_P  |
| PID21  | 2  | 1  | AIN0-3 (user-selectable)  | DIO3_N  | DIO3_P  |
| PID22  | 2  | 2  | AIN0-3 (user-selectable)  | DIO4_N  | DIO4_P  |

The lock statuses of the four PID controllers as determined from lock monitoring are output as
digital logic signals for each of the four controllers.
The GPIO pins of extension connector E1 are used.
The output pin "Lock status DO" is high when the lock status is asserted as locked,
and low otherwise. The output pin "Inverted lock status DO" carries the inverted signal of that.

### Output limiting
Global limits can be defined for both outputs of the Red Pitaya. When an output is at its limit, the
integrators of the corresponding PID controllers are frozen in order to avoid integrator windup. If
automatic integrator reset of the PID is enabled, the integrators are reset so that the output sits
at the center of the output limit range.

### Saving and restoring the configuration

The current configuration can be saved to and restored from the SD card of the Red Pitaya through the API, SCPI commands, or the web interface. The configuration is stored in the file `/home/redpitaya/pid_settings.conf` (to change this path, change `CONFIG_FILE_PATH` in [`lockbox.h`](api/include/redpitaya/lockbox.h)).

The file holds both parameter sets and the set selection of every PID controller. A file saved by
rp-lockbox 1.3 or earlier loads too: its parameters become parameter set 1, set 2 is a copy of
them, and every controller uses set 1, so the lock runs as before. Loading such a
file keeps a copy of it as `pid_settings.conf.v2`, which is never overwritten; the earlier software
cannot read the newer file, so to go back to it, copy `pid_settings.conf.v2` over
`pid_settings.conf` first. A save writes a new file and then renames it over the old one, so an
interrupted save leaves the previous file intact.

## How to build
### Architecture
rp-lockbox consists of three core components:

1. The FPGA configuration ("gateware") (`lockbox.bit`). Cannot be build on the Red Pitaya itself and must be build on a desktop PC.
2. An API library (`liblockbox.so`) for reading and modifying the FPGA registers. Can be compiled direclty on the Red Pitaya.
3. The SCPI command server (`lockbox-server`). Can be compiled direclty on the Red Pitaya.
4. The lockbox monitor daemon (`lockbox-monitor`). Can be compiled directly on the Red Pitaya.

### Build requirements
Only Linux is supported as a build environment. Further build requirements for the different
components are:

#### FPGA configuration:

* [Xilinx Vivado](https://www.xilinx.com/products/design-tools/vivado.html) 2017.2 (the free WebPACK
edition is sufficient). The build scripts generated by Vivado are not compatible between versions,
so make sure to install exactly this version.

#### API library and SCPI server:

The easiest way is to compile directly on the Red Pitaya, in which case no additional packages are necessary.

If compiling on another platform:
* The ARMv7 (armhf) cross compiler toolchain (gcc-arm-linux-gnueabihf in Debian)

### Build process

#### FPGA configuration

This process happens on a desktop PC with Xilinx Vivado 2017.2 installed.

Set up required environment variables for Vivado with
```
source <VIVADO_PATH>/settings64.sh
```
where `<VIVDA_PATH>` is the path were Vivado is installed, typically `/opt/Xilinx/Vivado/2017.2` or `/tools/Xilinx/Vivado/2017.2`.

Build the FPGA gateware
```
make -B fpga
```
The bitfile is committed in the repository, so run this only after changing the sources.
The bitfile is written to `fpga/prj/lockbox/out/red_pitaya.bit`.

#### API library, SCPI server and lockbox monitor

This process happens either on the Red Pitaya itself (recommended) or on another platform with the ARMv7 cross compiler toolchain present.

Check out the scpi-parser submodule:
```
git submodule update --init
```

Build the API library, the SCPI server and the lockbox monitor
```
make api
make scpi
make monitor
```
These are incremental: a changed source rebuilds its object, and a changed `VERSION` or commit
rebuilds the object that reports them, so a build always says what it is (`*IDN?`, and Options >
Software on the web page).

The lockbox monitor's lock-drop bookkeeping and its shared block have tests that run on any Linux host
with gcc (no Red Pitaya needed): `make monitor-test` builds the daemon against a stand-in for the API
library, feeds it a scripted sequence of lock flags and reads the result back through the library's
reader. `monitor/test/readmon` also builds on the Red Pitaya (`make -C monitor/test readmon`) as an
inspection tool for the running monitor.

Host tests also cover the API library's settings file and PID register access, saving and loading
the settings through the whole library against register blocks in memory (`make api-test`), and
the SCPI command table (`make scpi-test`). The gateware's PID module has a self-checking
simulation that compares it with the module before the parameter sets (`tbn/ref/`):
`make -C fpga/sim/red_pitaya_pid_sets` with Icarus Verilog, or with `SIM=xsim` in a Vivado
environment. The relock sweep has one too, `make -C fpga/sim/red_pitaya_relock`: below 1907 V/s
it equals the earlier module cycle by cycle, and above it sweeps the full range at every slew rate
the register holds.

`make clean` leaves the FPGA project alone, since its output directory holds the committed bitfile
and synthesis reports; `make clean-fpga` cleans it, and `git checkout -- fpga/prj/lockbox/out/`
restores what was committed.

To install a build over the running installation and restart the services, run `scripts/update.sh`
from a root login shell, like the install script above:
```
sudo -i
cd rp-lockbox
scripts/update.sh
```
where `cd rp-lockbox` assumes the checkout sits where the installation above put it; use its path
otherwise. The script states what the run will do and waits for a confirmation. The lock lives in
the gateware, so when the bitfile in the tree is the one already installed the software is
restarted without reprogramming the FPGA and the lock is kept; a different bitfile is installed and
loaded, which drops the lock (`--reload-fpga` forces that). The SCPI server restores the saved
`pid_settings.conf` at its start, so save the parameters first (web page, or
`LOCKbox:CONFig:SAVE`) if they changed since the last save.

#### Make compressed archive

Finally, the built components can be assembled in a compressed archive for release.

If the API library and SCPI have been built on the Red Pitaya, the generated FPGA gateware must first be copied to the Red Pitaya itself (e.g., using SCP: `scp fpga/prj/lockbox/out/red_pitaya.bit root@$RPHOSTNAME:/root/rp-lockbox/fpga/prj/lockbox/out/red_pitaya.bit`).

Next, run
```
make install
make tarball
```
to copy the generated files to the `build` subdirectory and generate a compressed archive.

### Versioning and releases

The release version lives in the file `VERSION` at the top of the repository. The top-level `make` passes it, together with the git revision of the checkout, into the API library and the SCPI server, and the server reports both in `*IDN?` (e.g., `REDPITAYA,rp-lockbox,rp-f0ac0b,1.2.1 (77505ed)`), so a running lockbox always tells which version it runs. The web interface shows the same string under Options > Software.

To release: bump `VERSION` (major for incompatible SCPI or configuration changes, minor for new commands or features, patch for fixes), commit, tag the commit with the version (`git tag 1.2.1`, `git push --tags`), build the archive as described above, and attach it to a GitHub release of that tag; the [installation instructions](#installation) point at the latest release.
