/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * One register stage between the system bus master and its slaves, in both
 * directions: the request (address, write data, write and read enable) is
 * registered once per slave, so that each slave's registers load from a copy
 * placed near them, and the response (read data, error, acknowledge) is
 * registered after the slave multiplexer. An access takes two clock cycles
 * more; the AXI slave waits up to 32 cycles for the acknowledge.
 *
 * The acknowledge is passed on only while a request is in flight, so a slave
 * that acknowledges permanently (`sys_bus_stub`) cannot acknowledge the next
 * access to another slave before that slave has answered.
 *
 * The slave side is flattened: slave i uses bits [32*i +: 32] and bit i.
 */
`timescale 1ns / 1ps

module sys_bus_pipe #(
  parameter SN = 8,  // slave number
  parameter SW = 20  // slave width (address bus width)
)(
  input  wire               clk_i,
  input  wire               rstn_i,
  // master
  input  wire [   32-1:0]   m_addr_i,
  input  wire [   32-1:0]   m_wdata_i,
  input  wire               m_wen_i,
  input  wire               m_ren_i,
  output reg  [   32-1:0]   m_rdata_o,
  output reg                m_err_o,
  output reg                m_ack_o,
  // slaves
  output reg  [SN*32-1:0]   s_addr_o,
  output reg  [SN*32-1:0]   s_wdata_o,
  output reg  [   SN-1:0]   s_wen_o,
  output reg  [   SN-1:0]   s_ren_o,
  input  wire [SN*32-1:0]   s_rdata_i,
  input  wire [   SN-1:0]   s_err_i,
  input  wire [   SN-1:0]   s_ack_i
);

// slave number logarithm (a constant function: Vivado 2017.2 takes no $clog2
// in a Verilog localparam)
function integer clog2;
  input integer value;
  begin
    value = value - 1;
    for (clog2 = 0; value > 0; clog2 = clog2 + 1)
      value = value >> 1;
  end
endfunction
localparam SL = clog2(SN);

wire [SL-1:0] m_sel = m_addr_i[SW+:SL];

// The address and the write data are taken with the request and held until
// the next one: between accesses the master's address falls back to its last
// write address, and a slave that acknowledges a read some cycles late must
// still see the address of that read.
genvar i;
generate for (i = 0; i < SN; i = i + 1) begin: for_bus
  always @(posedge clk_i) begin
    if (m_wen_i | m_ren_i) begin
      s_addr_o [32*i+:32] <= m_addr_i;
      s_wdata_o[32*i+:32] <= m_wdata_i;
    end
    if (rstn_i == 1'b0) begin
      s_wen_o[i] <= 1'b0;
      s_ren_o[i] <= 1'b0;
    end else begin
      s_wen_o[i] <= m_wen_i & (m_sel == i);
      s_ren_o[i] <= m_ren_i & (m_sel == i);
    end
  end
end
endgenerate

// Slave of the request in flight
reg  [SL-1:0] r_sel;
reg           pending;
wire          forwarded = |(s_wen_o | s_ren_o);
wire          ack_sel   = s_ack_i[r_sel];

always @(posedge clk_i) begin
  if (m_wen_i | m_ren_i)
    r_sel   <= m_sel;
  m_rdata_o <= s_rdata_i[32*r_sel+:32];
  m_err_o   <= s_err_i[r_sel];
  if (rstn_i == 1'b0) begin
    pending <= 1'b0;
    m_ack_o <= 1'b0;
  end else begin
    m_ack_o <= (forwarded | pending) &  ack_sel;
    pending <= (forwarded | pending) & ~ack_sel;
  end
end

endmodule
