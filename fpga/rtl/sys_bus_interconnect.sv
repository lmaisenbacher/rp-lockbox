////////////////////////////////////////////////////////////////////////////////
// Module: System bus interconnect
// Author: Iztok Jeras <iztok.jeras@redpitaya.com>
// (c) Red Pitaya  (redpitaya.com)
//
// The bus is registered once in each direction (sys_bus_pipe): the write data
// fans out to every configuration register of every slave, and registered per
// slave, each slave loads it from a copy of its own.
////////////////////////////////////////////////////////////////////////////////

module sys_bus_interconnect #(
  int unsigned SN = 16, // slave number
  int unsigned SW = 20  // slave width (address bus width)
)(
  sys_bus_if.s bus_m,          // from master
  sys_bus_if.m bus_s [SN-1:0]  // to   slaves
);

logic [SN*32-1:0] s_addr ;
logic [SN*32-1:0] s_wdata;
logic [SN   -1:0] s_wen  ;
logic [SN   -1:0] s_ren  ;
logic [SN*32-1:0] s_rdata;
logic [SN   -1:0] s_err  ;
logic [SN   -1:0] s_ack  ;

sys_bus_pipe #(
  .SN (SN),
  .SW (SW)
) i_pipe (
  .clk_i     (bus_m.clk  ),
  .rstn_i    (bus_m.rstn ),
  .m_addr_i  (bus_m.addr ),
  .m_wdata_i (bus_m.wdata),
  .m_wen_i   (bus_m.wen  ),
  .m_ren_i   (bus_m.ren  ),
  .m_rdata_o (bus_m.rdata),
  .m_err_o   (bus_m.err  ),
  .m_ack_o   (bus_m.ack  ),
  .s_addr_o  (s_addr     ),
  .s_wdata_o (s_wdata    ),
  .s_wen_o   (s_wen      ),
  .s_ren_o   (s_ren      ),
  .s_rdata_i (s_rdata    ),
  .s_err_i   (s_err      ),
  .s_ack_i   (s_ack      )
);

generate
for (genvar i=0; i<SN; i++) begin: for_bus

assign bus_s[i].addr  = s_addr [32*i+:32];
assign bus_s[i].wdata = s_wdata[32*i+:32];
assign bus_s[i].wen   = s_wen  [i];
assign bus_s[i].ren   = s_ren  [i];

assign s_rdata[32*i+:32] = bus_s[i].rdata;
assign s_err  [i]        = bus_s[i].err  ;
assign s_ack  [i]        = bus_s[i].ack  ;

end: for_bus
endgenerate

endmodule: sys_bus_interconnect
