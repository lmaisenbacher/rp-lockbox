# Out-of-context synthesis of the PID module with the build's synthesis
# options, written out as a functional netlist for the port-level test
set path_rtl ../../rtl/classic
read_verilog [list $path_rtl/red_pitaya_pid.v $path_rtl/red_pitaya_pid_block.v \
                   $path_rtl/pid_relock.v $path_rtl/pid_kg_products.v]
synth_design -top red_pitaya_pid -part xc7z010clg400-1 -mode out_of_context \
             -flatten_hierarchy none -keep_equivalent_registers
write_verilog -force -mode funcsim pid_netlist.v
