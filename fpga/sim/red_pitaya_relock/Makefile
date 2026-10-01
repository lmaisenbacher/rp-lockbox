# Self-checking simulation of the relock sweep (pid_relock) against the
# module as it was in 1.3.2. Prints PASS or FAIL.
#
#   make                 Icarus Verilog (iverilog, vvp on the PATH)
#   make SIM=xsim        Vivado xsim (Vivado's settings64.sh sourced)

PATH_TBN = ../../tbn
PATH_RTL = ../../rtl
SIM     ?= iverilog
IVERILOG ?= iverilog
VVP      ?= vvp

SRC = $(PATH_TBN)/pid_relock_tb.v \
      $(PATH_RTL)/classic/pid_relock.v \
      $(PATH_TBN)/ref/pid_relock_ref.v

.PHONY: all clean

ifeq ($(SIM),xsim)
all:
	xvlog $(SRC)
	xelab --debug typical --snapshot pid_relock_tb work.pid_relock_tb
	xsim pid_relock_tb --runall
else
all:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o pid_relock_tb.vvp -s pid_relock_tb $(SRC)
	$(VVP) -n pid_relock_tb.vvp
endif

clean:
	rm -rf *.vvp xsim.dir *.pb *.log *.jou *.wdb *.str
