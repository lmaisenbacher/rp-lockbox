# Self-checking simulation of the scope's input filter (red_pitaya_dfilt1)
# against the filter as it was in 1.4.0, before its recursive stages were
# restructured for timing. Prints PASS or FAIL.
#
#   make                 Icarus Verilog (iverilog, vvp on the PATH)
#   make SIM=xsim        Vivado xsim (Vivado's settings64.sh sourced)

PATH_TBN = ../../tbn
PATH_RTL = ../../rtl
SIM     ?= iverilog
IVERILOG ?= iverilog
VVP      ?= vvp

SRC = $(PATH_TBN)/red_pitaya_dfilt1_tb.sv \
      $(PATH_RTL)/red_pitaya_dfilt1.sv \
      $(PATH_TBN)/ref/red_pitaya_dfilt1_ref.sv

.PHONY: all clean

ifeq ($(SIM),xsim)
all:
	xvlog -sv $(SRC)
	xelab --debug typical --snapshot dfilt1_tb work.red_pitaya_dfilt1_tb
	xsim dfilt1_tb --runall
else
all:
	$(IVERILOG) -g2012 -Wall -Wno-timescale -o dfilt1_tb.vvp -s red_pitaya_dfilt1_tb $(SRC)
	$(VVP) -n dfilt1_tb.vvp
endif

clean:
	rm -rf *.vvp xsim.dir *.pb *.log *.jou *.wdb *.str
