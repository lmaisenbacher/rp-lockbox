# -*- coding: utf-8 -*-
"""
Created on Mon Sep 25 17:09:09 2023

@author: Lothar Maisenbacher

Test SCPI commands.
"""

import rp_lockbox

# IP address or host name of Red Pitaya
rp_address = '192.168.50.37'
# Timeout (s)
timeout = 5

rp = rp_lockbox.RedPitaya(rp_address, timeout=timeout)

pid_in = 1
pid_out = 1

# Set global gain
rp.tx_txt(f'PID:IN{pid_in}:OUT{pid_out}:Kg 4096')

# Get global gain
print(rp.txrx_txt(f'PID:IN{pid_in}:OUT{pid_out}:Kg?'))

# Set P gain
rp.tx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KP 4096')

# Get P gain
print(rp.txrx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KP?'))

# Set D gain (ns)
rp.tx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KD 1e-7')

# Get D gain (ns)
print(rp.txrx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KD?'))

# Set II gain (1/s)
rp.tx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KII 1000')

# Get II gain (1/s)
print(rp.txrx_txt(f'PID:IN{pid_in}:OUT{pid_out}:KII?'))
