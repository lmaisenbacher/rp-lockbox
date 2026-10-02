# Self-checking simulations of the PID with two parameter sets and of the
# registered system bus. Each prints PASS or FAIL.
#
#   make                 Icarus Verilog (iverilog, vvp on the PATH)
#   make SIM=xsim        Vivado xsim (Vivado's settings64.sh sourced)
#   make netlist         the port-level test on the synthesized PID module
#                        (Vivado's settings64.sh sourced, a few minutes)

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
PORTS_SRC = $(PATH_TBN)/red_pitaya_pid_ports_tb.v \
          $(PATH_RTL)/classic/red_pitaya_pid.v \
          $(PATH_RTL)/classic/red_pitaya_pid_block.v \
          $(PATH_RTL)/classic/pid_relock.v \
          $(PATH_RTL)/classic/pid_kg_products.v
BUS_SRC = $(PATH_TBN)/sys_bus_pipe_tb.v \
          $(PATH_RTL)/sys_bus_pipe.v
AXI_SRC = $(PATH_TBN)/sys_bus_axi_tb.v \
          $(PATH_RTL)/sys_bus_pipe.v

.PHONY: all pid ports bus netlist clean

all: pid ports bus

netlist:
	vivado -nojournal -nolog -mode batch -source pid_netlist.tcl > pid_netlist.log
	xvlog pid_netlist.v $(PATH_TBN)/red_pitaya_pid_ports_tb.v $(XILINX_VIVADO)/data/verilog/src/glbl.v
	xelab -L unisims_ver -L secureip --snapshot pid_ports_netlist work.red_pitaya_pid_ports_tb work.glbl
	xsim pid_ports_netlist --runall | grep -v "^LOG"

ifeq ($(SIM),xsim)
pid:
	xvlog $(PID_SRC)
	xelab --debug typical --snapshot pid_sets_tb work.red_pitaya_pid_sets_tb
	xsim pid_sets_tb --runall

ports:
	xvlog $(PORTS_SRC)
	xelab --debug typical --snapshot pid_ports_tb work.red_pitaya_pid_ports_tb
	xsim pid_ports_tb --runall | grep -v "^LOG"

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

ports:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o pid_ports_tb.vvp -s red_pitaya_pid_ports_tb $(PORTS_SRC)
	$(VVP) -n pid_ports_tb.vvp | grep -v "^LOG"

bus:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o bus_pipe_tb.vvp -s sys_bus_pipe_tb $(BUS_SRC)
	$(VVP) -n bus_pipe_tb.vvp
	$(IVERILOG) -g2005 -Wall -Wno-timescale -o bus_axi_tb.vvp -s sys_bus_axi_tb $(AXI_SRC)
	$(VVP) -n bus_axi_tb.vvp
endif

clean:
	rm -rf *.vvp xsim.dir *.pb *.log *.jou *.wdb *.str pid_netlist.v .Xil
