# Self-checking simulations of the PID with two parameter sets and of the
# registered system bus. Each prints PASS or FAIL.
#
#   make                 Icarus Verilog (iverilog, vvp on the PATH)
#   make SIM=xsim        Vivado xsim (Vivado's settings64.sh sourced)

PATH_TBN = ../../tbn
PATH_RTL = ../../rtl
SIM     ?= iverilog
IVERILOG ?= iverilog
VVP      ?= vvp

PID_SRC = $(PATH_TBN)/red_pitaya_pid_sets_tb.v \
          $(PATH_RTL)/classic/red_pitaya_pid.v \
          $(PATH_RTL)/classic/red_pitaya_pid_block.v \
          $(PATH_RTL)/classic/pid_relock.v \
          $(PATH_RTL)/classic/pid_kg_products.v \
          $(PATH_TBN)/ref/red_pitaya_pid_ref.v \
          $(PATH_TBN)/ref/red_pitaya_pid_block_ref.v \
          $(PATH_TBN)/ref/pid_relock_ref.v
BUS_SRC = $(PATH_TBN)/sys_bus_pipe_tb.v \
          $(PATH_RTL)/sys_bus_pipe.v
AXI_SRC = $(PATH_TBN)/sys_bus_axi_tb.v \
          $(PATH_RTL)/sys_bus_pipe.v

.PHONY: all pid bus clean

all: pid bus

ifeq ($(SIM),xsim)
pid:
	xvlog $(PID_SRC)
	xelab --debug typical --snapshot pid_sets_tb work.red_pitaya_pid_sets_tb
	xsim pid_sets_tb --runall

bus:
	xvlog $(BUS_SRC)
	xelab --debug typical --snapshot bus_pipe_tb work.sys_bus_pipe_tb
	xsim bus_pipe_tb --runall
	xvlog $(AXI_SRC)
	xelab --debug typical --snapshot bus_axi_tb work.sys_bus_axi_tb
	xsim bus_axi_tb --runall
else
pid:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o pid_sets_tb.vvp -s red_pitaya_pid_sets_tb $(PID_SRC)
	$(VVP) -n pid_sets_tb.vvp

bus:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o bus_pipe_tb.vvp -s sys_bus_pipe_tb $(BUS_SRC)
	$(VVP) -n bus_pipe_tb.vvp
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o bus_axi_tb.vvp -s sys_bus_axi_tb $(AXI_SRC)
	$(VVP) -n bus_axi_tb.vvp
endif

clean:
	rm -rf *.vvp xsim.dir *.pb *.log *.jou *.wdb *.str
