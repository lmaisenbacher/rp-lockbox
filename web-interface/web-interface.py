#!/usr/bin/env python3
#
# Copyright (c) 2019, Malte Bieringer, Fabian Schmid
# Copyright (c) 2023, Lothar Maisenbacher
#
# All rights reserved.
"""Server-side module for the Red Pitaya lockbox web interface. Uses the bottle micro
web-framework."""
import os
import ctypes
import sys
import json
import logging
import math
from bottle import route, run, request, static_file

logging.basicConfig()
LOG = logging.getLogger(__name__)

BASEDIR = os.path.dirname(__file__)

# Error codes returned by the API (lockbox.h)
ERROR_CODES = {
    1: "RP_EOED. Failed to open EEPROM device.",
    2: "RP_EOMD. Failed to open memory device.",
    3: "RP_ECMD. Failed to close memory device.",
    4: "RP_EMMD. Failed to map memory device.",
    5: "RP_EUMD. Failed to unmap memory device.",
    6: "RP_EOOR. Value out of range.",
    7: "RP_ELID. LED input direction is not valid.",
    8: "RP_EMRO. Modifying read only field is not allowed.",
    9: "RP_EWIP. Writing to input pin is not valid.",
    10: "RP_EPN. Invalid pin number.",
    11: "RP_UIA. Uninitialized input argument.",
    12: "RP_FCA. Failed to find calibration parameters.",
    13: "RP_RCA. Failed to read calibration parameters.",
    14: "RP_BTS. Buffer too small.",
    15: "RP_EIPV. Invalid parameter value.",
    16: "RP_EUF. Unsupported feature.",
    17: "RP_ENN. Data not normalized.",
    18: "RP_EFOB. Failed to open bus.",
    19: "RP_EFCB. Failed to close bus.",
    20: "RP_EABA. Failed to acquire bus access.",
    21: "RP_EFRB. Failed to read from the bus.",
    22: "RP_EFWB. Failed to write to the bus.",
    23: "RP_EMNC. Extension module not connected.",
    24: "RP_EOCF. Failed to open config file.",
    25: "RP_EICV. Incompatible config file version.",
    26: "RP_EMON. Lockbox monitor not running."}

#: Error code of a lockbox monitor that is not running (its readouts are
#: shown as such, not logged as errors)
RP_EMON = 26

#: Error code of the parameter set functions on an FPGA image without the
#: parameter sets
RP_EUF = 16

#: The parameters of a parameter set (`rp_pidparam_t`), with the factor from
#: the unit the page shows to the library's
PSET_PARAMS = {
    "setpoint": (0, 1.0),
    "kp": (1, 1.0),
    "ki": (2, 1.0),
    "kii": (3, 1.0),
    "kd": (4, 1e-9),         # ns
    "kg": (5, 1.0),
    "relock_min": (6, 1.0),
    "relock_max": (7, 1.0),
    "holdoff": (8, 1e-3)}    # ms

#: The parameter sets (`rp_pidset_t`) and the suffix of their keys
PSET_SUFFIX = {0: "", 1: "_set2"}

#: The pins that can select the parameter set (`rp_dpin_t` values)
PSET_INPUTS = {13: "DIO5_P", 14: "DIO6_P", 15: "DIO7_P", 16: "DIO0_N",
              21: "DIO5_N", 22: "DIO6_N", 23: "DIO7_N"}


def error_text(code):
    """The name and description of an API error code."""
    return ERROR_CODES.get(code, "unknown error %s" % code)

#: The scope decimations the lockbox monitor's input statistics accept, with
#: the bandwidth (-3 dB of the averaging) each gives
STATS_DECIMATIONS = {64: "850 kHz", 1024: "54 kHz", 8192: "6.7 kHz", 65536: "0.85 kHz"}

PID_ID = {
    "PID_11": 0, # Input 1 -> Output 1
    "PID_12": 1, # Input 2 -> Output 1
    "PID_21": 2, # Input 1 -> Output 2
    "PID_22": 3} # Input 2 -> Output 2

AIN_ID = {
    0: "AIN0",
    1: "AIN1",
    2: "AIN2",
    3: "AIN3"}

def init_rp_library():
    """Initialize the Red Pitaya lockbox library. Exit the program on failure.

    The web interface joins the lockbox the SCPI server set up, so it
    attaches to the registers without resetting anything (`rp_Init` would
    put the signal generators, the digital pins and the scope back to
    their defaults)."""
    RP_LIB.rp_GetVersion.restype = ctypes.c_char_p
    retval = RP_LIB.rp_Attach()
    if retval != 0:
        LOG.error("Failed to initialize lockbox library. Error code: %s", ERROR_CODES[retval])
        sys.exit(-1)


def software_version():
    """The lockbox software's release version and the git revision it was
    built from, "1.3.0 (58411ac)": the same string `*IDN?` reports, read
    from the library this page and the SCPI server share. It cannot
    change while the process runs, so it is read once."""
    try:
        version = RP_LIB.rp_GetVersion()
    except Exception as err:                # a library without the symbol
        LOG.error("Failed to read the software version. Error: %s", err)
        return "unknown"
    if isinstance(version, bytes):
        version = version.decode("ascii", "replace")
    return str(version)


class PIDCounters(ctypes.Structure):
    """`rp_pid_counters_t` of lockbox.h: one PID's event counters in the FPGA."""
    _fields_ = [
        ("switches", ctypes.c_uint32),
        ("holdoffs_went_outside", ctypes.c_uint32),
        ("holdoffs_ended_outside", ctypes.c_uint32),
        ("unlocks", ctypes.c_uint32),
    ]


class PIDMonitor(ctypes.Structure):
    """`rp_pid_monitor_t` of lockbox.h: one PID's lock monitoring."""
    _fields_ = [
        ("locked", ctypes.c_bool),
        ("lock_age_s", ctypes.c_double),
        ("servo_on", ctypes.c_bool),
        ("servo_age_s", ctypes.c_double),
        ("unlocks_total", ctypes.c_uint64),
        ("unlocked_total_s", ctypes.c_double),
        ("unlocks_since_servo", ctypes.c_uint64),
        ("unlocked_since_servo_s", ctypes.c_double),
        ("longest_since_servo_s", ctypes.c_double),
        ("drop_open", ctypes.c_bool),
        ("last_unlock_age_s", ctypes.c_double),
        ("last_unlock_s", ctypes.c_double),
        ("raw_unlock_edges", ctypes.c_uint64),
        ("short_counted", ctypes.c_bool),
        ("short_total", ctypes.c_uint64),
        ("short_since_servo", ctypes.c_uint64),
    ]


def pid_monitor(pid):
    """The lockbox monitor's view of PID `pid` (0-3) as a dict, or None while
    the monitor is not running."""
    monitor = PIDMonitor()
    retval = RP_LIB.rp_PIDGetMonitor(pid, ctypes.byref(monitor))
    if retval == RP_EMON:
        return None
    if retval != 0:
        LOG.error("Failed to get the lock monitoring of PID. Error code: %s", ERROR_CODES[retval])
        return None
    return {
        "locked": monitor.locked,
        "lock_age_s": monitor.lock_age_s,
        "servo_on": monitor.servo_on,
        "servo_age_s": monitor.servo_age_s,
        "unlocks_total": monitor.unlocks_total,
        "unlocked_total_s": monitor.unlocked_total_s,
        "drops": monitor.unlocks_since_servo,
        # Of them, the ones shorter than a poll of the monitor (None while
        # the FPGA image does not count drops)
        "short_drops": monitor.short_since_servo if monitor.short_counted else None,
        "unlocked_s": monitor.unlocked_since_servo_s,
        "longest_s": monitor.longest_since_servo_s,
        "drop_open": monitor.drop_open,
        "last_unlock_age_s": monitor.last_unlock_age_s,
        "last_unlock_s": monitor.last_unlock_s,
    }


def monitor_health():
    """The lockbox monitor's health as a dict; `alive` False while it is not running."""
    alive = ctypes.c_bool()
    uptime_s = ctypes.c_double()
    period_ms = ctypes.c_double()
    max_gap_ms = ctypes.c_double()
    late_polls = ctypes.c_uint64()
    merge_ms = ctypes.c_double()
    retval = RP_LIB.rp_MonitorGetHealth(
        ctypes.byref(alive), ctypes.byref(uptime_s), ctypes.byref(period_ms),
        ctypes.byref(max_gap_ms), ctypes.byref(late_polls), ctypes.byref(merge_ms))
    if retval not in (0, RP_EMON):
        LOG.error("Failed to get the lockbox monitor's health. Error code: %s", ERROR_CODES[retval])
    return {
        "alive": alive.value,
        "uptime_s": uptime_s.value,
        "period_ms": period_ms.value,
        "max_gap_ms": max_gap_ms.value,
        "late_polls": late_polls.value,
        "merge_ms": merge_ms.value,
    }


def input_stats(channel):
    """The lockbox monitor's noise statistics of fast input `channel` (0 or 1)
    as a dict, or None while the monitor is not running."""
    mean = ctypes.c_double()
    sd = ctypes.c_double()
    minimum = ctypes.c_double()
    maximum = ctypes.c_double()
    window_s = ctypes.c_double()
    age_s = ctypes.c_double()
    decimation = ctypes.c_uint32()
    retval = RP_LIB.rp_GetInStats(
        channel, ctypes.byref(mean), ctypes.byref(sd), ctypes.byref(minimum),
        ctypes.byref(maximum), ctypes.byref(window_s), ctypes.byref(age_s),
        ctypes.byref(decimation))
    if retval == RP_EMON:
        return None
    if retval != 0:
        LOG.error("Failed to get the input statistics. Error code: %s", ERROR_CODES[retval])
        return None
    return {
        "mean_v": mean.value,
        "sd_v": sd.value,
        "min_v": minimum.value,
        "max_v": maximum.value,
        "window_s": window_s.value,
        "age_s": age_s.value,
        "decimation": decimation.value,
        "bandwidth": STATS_DECIMATIONS.get(decimation.value, ""),
    }


def has_param_sets():
    """Whether the FPGA image has the two parameter sets."""
    available = ctypes.c_bool()
    RP_LIB.rp_PIDHasParamSets(ctypes.byref(available))
    return available.value


def get_pset_param(pid, pset, name):
    """Parameter `name` (see `PSET_PARAMS`) of parameter set `pset` of PID
    `pid`, in the unit the page shows, or None if the FPGA image lacks it."""
    param, scale = PSET_PARAMS[name]
    value = ctypes.c_float()
    retval = RP_LIB.rp_PIDGetParam(pid, pset, param, ctypes.byref(value))
    if retval == RP_EUF:
        return None
    if retval != 0:
        LOG.error("Failed to get %s of PID %d, set %d. Error code: %s",
                  name, pid, pset, error_text(retval))
        return None
    return value.value / scale


def set_pset_param(name):
    """Handle a POST request that sets parameter `name` (see `PSET_PARAMS`).

    Accepted POST parameters:
    :pid: the PID to adjust
    :set: the parameter set: 0 = param. set 1 (the default), 1 = param. set 2
    :<name>: the value to set, in the unit the page shows
    """
    value = request.params.get(name, 0, type=float)
    pid = request.params.get("pid", 1, type=int)
    pset = request.params.get("set", 0, type=int)
    param, scale = PSET_PARAMS[name]
    retval = RP_LIB.rp_PIDSetParam(pid, pset, param, ctypes.c_float(scale * value))
    if retval != 0:
        LOG.error("Failed to set %s of PID %d, set %d. Error code: %s",
                  name, pid, pset, error_text(retval))
    LOG.info("PID %d set %d %s: %f", pid, pset, name, value)


def pset_state(pid):
    """The parameter set in use by PID `pid` as a dict, or None if the FPGA
    image lacks the parameter sets."""
    active = ctypes.c_int()
    holdoff = ctypes.c_bool()
    level = ctypes.c_bool()
    violated = ctypes.c_bool()
    retval = RP_LIB.rp_PIDGetParamSetState(
        pid, ctypes.byref(active), ctypes.byref(holdoff), ctypes.byref(level),
        ctypes.byref(violated))
    if retval == RP_EUF:
        return None
    if retval != 0:
        LOG.error("Failed to get the parameter set state of PID %d. Error code: %s",
                  pid, error_text(retval))
        return None
    state = {
        "active": active.value,
        "holdoff": holdoff.value,
        "level": level.value,
        "violated": violated.value,
        "counters": None,
    }
    counters = PIDCounters()
    retval = RP_LIB.rp_PIDGetCounters(pid, ctypes.byref(counters))
    if retval == 0:
        state["counters"] = {
            "switches": counters.switches,
            "holdoffs_went_outside": counters.holdoffs_went_outside,
            "holdoffs_ended_outside": counters.holdoffs_ended_outside,
        }
    elif retval != RP_EUF:
        LOG.error("Failed to get the counters of PID %d. Error code: %s", pid, error_text(retval))
    return state

@route('/')
def index():
    """Main HTML file."""
    return static_file("index.html", root=BASEDIR)

@route('/jquery-ui.css')
def jquery_ui_css():
    """jQuery UI style file."""
    return static_file("jquery-ui.css", root=os.path.join(BASEDIR, "css"))

@route('/jquery-ui.js')
def jquery_ui_js():
    """jQuery UI library."""
    return static_file("jquery-ui.js", root=os.path.join(BASEDIR, "js"))

@route('/external/jquery/jquery.js')
def jquery_js():
    """jQuery library."""
    return static_file("external/jquery/jquery.js", root=os.path.join(BASEDIR))

@route('/images/<name>')
def images(name):
    """Image files used by jQuery UI."""
    return static_file(name, root=os.path.join(BASEDIR, "images"))

@route('/favicon.svg')
@route('/favicon.ico')
def favicon():
    """The tab icon: the letters RPL on a colored square, in the style of
    the lab's pydase servers (served at /favicon.ico too, for browsers that
    ask there without a link tag)."""
    return static_file("favicon.svg", root=BASEDIR, mimetype="image/svg+xml")

@route("/_set_setpoint", method="POST")
def set_setpoint():
    """Handle POST request for setting the PID setpoint (V), see `set_pset_param`."""
    set_pset_param("setpoint")

@route("/_set_kp", method="POST")
def set_kp():
    """Handle POST request for setting the PID Kp (P gain), see `set_pset_param`."""
    set_pset_param("kp")

@route("/_set_ki", method="POST")
def set_ki():
    """Handle POST request for setting the PID Ki (integrator gain (1/s)), see
    `set_pset_param`."""
    set_pset_param("ki")

@route("/_set_kd", method="POST")
def set_kd():
    """Handle POST request for setting the PID Kd (derivative gain (ns)), see
    `set_pset_param`."""
    set_pset_param("kd")

@route("/_set_kii", method="POST")
def set_kii():
    """Handle POST request for setting the PID Kii (2nd integrator gain (1/s)), see
    `set_pset_param`."""
    set_pset_param("kii")

@route("/_set_kg", method="POST")
def set_kg():
    """Handle POST request for setting the PID Kg (global gain), see `set_pset_param`."""
    set_pset_param("kg")

@route("/_set_holdoff", method="POST")
def set_holdoff():
    """Handle POST request for setting the holdoff after a switch into a parameter
    set (ms), see `set_pset_param`."""
    set_pset_param("holdoff")

@route("/_set_pset_mode", method="POST")
def set_pset_mode():
    """Handle POST request for setting which parameter set a PID uses.

    Accepted POST parameters:
    :pid: the PID to adjust
    :mode: 0 = param. set 1, 1 = param. set 2, 2 = the digital input selects (high: set 2),
           3 = the digital input selects (high: set 1)
    """
    mode = request.params.get("mode", 0, type=int)
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetParamSetMode(pid, ctypes.c_int(mode))
    if retval != 0:
        LOG.error("Failed to set the parameter set mode of PID %d. Error code: %s",
                  pid, error_text(retval))

@route("/_set_pset_input", method="POST")
def set_pset_input():
    """Handle POST request for setting the digital input that selects the parameter set.

    Accepted POST parameters:
    :pid: the PID to adjust
    :din: the digital input (see `PSET_INPUTS`)
    """
    din = request.params.get("din", 0, type=int)
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetParamSetInput(pid, ctypes.c_int(din))
    if retval != 0:
        LOG.error("Failed to set the digital input of PID %d. Error code: %s", pid,
                  error_text(retval))

@route("/_copy_params", method="POST")
def copy_params():
    """Handle POST request for copying one parameter set of a PID into its other set.

    Accepted POST parameters:
    :pid: the PID to adjust
    :from: the set to copy: 0 = param. set 1 (into set 2), 1 = param. set 2 (into set 1)
    """
    pid = request.params.get("pid", 1, type=int)
    pset = request.params.get("from", 0, type=int)
    retval = RP_LIB.rp_PIDCopyParams(pid, pset, 1 - pset)
    if retval != 0:
        LOG.error("Failed to copy parameter set %d of PID %d. Error code: %s",
                  pset + 1, pid, error_text(retval))

@route("/_set_inverted", method="POST")
def set_inverted():
    """Handle POST request for setting the PID feedback sign.

    Accepted POST parameters:
    :pid: the PID to adjust
    :inverted: true for a negative gain sign, false for a positive gain sign
    """
    inverted = request.params.get("inverted", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetInverted(pid, inverted)
    if retval != 0:
        LOG.error("Failed to set PID feedback sign. Error code: %s", ERROR_CODES[retval])

@route("/_set_hold", method="POST")
def set_hold():
    """Handle POST request for setting to hold internal state.

    Accepted POST parameters:
    :pid: the PID to adjust
    :hold: true if internal state should be held, false if not
    """
    hold = request.params.get("hold", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetHold(pid, hold)
    if retval != 0:
        LOG.error("Failed to set PID internal state holding. Error code: %s", ERROR_CODES[retval])

@route("/_set_int_reset", method="POST")
def set_int_reset():
    """Handle POST request for resetting the integrator.

    Accepted POST parameters:
    :pid: the PID to adjust
    :int_reset: true if internal state should be reset, false if not
    """
    int_reset = request.params.get("int_reset", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetIntReset(pid, int_reset)
    if retval != 0:
        LOG.error("Failed to set PID integrator reset. Error code: %s", ERROR_CODES[retval])

@route("/_set_int_auto", method="POST")
def set_int_auto():
    """Handle POST request for resetting the integrator automatically.

    Accepted POST parameters:
    :pid: the PID to adjust
    :int_reset: If true, the integrator register is reset when the PID output hits the configured
                limit
    """
    int_auto = request.params.get("int_auto", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetResetWhenRailed(pid, int_auto)
    if retval != 0:
        LOG.error("Failed to set PID automatical integrator reset. Error code: %s",
                  ERROR_CODES[retval])

@route("/_set_pid_enabled", method="POST")
def set_pid_enabled():
    """Handle POST request for enabling the PID output.

    Accepted POST parameters:
    :pid: the PID to adjust
    :pid_enabled: If true, the PID output is enabled.
    """
    pid_enabled = request.params.get("pid_enabled", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetEnable(pid, pid_enabled)
    if retval != 0:
        LOG.error("Failed to set PID enabled. Error code: %s", ERROR_CODES[retval])

@route("/_set_lock", method="POST")
def set_lock():
    """Handle POST request for switching a PID between lock and scan (`rp_PIDSetLock`).

    Accepted POST parameters:
    :pid: the PID to switch
    :lock: true to lock, false to scan with the signal generator of the PID's output
    """
    lock = request.params.get("lock", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetLock(pid, lock)
    if retval != 0:
        LOG.error("Failed to switch PID %d to %s. Error code: %s",
                  pid, "lock" if lock else "scan", error_text(retval))

@route("/_set_relock_min", method="POST")
def set_relock_min():
    """Handle POST request for setting the minimum input voltage for which the PID is considered
    locked, see `set_pset_param`."""
    set_pset_param("relock_min")

@route("/_set_relock_max", method="POST")
def set_relock_max():
    """Handle POST request for setting the maximum input voltage for which the PID is considered
    locked, see `set_pset_param`."""
    set_pset_param("relock_max")

@route("/_set_relock_slew_rate", method="POST")
def set_relock_slew_rate():
    """Handle POST request for setting slew rate of the relock in V/s.

    Accepted POST parameters:
    :pid: the PID to adjust
    :relock_slew_rate: the value to set
    """
    relock_slew_rate = request.params.get("relock_slew_rate", 0, type=float)
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetRelockStepsize(pid, ctypes.c_float(relock_slew_rate))
    if retval != 0:
        LOG.error("Failed to set PID relock slew rate. Error code: %s", ERROR_CODES[retval])
    LOG.info("Relock slew rate: %f", relock_slew_rate)
    LOG.info("PID: %d", pid)

@route("/_set_relock_enabled", method="POST")
def set_relock_enabled():
    """Handle POST request for enabling the relock group.

    Accepted POST parameters:
    :pid: the PID to adjust
    :relock_enabled: If true, the PID relock feature is enabled.
    """
    relock_enabled = request.params.get("relock_enabled", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetRelock(pid, relock_enabled)
    if retval != 0:
        LOG.error("Failed to set PID relock enabled. Error code: %s", ERROR_CODES[retval])

@route("/_set_relock_input", method="POST")
def set_relock_input():
    """Handle POST request for setting the analog input to be used for relocking the PID.

    Accepted POST parameters:
    :pid: the PID to adjust
    :ain: number of the analog input to be used for relocking the PID.
    """
    ain = request.params.get("ain", 0, type=int)
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetRelockInput(pid, ctypes.c_int(ain))
    if retval != 0:
        LOG.error("Failed to select analog input to be used for relocking the PID. Error code: %s",
                  ERROR_CODES[retval])

@route("/_set_lso_enabled", method="POST")
def set_lso_enabled():
    """Handle POST request for enabling the PID lock status output.

    Accepted POST parameters:
    :pid: the PID to adjust
    :enabled: If true, the PID lock status output is enabled.
    """
    enabled = request.params.get("enabled", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetLockStatusOutputEnable(pid, enabled)
    if retval != 0:
        LOG.error("Failed to set PID lock status output enabled. Error code: %s", ERROR_CODES[retval])

@route("/_set_ext_reset_enabled", method="POST")
def set_ext_reset_enabled():
    """Handle POST request for enabling the PID external reset.

    Accepted POST parameters:
    :pid: the PID to adjust
    :enabled: If true, the PID external reset is enabled.
    """
    enabled = request.params.get("enabled", 0) == "true"
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetExtResetEnable(pid, enabled)
    if retval != 0:
        LOG.error("Failed to set PID external reset enabled. Error code: %s", ERROR_CODES[retval])

@route("/_set_ext_reset_input", method="POST")
def set_ext_reset_input():
    """Handle POST request for setting the digital input to be used for resetting the PID.

    Accepted POST parameters:
    :pid: the PID to adjust
    :din: number of the digital input to be used for resetting the PID.
    """
    din = request.params.get("din", 0, type=int)
    pid = request.params.get("pid", 1, type=int)
    retval = RP_LIB.rp_PIDSetExtResetInput(pid, ctypes.c_int(din))
    if retval != 0:
        LOG.error("Failed to select digital input to be used for resetting the PID. Error code: %s",
                  ERROR_CODES[retval])

@route("/_set_limit_min", method="POST")
def set_limit_min():
    """Handle POST request for setting minimum output value.

    Accepted POST parameters:
    :output: the output channel to adjust
    :limit_min: the value to set.
    """
    limit_min = request.params.get("limit_min", 0, type=float)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_LimitMin(output, ctypes.c_float(limit_min))
    if retval != 0:
        LOG.error("Failed to set minimum output voltage. Error code: %s", ERROR_CODES[retval])

@route("/_set_limit_max", method="POST")
def set_limit_max():
    """Handle POST request for setting maximum output value.

    Accepted POST parameters:
    :output: the output channel to adjust
    :limit_max: the value to set.
    """
    limit_max = request.params.get("limit_max", 0, type=float)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_LimitMax(output, ctypes.c_float(limit_max))
    if retval != 0:
        LOG.error("Failed to set maximum output voltage. Error code: %s", ERROR_CODES[retval])

@route("/_set_waveform", method="POST")
def set_waveform():
    """Handle POST request for setting waveform of the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :waveform: number of the selected waveform. (0:SIN, 1:SQUARE, 2:TRIANGLE, 3:SAWU, 4:SAWD)
    """
    waveform = request.params.get("waveform", 0, type=int)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_GenWaveform(output, ctypes.c_int(waveform))
    if retval != 0:
        LOG.error("Failed to set waveform of the signal generator. Error code: %s",
                  ERROR_CODES[retval])

@route("/_set_sg_amp", method="POST")
def set_sg_amp():
    """Handle POST request for setting amplitude of the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :amp: the value to set.
    """
    amp = request.params.get("amp", 0, type=float)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_GenAmp(output, ctypes.c_float(amp))
    if retval != 0:
        LOG.error("Failed to set signal generator amplitude. Error code: %s", ERROR_CODES[retval])

@route("/_set_sg_freq", method="POST")
def set_sg_freq():
    """Handle POST request for setting frequency of the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :freq: the value to set.
    """
    freq = request.params.get("freq", 0, type=float)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_GenFreq(output, ctypes.c_float(freq))
    if retval != 0:
        LOG.error("Failed to set signal generator frequency. Error code: %s", ERROR_CODES[retval])

@route("/_set_sg_offset", method="POST")
def set_sg_offset():
    """Handle POST request for setting offset of the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :offset: the value to set.
    """
    offset = request.params.get("offset", 0, type=float)
    output = request.params.get("output", 1, type=int)
    retval = RP_LIB.rp_GenOffset(output, ctypes.c_float(offset))
    if retval != 0:
        LOG.error("Failed to set signal generator offset. Error code: %s", ERROR_CODES[retval])

@route("/_set_sg_enabled", method="POST")
def set_sg_enabled():
    """Handle POST request for enabling the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :sg_enabled: true if signal generator enabled, false if not
    """
    sg_enabled = request.params.get("sg_enabled", 0) == "true"
    output = request.params.get("output", 1, type=int)
    if sg_enabled:
        retval = RP_LIB.rp_GenOutEnable(output)
        if retval != 0:
            LOG.error("Failed to enable signal generator. Error code: %s", ERROR_CODES[retval])
    else:
        retval = RP_LIB.rp_GenOutDisable(output)
        if retval != 0:
            LOG.error("Failed to disable signal generator. Error code: %s", ERROR_CODES[retval])

@route("/_set_sg_poffset_enabled", method="POST")
def set_sg_poffset_enabled():
    """Handle POST request for enabling permanent offset of the signal generator.

    Accepted POST parameters:
    :output: the output channel to adjust
    :offset_enabled: true if permanent offset of signal generator enabled, false if not
    """
    offset_enabled = request.params.get("offset_enabled", 0) == "true"
    output = request.params.get("output", 1, type=int)
    if offset_enabled:
        retval = RP_LIB.rp_GenPOffsetEnable(output)
        if retval != 0:
            LOG.error("Failed to enable permanent offset of signal generator. Error code: %s", ERROR_CODES[retval])
    else:
        retval = RP_LIB.rp_GenPOffsetDisable(output)
        if retval != 0:
            LOG.error("Failed to disable permanent offset of signal generator. Error code: %s", ERROR_CODES[retval])

@route("/_save_parameters", method="POST")
def save_parameters():
    """Handle POST request for saving parameters to SD card."""

    retval = RP_LIB.rp_SaveLockboxConfig()
    if retval != 0:
        LOG.error("Failed to save parameters. Error code: %s", ERROR_CODES[retval])

@route("/_load_parameters", method="POST")
def load_parameters():
    """Handle POST request for loading parameters to SD card."""

    retval = RP_LIB.rp_LoadLockboxConfig()
    if retval != 0:
        LOG.error("Failed to load parameters. Error code: %s", ERROR_CODES[retval])

@route("/_get_values")
def get_values():
    ain_voltage = [0., 0., 0., 0.]
    for i in range(4, 8):
        ain_voltage[i-4] = ctypes.c_float()
        retval = RP_LIB.rp_ApinGetValue(i, ctypes.byref(ain_voltage[i-4]))
        if retval != 0:
            LOG.error("Failed to get analog input voltage. Error code: %s", ERROR_CODES[retval])

    fast_input_voltage = [0., 0.]
    for i in range(2):
        fast_input_voltage[i] = ctypes.c_float()
        retval = RP_LIB.rp_GetInVoltage(i, ctypes.byref(fast_input_voltage[i]))
        if retval != 0:
            LOG.error("Failed to get fast input voltage. Error code: %s", ERROR_CODES[retval])

    fast_output_voltage = [0., 0.]
    for i in range(2):
        fast_output_voltage[i] = ctypes.c_float()
        retval = RP_LIB.rp_GetOutVoltage(i, ctypes.byref(fast_output_voltage[i]))
        if retval != 0:
            LOG.error("Failed to get fast output voltage. Error code: %s", ERROR_CODES[retval])

    lock_status = [False, False, False, False]
    for i in range(4):
        lock_status[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetLockStatus(i, ctypes.byref(lock_status[i]))
        if retval != 0:
            LOG.error("Failed to get lock status of PID. Error code: %s",
                      ERROR_CODES[retval])

    # The lockbox monitor service's counters (None per entry while it is not running)
    health = monitor_health()
    alive = health["alive"]

    ain_voltage_values = {
        "ain0_voltage": ain_voltage[0].value,
        "ain1_voltage": ain_voltage[1].value,
        "ain2_voltage": ain_voltage[2].value,
        "ain3_voltage": ain_voltage[3].value,
        "in_1_voltage": fast_input_voltage[0].value,
        "in_2_voltage": fast_input_voltage[1].value,
        "out_1_voltage": fast_output_voltage[0].value,
        "out_2_voltage": fast_output_voltage[1].value,
        "pid_11_lock_status": lock_status[0].value,
        "pid_12_lock_status": lock_status[1].value,
        "pid_21_lock_status": lock_status[2].value,
        "pid_22_lock_status": lock_status[3].value,
        # The parameter set in use (None without the parameter sets)
        "pid_11_pset": pset_state(0),
        "pid_12_pset": pset_state(1),
        "pid_21_pset": pset_state(2),
        "pid_22_pset": pset_state(3),
        "monitor": health,
        "pid_11_monitor": pid_monitor(0) if alive else None,
        "pid_12_monitor": pid_monitor(1) if alive else None,
        "pid_21_monitor": pid_monitor(2) if alive else None,
        "pid_22_monitor": pid_monitor(3) if alive else None,
        "in_1_stats": input_stats(0) if alive else None,
        "in_2_stats": input_stats(1) if alive else None,
    }
    return json.dumps(ain_voltage_values)


@route("/_set_stats_decimation", method="POST")
def set_stats_decimation():
    """Handle POST request for the scope decimation (bandwidth) of the lock
    monitor's input noise statistics."""
    decimation = int(request.forms.get("decimation"))
    LOG.debug("stats decimation: %d", decimation)

    retval = RP_LIB.rp_MonitorSetStatsDecimation(ctypes.c_uint32(decimation))
    if retval != 0:
        LOG.error("Failed to set the input statistics decimation. Error code: %s",
                  ERROR_CODES[retval])


@route("/_get_parameters")
def get_parameters():
    """Return a json string containing the current lockbox parameters."""

    # The parameters of both parameter sets: "pid_11_kp" is param. set 1,
    # "pid_11_kp_set2" param. set 2 (None without the parameter sets)
    pset_values = {}
    pset_mode = [0, 0, 0, 0]
    pset_input = [15, 15, 15, 15]
    for i, code in enumerate(("11", "12", "21", "22")):
        for name in PSET_PARAMS:
            for pset, suffix in PSET_SUFFIX.items():
                pset_values["pid_%s_%s%s" % (code, name, suffix)] = get_pset_param(i, pset, name)
        mode = ctypes.c_int()
        retval = RP_LIB.rp_PIDGetParamSetMode(i, ctypes.byref(mode))
        if retval == 0:
            pset_mode[i] = mode.value
        elif retval != RP_EUF:
            LOG.error("Failed to get the parameter set mode of PID. Error code: %s", error_text(retval))
        din = ctypes.c_int()
        retval = RP_LIB.rp_PIDGetParamSetInput(i, ctypes.byref(din))
        if retval == 0:
            pset_input[i] = din.value
        elif retval != RP_EUF:
            LOG.error("Failed to get the digital input of PID. Error code: %s", error_text(retval))

    inverted = [False, False, False, False]
    hold = [False, False, False, False]
    int_reset = [False, False, False, False]
    int_auto = [False, False, False, False]
    enabled = [False, False, False, False]
    relock_slew_rate = [0., 0., 0., 0.]
    relock_enabled = [False, False, False, False]
    relock_input = [0, 0, 0, 0]
    lso_enabled = [False, False, False, False]
    ext_reset_enabled = [False, False, False, False]
    ext_reset_input = [0, 0, 0, 0]
    for i in range(4):
        inverted[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetInverted(i, ctypes.byref(inverted[i]))
        if retval != 0:
            LOG.error("Failed to get PID feedback sign. Error code: %s", ERROR_CODES[retval])

        hold[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetHold(i, ctypes.byref(hold[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID internal holding. Error code: %s",
                      ERROR_CODES[retval])

        int_reset[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetIntReset(i, ctypes.byref(int_reset[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID integrator reset. Error code: %s",
                      ERROR_CODES[retval])

        int_auto[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetResetWhenRailed(i, ctypes.byref(int_auto[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID automatical integrator reset. Error code: %s",
                      ERROR_CODES[retval])

        enabled[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetEnable(i, ctypes.byref(enabled[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID enable. Error code: %s",
                      ERROR_CODES[retval])

        relock_slew_rate[i] = ctypes.c_float()
        retval = RP_LIB.rp_PIDGetRelockStepsize(i, ctypes.byref(relock_slew_rate[i]))
        if retval != 0:
            LOG.error("Failed to get PID relock slew rate. Error code: %s",
                      ERROR_CODES[retval])

        relock_enabled[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetRelock(i, ctypes.byref(relock_enabled[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID relock feature. Error code: %s",
                      ERROR_CODES[retval])

        relock_input[i] = ctypes.c_int()
        retval = RP_LIB.rp_PIDGetRelockInput(i, ctypes.byref(relock_input[i]))
        if retval != 0:
            LOG.error("Failed to get analog input of PID relock. Error code: %s",
                      ERROR_CODES[retval])

        lso_enabled[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetLockStatusOutputEnable(i, ctypes.byref(lso_enabled[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID lock status output enable. Error code: %s",
                      ERROR_CODES[retval])

        ext_reset_enabled[i] = ctypes.c_bool()
        retval = RP_LIB.rp_PIDGetExtResetEnable(i, ctypes.byref(ext_reset_enabled[i]))
        if retval != 0:
            LOG.error("Failed to get state of PID external reset enable. Error code: %s",
                      ERROR_CODES[retval])

        ext_reset_input[i] = ctypes.c_int()
        retval = RP_LIB.rp_PIDGetExtResetInput(i, ctypes.byref(ext_reset_input[i]))
        if retval != 0:
            LOG.error("Failed to get digital input of PID reset. Error code: %s",
                      ERROR_CODES[retval])

    limit_min_1 = ctypes.c_float()
    retval = RP_LIB.rp_LimitGetMin(0, ctypes.byref(limit_min_1))
    if retval != 0:
        LOG.error("Failed to get minimum output limit. Error code: %s", ERROR_CODES[retval])
    limit_min_2 = ctypes.c_float()
    retval = RP_LIB.rp_LimitGetMin(1, ctypes.byref(limit_min_2))
    if retval != 0:
        LOG.error("Failed to get minimum output limit. Error code: %s", ERROR_CODES[retval])

    limit_max_1 = ctypes.c_float()
    retval = RP_LIB.rp_LimitGetMax(0, ctypes.byref(limit_max_1))
    if retval != 0:
        LOG.error("Failed to get maximum output limit. Error code: %s", ERROR_CODES[retval])
    limit_max_2 = ctypes.c_float()
    retval = RP_LIB.rp_LimitGetMax(1, ctypes.byref(limit_max_2))
    if retval != 0:
        LOG.error("Failed to get maximum output limit. Error code: %s", ERROR_CODES[retval])

    sg_1_amp = ctypes.c_float()
    retval = RP_LIB.rp_GenGetAmp(0, ctypes.byref(sg_1_amp))
    if retval != 0:
        LOG.error("Failed to get signal generator amplitude. Error code: %s", ERROR_CODES[retval])
    sg_2_amp = ctypes.c_float()
    retval = RP_LIB.rp_GenGetAmp(1, ctypes.byref(sg_2_amp))
    if retval != 0:
        LOG.error("Failed to get signal generator amplitude. Error code: %s", ERROR_CODES[retval])

    sg_1_freq = ctypes.c_float()
    retval = RP_LIB.rp_GenGetFreq(0, ctypes.byref(sg_1_freq))
    if retval != 0:
        LOG.error("Failed to get signal generator frequency. Error code: %s", ERROR_CODES[retval])
    sg_2_freq = ctypes.c_float()
    retval = RP_LIB.rp_GenGetFreq(1, ctypes.byref(sg_2_freq))
    if retval != 0:
        LOG.error("Failed to get signal generator frequency. Error code: %s", ERROR_CODES[retval])

    sg_1_offset = ctypes.c_float()
    retval = RP_LIB.rp_GenGetOffset(0, ctypes.byref(sg_1_offset))
    if retval != 0:
        LOG.error("Failed to get signal generator offset. Error code: %s", ERROR_CODES[retval])
    sg_2_offset = ctypes.c_float()
    retval = RP_LIB.rp_GenGetOffset(1, ctypes.byref(sg_2_offset))
    if retval != 0:
        LOG.error("Failed to get signal generator offset. Error code: %s", ERROR_CODES[retval])

    sg_1_waveform = ctypes.c_int()
    retval = RP_LIB.rp_GenGetWaveform(0, ctypes.byref(sg_1_waveform))
    if retval != 0:
        LOG.error("Failed to get the waveform of the signal generator. Error code: %s",
                  ERROR_CODES[retval])
    sg_2_waveform = ctypes.c_int()
    retval = RP_LIB.rp_GenGetWaveform(1, ctypes.byref(sg_2_waveform))
    if retval != 0:
        LOG.error("Failed to get the waveform of the signal generator. Error code: %s",
                  ERROR_CODES[retval])

    sg_1_enabled = ctypes.c_bool()
    retval = RP_LIB.rp_GenOutIsEnabled(0, ctypes.byref(sg_1_enabled))
    if retval != 0:
        LOG.error("Failed to get if signal generator is enabled. Error code: %s",
                  ERROR_CODES[retval])
    sg_2_enabled = ctypes.c_bool()
    retval = RP_LIB.rp_GenOutIsEnabled(1, ctypes.byref(sg_2_enabled))
    if retval != 0:
        LOG.error("Failed to get if signal generator is enabled. Error code: %s",
                  ERROR_CODES[retval])

    sg_1_poffset_enabled = ctypes.c_bool()
    retval = RP_LIB.rp_GenPOffsetIsEnabled(0, ctypes.byref(sg_1_poffset_enabled))
    if retval != 0:
        LOG.error("Failed to get if signal generator permanent offset is enabled. Error code: %s",
                  ERROR_CODES[retval])
    sg_2_poffset_enabled = ctypes.c_bool()
    retval = RP_LIB.rp_GenPOffsetIsEnabled(1, ctypes.byref(sg_2_poffset_enabled))
    if retval != 0:
        LOG.error("Failed to get if signal generator permanent offset is enabled. Error code: %s",
                  ERROR_CODES[retval])

    # The lockbox monitor's input statistics decimation: 0 while the monitor
    # is not running or has no window yet
    stats_decimation = ctypes.c_uint32()
    retval = RP_LIB.rp_MonitorGetStatsDecimation(ctypes.byref(stats_decimation))
    if retval not in (0, RP_EMON):
        LOG.error("Failed to get the input statistics decimation. Error code: %s",
                  ERROR_CODES[retval])
    if retval != 0:
        stats_decimation.value = 0

    parameters = {
        "version": VERSION,
        "stats_decimation": stats_decimation.value,
        "param_sets": has_param_sets(),
        "pid_11_pset_mode": pset_mode[0],
        "pid_12_pset_mode": pset_mode[1],
        "pid_21_pset_mode": pset_mode[2],
        "pid_22_pset_mode": pset_mode[3],
        "pid_11_pset_input": pset_input[0],
        "pid_12_pset_input": pset_input[1],
        "pid_21_pset_input": pset_input[2],
        "pid_22_pset_input": pset_input[3],
        "pid_11_inverted": inverted[0].value,
        "pid_12_inverted": inverted[1].value,
        "pid_21_inverted": inverted[2].value,
        "pid_22_inverted": inverted[3].value,
        "pid_11_hold": hold[0].value,
        "pid_12_hold": hold[1].value,
        "pid_21_hold": hold[2].value,
        "pid_22_hold": hold[3].value,
        "pid_11_int_res": int_reset[0].value,
        "pid_12_int_res": int_reset[1].value,
        "pid_21_int_res": int_reset[2].value,
        "pid_22_int_res": int_reset[3].value,
        "pid_11_int_auto_reset": int_auto[0].value,
        "pid_12_int_auto_reset": int_auto[1].value,
        "pid_21_int_auto_reset": int_auto[2].value,
        "pid_22_int_auto_reset": int_auto[3].value,
        "pid_11_enabled": enabled[0].value,
        "pid_12_enabled": enabled[1].value,
        "pid_21_enabled": enabled[2].value,
        "pid_22_enabled": enabled[3].value,
        "pid_11_relock_slew_rate": relock_slew_rate[0].value,
        "pid_12_relock_slew_rate": relock_slew_rate[1].value,
        "pid_21_relock_slew_rate": relock_slew_rate[2].value,
        "pid_22_relock_slew_rate": relock_slew_rate[3].value,
        "pid_11_relock_enabled": relock_enabled[0].value,
        "pid_12_relock_enabled": relock_enabled[1].value,
        "pid_21_relock_enabled": relock_enabled[2].value,
        "pid_22_relock_enabled": relock_enabled[3].value,
        "pid_11_relock_input": relock_input[0].value,
        "pid_12_relock_input": relock_input[1].value,
        "pid_21_relock_input": relock_input[2].value,
        "pid_22_relock_input": relock_input[3].value,
        "pid_11_lso_enabled": lso_enabled[0].value,
        "pid_12_lso_enabled": lso_enabled[1].value,
        "pid_21_lso_enabled": lso_enabled[2].value,
        "pid_22_lso_enabled": lso_enabled[3].value,
        "pid_11_ext_reset_enabled": ext_reset_enabled[0].value,
        "pid_12_ext_reset_enabled": ext_reset_enabled[1].value,
        "pid_21_ext_reset_enabled": ext_reset_enabled[2].value,
        "pid_22_ext_reset_enabled": ext_reset_enabled[3].value,
        "pid_11_ext_reset_input": ext_reset_input[0].value,
        "pid_12_ext_reset_input": ext_reset_input[1].value,
        "pid_21_ext_reset_input": ext_reset_input[2].value,
        "pid_22_ext_reset_input": ext_reset_input[3].value,
        "limit_min_1": limit_min_1.value,
        "limit_min_2": limit_min_2.value,
        "limit_max_1": limit_max_1.value,
        "limit_max_2": limit_max_2.value,
        "sg_1_waveform": sg_1_waveform.value,
        "sg_2_waveform": sg_2_waveform.value,
        "sg_1_enabled": sg_1_enabled.value,
        "sg_2_enabled": sg_2_enabled.value,
        "sg_1_poffset_enabled": sg_1_poffset_enabled.value,
        "sg_2_poffset_enabled": sg_2_poffset_enabled.value,
        "sg_1_amp": sg_1_amp.value,
        "sg_2_amp": sg_2_amp.value,
        "sg_1_freq": sg_1_freq.value,
        "sg_2_freq": sg_2_freq.value,
        "sg_1_offset": sg_1_offset.value,
        "sg_2_offset": sg_2_offset.value
    }
    parameters.update(pset_values)
    return json.dumps(parameters)

def _value(arg):
    """The Python value of an argument the server passes to the library
    (a ctypes number or a plain bool)."""
    return arg.value if hasattr(arg, "value") else arg


class MockRPLib():
    """Class that simulates the Red Pitaya lockbox library, for running the
    page without a Red Pitaya. Setters store their values and getters return
    them, so edits on the page round-trip."""

    #: Values of the parameters of a parameter set, in the order of
    #: `rp_pidparam_t` and the library's units
    PSET_DEFAULTS = [0.0, 0.1, 10.0, 0.0, 1e-9, 1.0, 0.0, 7.0, 0.0]

    def __init__(self):
        self.pset = {(pid, pset): list(self.PSET_DEFAULTS) for pid in range(4) for pset in (0, 1)}
        self.pset[(0, 1)][5] = 0.5
        self.pset_mode = [2, 0, 0, 0]
        self.pset_input = [15, 15, 15, 15]
        self.values = {}
        self.mock_stats_decimation = 1024

    def _set(self, name, index, arg):
        LOG.debug("%s[%d] = %s", name, index, _value(arg))
        self.values[(name, index)] = _value(arg)
        return 0

    def _get(self, name, index, ref, default):
        ref._obj.value = self.values.get((name, index), default)
        return 0

    def rp_Init(self):
        LOG.debug("rp_Init called")
        return 0

    def rp_Attach(self):
        LOG.debug("rp_Attach called")
        return 0

    def rp_GetVersion(self):
        return b"0.00-0000 (mock)"

    def rp_PIDGetLockStatus(self, pid, lock_status):
        lock_status._obj.value = pid != 1
        return 0

    # The lockbox monitor: a running service with fixed numbers

    def rp_MonitorGetHealth(self, alive, uptime_s, period_ms, max_gap_ms, late_polls, merge_ms):
        alive._obj.value = True
        uptime_s._obj.value = 98765.4
        period_ms._obj.value = 1.0
        max_gap_ms._obj.value = 2.3
        late_polls._obj.value = 4
        merge_ms._obj.value = 10.0
        return 0

    def rp_PIDGetMonitor(self, pid, monitor):
        m = monitor._obj
        m.locked = pid != 1
        m.lock_age_s = 4321.0 + 100 * pid
        m.servo_on = pid != 3
        m.servo_age_s = 5000.0 if pid != 3 else -1.0
        m.unlocks_total = 17 + pid
        m.unlocked_total_s = 3.2
        m.unlocks_since_servo = 3 if pid != 3 else 0
        m.unlocked_since_servo_s = 0.9
        m.longest_since_servo_s = 0.4
        m.drop_open = pid == 1
        m.last_unlock_age_s = 4321.0
        m.last_unlock_s = 0.4
        m.raw_unlock_edges = 20 + pid
        m.short_counted = True
        m.short_total = 2
        m.short_since_servo = 1 if pid != 3 else 0
        return 0

    def rp_GetInStats(self, channel, mean, sd, minimum, maximum, window_s, age_s, decimation):
        mean._obj.value = 0.5 if channel == 0 else 0.25
        sd._obj.value = 0.00083 if channel == 0 else 0.0021
        minimum._obj.value = mean._obj.value - 0.004
        maximum._obj.value = mean._obj.value + 0.004
        window_s._obj.value = 1.074
        age_s._obj.value = 0.3
        decimation._obj.value = self.mock_stats_decimation
        return 0

    def rp_MonitorSetStatsDecimation(self, decimation):
        LOG.debug("stats decimation: %d", decimation.value)
        if decimation.value not in STATS_DECIMATIONS:
            return 6
        self.mock_stats_decimation = decimation.value
        return 0

    def rp_MonitorGetStatsDecimation(self, decimation):
        decimation._obj.value = self.mock_stats_decimation
        return 0

    # The parameter sets

    def rp_PIDHasParamSets(self, available):
        available._obj.value = True
        return 0

    def rp_PIDSetParam(self, pid, pset, param, value):
        LOG.debug("pid: %d\t set: %d\t param: %d\t value: %g", pid, pset, param, value.value)
        self.pset[(pid, pset)][param] = value.value
        return 0

    def rp_PIDGetParam(self, pid, pset, param, value):
        value._obj.value = self.pset[(pid, pset)][param]
        return 0

    def rp_PIDCopyParams(self, pid, source, target):
        # all but the holdoff (the last parameter)
        self.pset[(pid, target)][:8] = self.pset[(pid, source)][:8]
        return 0

    def rp_PIDSetParamSetMode(self, pid, mode):
        self.pset_mode[pid] = mode.value
        return 0

    def rp_PIDGetParamSetMode(self, pid, mode):
        mode._obj.value = self.pset_mode[pid]
        return 0

    def rp_PIDSetParamSetInput(self, pid, din):
        if din.value not in PSET_INPUTS:
            return 10
        self.pset_input[pid] = din.value
        return 0

    def rp_PIDGetParamSetInput(self, pid, din):
        din._obj.value = self.pset_input[pid]
        return 0

    def rp_PIDGetParamSetState(self, pid, active, holdoff, level, violated):
        # Following its input, PID 11 sees the input high, and the holdoff of
        # the set in use running if it has one
        mode = self.pset_mode[pid]
        level._obj.value = mode in (2, 3) and pid == 0
        active._obj.value = 1 if (mode == 1 or (mode == 2 and level._obj.value)
                                  or (mode == 3 and not level._obj.value)) else 0
        holdoff._obj.value = level._obj.value and self.pset[(pid, active._obj.value)][8] > 0
        violated._obj.value = False
        return 0

    def rp_PIDGetCounters(self, pid, counters):
        c = counters._obj
        c.switches = 1234 if pid == 0 else 0
        c.holdoffs_went_outside = 56 if pid == 0 else 0
        c.holdoffs_ended_outside = 2 if pid == 0 else 0
        c.unlocks = 19 + pid
        return 0

    def rp_PIDSetLock(self, pid, value):
        lock = bool(_value(value))
        output = 0 if pid in (0, 1) else 1
        if lock:
            self._set("sg_enabled", output, False)
        self._set("int_reset", pid, not lock)
        self._set("hold", pid, not lock)
        self._set("enabled", pid, lock)
        if not lock:
            self._set("sg_enabled", output, True)
        return 0

    def rp_PIDGetLock(self, pid, ref):
        ref._obj.value = (not self.values.get(("int_reset", pid), False)
                          and not self.values.get(("hold", pid), False)
                          and self.values.get(("enabled", pid), True))
        return 0

    # Flags and values without logic of their own

    def rp_PIDSetInverted(self, pid, value):
        return self._set("inverted", pid, value)

    def rp_PIDGetInverted(self, pid, ref):
        return self._get("inverted", pid, ref, False)

    def rp_PIDSetHold(self, pid, value):
        return self._set("hold", pid, value)

    def rp_PIDGetHold(self, pid, ref):
        return self._get("hold", pid, ref, False)

    def rp_PIDSetIntReset(self, pid, value):
        return self._set("int_reset", pid, value)

    def rp_PIDGetIntReset(self, pid, ref):
        return self._get("int_reset", pid, ref, False)

    def rp_PIDSetResetWhenRailed(self, pid, value):
        return self._set("int_auto", pid, value)

    def rp_PIDGetResetWhenRailed(self, pid, ref):
        return self._get("int_auto", pid, ref, False)

    def rp_PIDSetEnable(self, pid, value):
        return self._set("enabled", pid, value)

    def rp_PIDGetEnable(self, pid, ref):
        return self._get("enabled", pid, ref, True)

    def rp_PIDSetRelock(self, pid, value):
        return self._set("relock", pid, value)

    def rp_PIDGetRelock(self, pid, ref):
        return self._get("relock", pid, ref, True)

    def rp_PIDSetRelockStepsize(self, pid, value):
        return self._set("relock_stepsize", pid, value)

    def rp_PIDGetRelockStepsize(self, pid, ref):
        return self._get("relock_stepsize", pid, ref, 500.0)

    def rp_PIDSetRelockInput(self, pid, value):
        return self._set("relock_input", pid, value)

    def rp_PIDGetRelockInput(self, pid, ref):
        return self._get("relock_input", pid, ref, 5)

    def rp_PIDSetLockStatusOutputEnable(self, pid, value):
        return self._set("lso", pid, value)

    def rp_PIDGetLockStatusOutputEnable(self, pid, ref):
        return self._get("lso", pid, ref, True)

    def rp_PIDSetExtResetEnable(self, pid, value):
        return self._set("ext_reset", pid, value)

    def rp_PIDGetExtResetEnable(self, pid, ref):
        return self._get("ext_reset", pid, ref, False)

    def rp_PIDSetExtResetInput(self, pid, value):
        return self._set("ext_reset_input", pid, value)

    def rp_PIDGetExtResetInput(self, pid, ref):
        return self._get("ext_reset_input", pid, ref, 13)

    def rp_LimitMin(self, output, value):
        return self._set("limit_min", output, value)

    def rp_LimitGetMin(self, output, ref):
        return self._get("limit_min", output, ref, -1.0)

    def rp_LimitMax(self, output, value):
        return self._set("limit_max", output, value)

    def rp_LimitGetMax(self, output, ref):
        return self._get("limit_max", output, ref, 1.0)

    def rp_GenWaveform(self, output, value):
        return self._set("waveform", output, value)

    def rp_GenGetWaveform(self, output, ref):
        return self._get("waveform", output, ref, 0)

    def rp_GenAmp(self, output, value):
        return self._set("amp", output, value)

    def rp_GenGetAmp(self, output, ref):
        return self._get("amp", output, ref, 1.0)

    def rp_GenFreq(self, output, value):
        return self._set("freq", output, value)

    def rp_GenGetFreq(self, output, ref):
        return self._get("freq", output, ref, 1000.0)

    def rp_GenOffset(self, output, value):
        return self._set("offset", output, value)

    def rp_GenGetOffset(self, output, ref):
        return self._get("offset", output, ref, 0.0)

    def rp_GenOutEnable(self, output):
        return self._set("sg_enabled", output, True)

    def rp_GenOutDisable(self, output):
        return self._set("sg_enabled", output, False)

    def rp_GenOutIsEnabled(self, output, ref):
        return self._get("sg_enabled", output, ref, True)

    def rp_GenPOffsetEnable(self, output):
        return self._set("poffset", output, True)

    def rp_GenPOffsetDisable(self, output):
        return self._set("poffset", output, False)

    def rp_GenPOffsetIsEnabled(self, output, ref):
        return self._get("poffset", output, ref, False)

    def rp_SaveLockboxConfig(self):
        LOG.debug("Lockbox configuration saved")
        return 0

    def rp_LoadLockboxConfig(self):
        LOG.debug("Lockbox configuration loaded")
        return 0

    def rp_ApinGetValue(self, ain, ain_voltage):
        ain_voltage._obj.value = 1.3
        return 0

    def rp_GetInVoltage(self, input, fast_input_voltage):
        fast_input_voltage._obj.value = 0.9
        return 0

    def rp_GetOutVoltage(self, input, fast_output_voltage):
        fast_output_voltage._obj.value = 0.8
        return 0

try:
    RP_LIB = ctypes.CDLL("/opt/redpitaya/lib/liblockbox.so")
except OSError as err:
    LOG.setLevel(logging.DEBUG)
    LOG.error("Failed to load lockbox library. Error: %s", err)
    RP_LIB = MockRPLib()
else:
    init_rp_library()

#: The running software's version, for the page's Options panel
VERSION = software_version()
LOG.info("rp-lockbox %s", VERSION)

run(host="0.0.0.0", port=80, quiet=True)
