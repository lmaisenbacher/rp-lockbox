/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Self-checking testbench of the registered system bus (sys_bus_pipe) with a
 * master that behaves like axi4_slave (one access at a time, a write or read
 * enable pulse, the address held until the acknowledge and then the last
 * write address for a cycle, a timeout after 32 cycles) and three kinds of
 * slave: registers that acknowledge one cycle after the request, a memory
 * that acknowledges three cycles after a read, and sys_bus_stub (acknowledge
 * and error always high). The AXI side, with reads issued back to back, is
 * sys_bus_axi_tb.v.
 *
 * Prints PASS or FAIL with the number of failed checks.
 */
`timescale 1ns / 1ps

module sys_bus_pipe_tb;

localparam SN = 8;

reg clk = 1'b0;
always #4 clk = ~clk;
reg rstn = 1'b0;

reg  [32-1:0]    m_addr  = 32'h0;
reg  [32-1:0]    m_wdata = 32'h0;
reg              m_wen   = 1'b0;
reg              m_ren   = 1'b0;
wire [32-1:0]    m_rdata;
wire             m_err;
wire             m_ack;
wire [SN*32-1:0] s_addr;
wire [SN*32-1:0] s_wdata;
wire [SN-1:0]    s_wen;
wire [SN-1:0]    s_ren;
wire [SN*32-1:0] s_rdata;
wire [SN-1:0]    s_err;
wire [SN-1:0]    s_ack;

sys_bus_pipe #(.SN (SN), .SW (20)) dut (
  .clk_i     (clk    ),
  .rstn_i    (rstn   ),
  .m_addr_i  (m_addr ),
  .m_wdata_i (m_wdata),
  .m_wen_i   (m_wen  ),
  .m_ren_i   (m_ren  ),
  .m_rdata_o (m_rdata),
  .m_err_o   (m_err  ),
  .m_ack_o   (m_ack  ),
  .s_addr_o  (s_addr ),
  .s_wdata_o (s_wdata),
  .s_wen_o   (s_wen  ),
  .s_ren_o   (s_ren  ),
  .s_rdata_i (s_rdata),
  .s_err_i   (s_err  ),
  .s_ack_i   (s_ack  )
);

// Slaves 0, 2, 3, 4, 6: registers; slave 1: memory with a 3-cycle read; slaves 5, 7: stubs
reg [32-1:0] mem   [SN-1:0][15:0];
reg [32-1:0] rdata [SN-1:0];
reg [SN-1:0] ack_r;
reg [3-1:0]  ren_dly [SN-1:0];

genvar s;
generate for (s = 0; s < SN; s = s + 1) begin: g_slave
  if ((s == 5) || (s == 7)) begin: g_stub
    assign s_ack[s] = 1'b1;
    assign s_err[s] = 1'b1;
    assign s_rdata[32*s+:32] = 32'h0;
  end else begin: g_reg
    always @(posedge clk) begin
      if (s_wen[s])
        mem[s][s_addr[32*s+2+:4]] <= s_wdata[32*s+:32];
      rdata[s]   <= mem[s][s_addr[32*s+2+:4]];
      ren_dly[s] <= {ren_dly[s][1:0], s_ren[s]};
      if (s == 1)
        ack_r[s] <= ren_dly[s][2] || s_wen[s];
      else
        ack_r[s] <= s_wen[s] || s_ren[s];
    end
    assign s_ack[s] = ack_r[s];
    assign s_err[s] = 1'b0;
    assign s_rdata[32*s+:32] = rdata[s];
  end
end
endgenerate

integer errors = 0;
integer checks = 0;
integer latency;
reg [31:0] last_waddr = 32'h0;

task check;
  input       cond;
  input [8*80-1:0] msg;
  begin
    checks = checks + 1;
    if (!cond) begin
      errors = errors + 1;
      $display("  FAIL: %0s (t = %0t ns)", msg, $time);
    end
  end
endtask

// One access like axi4_slave: enable pulse, wait for the acknowledge or time out
task access;
  input         we;
  input  [31:0] a;
  input  [31:0] d;
  output [31:0] q;
  output        err;
  integer       n;
  begin
    @(negedge clk);
    m_addr  = a;
    m_wdata = d;
    m_wen   = we;
    m_ren   = !we;
    @(negedge clk);
    m_wen   = 1'b0;
    m_ren   = 1'b0;
    n = 1;
    while (!m_ack && (n < 32)) begin
      @(negedge clk);
      n = n + 1;
    end
    latency = n;
    q   = m_rdata;
    err = m_err | !m_ack;
    // After the acknowledge the address falls back to the last write address
    // for a cycle, as axi4_slave's does, before the next access can start
    if (we)
      last_waddr = a;
    m_addr = last_waddr;
  end
endtask

reg [31:0] q;
reg        err;
integer    i;
integer    k;

initial begin
  $display("sys_bus_pipe_tb");
  repeat (5) @(negedge clk);
  rstn = 1'b1;
  repeat (5) @(negedge clk);

  // writes and read-back on every register slave
  for (i = 0; i < SN; i = i + 1) begin
    if ((i != 5) && (i != 7)) begin
      for (k = 0; k < 4; k = k + 1)
        access(1'b1, (i << 20) | (4*k), 32'h1000_0000*i + 17*k + 3, q, err);
    end
  end
  for (i = 0; i < SN; i = i + 1) begin
    if ((i != 5) && (i != 7)) begin
      for (k = 0; k < 4; k = k + 1) begin
        access(1'b0, (i << 20) | (4*k), 32'h0, q, err);
        check(!err, "read acknowledged without error");
        check(q == 32'h1000_0000*i + 17*k + 3, "read returns the written value");
      end
    end
  end
  // latencies: registers 3 cycles, memory 6 cycles
  access(1'b0, (0 << 20) | 4, 32'h0, q, err);
  $display("   register read: acknowledge after %0d cycles", latency);
  check(latency == 3, "register read latency");
  access(1'b0, (1 << 20) | 4, 32'h0, q, err);
  $display("   memory read: acknowledge after %0d cycles", latency);
  check(latency == 6, "memory read latency");
  // stub: acknowledged with error
  access(1'b0, (5 << 20), 32'h0, q, err);
  check(err, "stub read acknowledged with error");
  check(latency <= 3, "stub acknowledged at once");
  // the stub's permanent acknowledge does not acknowledge the next access early
  access(1'b0, (1 << 20) | 8, 32'h0, q, err);
  check(!err && (q == 32'h1000_0000 + 34 + 3), "memory read after a stub access");
  check(latency == 6, "memory read after a stub access waits for the memory");
  access(1'b1, (7 << 20), 32'h1, q, err);
  access(1'b1, (2 << 20) | 12, 32'h5555_aaaa, q, err);
  access(1'b0, (2 << 20) | 12, 32'h0, q, err);
  check(!err && (q == 32'h5555_aaaa), "register write and read after a stub write");

  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks failed)", errors, checks);
  $finish;
end

endmodule
