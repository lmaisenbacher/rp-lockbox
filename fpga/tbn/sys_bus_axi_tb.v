/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Self-checking testbench of the registered system bus (sys_bus_pipe) behind
 * the bus side of axi4_slave (rtl/axi4_slave.sv, ported to Verilog), with an
 * AXI master that issues reads back to back (the next address the cycle after
 * each address handshake) and a slave with the acknowledge logic of the
 * generator (red_pitaya_asg): registers that acknowledge with the request,
 * and a buffer whose reads are acknowledged by a delay line that every read
 * starts, decoded with the address at the time it comes out.
 *
 * Between two reads axi4_slave's address falls back to the last write
 * address. The pipe takes the address only with a request, so a delayed
 * acknowledge never meets an address the slave was not asked for.
 *
 * Prints PASS or FAIL with the number of failed checks.
 */
`timescale 1ns / 1ps

module sys_bus_axi_tb;

localparam SN = 8;

reg clk = 1'b0;
always #4 clk = ~clk;
reg rstn = 1'b0;

//---------------------------------------------------------------------------------
// AXI master signals

reg         AWVALID = 1'b0;
reg         WVALID  = 1'b0;
reg         ARVALID = 1'b0;
reg  [31:0] AWADDR  = 32'h0;
reg  [31:0] WDATA   = 32'h0;
reg  [31:0] ARADDR  = 32'h0;
wire        BREADY  = 1'b1;
wire        RREADY  = 1'b1;

//---------------------------------------------------------------------------------
// axi4_slave, bus side

reg         rd_do;
reg         wr_do;
reg  [31:0] rd_araddr;
reg  [31:0] wr_awaddr;
reg  [31:0] wr_wdata;
reg  [ 5:0] ack_cnt;
wire        ack;
reg         bus_wen;
reg         bus_ren;
wire [31:0] bus_addr = rd_do ? rd_araddr : wr_awaddr;
wire [31:0] bus_rdata;
wire        bus_ack;
wire        bus_err;
wire        AWREADY = !wr_do && !rd_do;
wire        WREADY  = wr_do && WVALID;
wire        ARREADY = !rd_do && !wr_do && !AWVALID;
reg         RVALID;
reg         BVALID;
reg  [31:0] RDATA;

always @(posedge clk)
if (!rstn) begin
  rd_do <= 1'b0;
end else begin
  if (ARVALID & ~rd_do & ~AWVALID & ~wr_do) rd_do <= 1'b1;
  else if (RREADY & rd_do & ack)            rd_do <= 1'b0;
  if (ARVALID & ARREADY) rd_araddr <= ARADDR;
end

always @(posedge clk)
if (!rstn) begin
  wr_do <= 1'b0;
end else begin
  if (AWVALID & ~wr_do & ~rd_do)    wr_do <= 1'b1;
  else if (BREADY & wr_do & ack)    wr_do <= 1'b0;
  if (AWVALID & AWREADY) wr_awaddr <= AWADDR;
  if (WVALID && wr_do)   wr_wdata  <= WDATA;
end

always @(posedge clk)
if (!rstn) begin
  RVALID <= 1'b0;
  BVALID <= 1'b0;
end else begin
  RVALID <= rd_do && ack;
  BVALID <= wr_do && ack;
  RDATA  <= bus_rdata;
end

always @(posedge clk)
if (!rstn)
  ack_cnt <= 6'h0;
else begin
  if ((ARVALID && ARREADY) || (AWVALID && AWREADY)) ack_cnt <= 6'h1;
  else if (ack)                                     ack_cnt <= 6'h0;
  else if (|ack_cnt)                                ack_cnt <= ack_cnt + 6'h1;
end

assign ack = bus_ack || ack_cnt[5];

always @(posedge clk)
if (!rstn) begin
  bus_wen <= 1'b0;
  bus_ren <= 1'b0;
end else begin
  bus_wen <= wr_do && WVALID;
  bus_ren <= ARVALID && ARREADY;
end

//---------------------------------------------------------------------------------
// The pipe and the slaves

wire [SN*32-1:0] s_addr;
wire [SN*32-1:0] s_wdata;
wire [SN*32-1:0] s_rdata;
wire [SN-1:0]    s_wen;
wire [SN-1:0]    s_ren;
wire [SN-1:0]    s_err;
wire [SN-1:0]    s_ack;

sys_bus_pipe #(.SN (SN), .SW (20)) dut (
  .clk_i     (clk      ),
  .rstn_i    (rstn     ),
  .m_addr_i  (bus_addr ),
  .m_wdata_i (wr_wdata ),
  .m_wen_i   (bus_wen  ),
  .m_ren_i   (bus_ren  ),
  .m_rdata_o (bus_rdata),
  .m_err_o   (bus_err  ),
  .m_ack_o   (bus_ack  ),
  .s_addr_o  (s_addr   ),
  .s_wdata_o (s_wdata  ),
  .s_wen_o   (s_wen    ),
  .s_ren_o   (s_ren    ),
  .s_rdata_i (s_rdata  ),
  .s_err_i   (s_err    ),
  .s_ack_i   (s_ack    )
);

// Slave 2, like the generator: registers at 0x00000-0x0FFFF, a buffer at
// 0x10000-0x1FFFF (in red_pitaya_asg the buffers of both channels)
wire [31:0] a2   = s_addr[64+:32];
wire        wen2 = s_wen[2];
wire        ren2 = s_ren[2];
reg  [ 2:0] ren_dly;
reg         ack_dly;
reg         ack2;
reg  [31:0] rd2;
reg  [31:0] regs  [0:15];
reg  [13:0] buf_a [0:1023];
reg  [13:0] buf_rd;
integer     j;

initial begin
  for (j = 0; j < 16; j = j + 1)
    regs[j] = 32'h100 + j;
  for (j = 0; j < 1024; j = j + 1)
    buf_a[j] = 14'h2000 | j;
end

always @(posedge clk) begin
  ren_dly <= {ren_dly[1:0], ren2};
  ack_dly <= ren_dly[2] || wen2;
  if (wen2 && a2[19:16] == 4'h1) buf_a[a2[11:2]] <= s_wdata[64+:14];
  if (wen2 && a2[19:16] == 4'h0) regs[a2[5:2]]   <= s_wdata[64+:32];
  buf_rd <= buf_a[a2[11:2]];
  casez (a2[19:0])
    20'h1zzzz: begin ack2 <= ack_dly;     rd2 <= {18'h0, buf_rd}; end
    default:   begin ack2 <= wen2 | ren2; rd2 <= regs[a2[5:2]];   end
  endcase
end

// The other slaves: a register that reads 0xA0000000 + slave number
genvar s;
generate for (s = 0; s < SN; s = s + 1) begin: g_slave
  if (s == 2) begin: g_asg
    assign s_ack[s] = ack2;
    assign s_rdata[32*s+:32] = rd2;
    assign s_err[s] = 1'b0;
  end else begin: g_reg
    reg        a;
    reg [31:0] d;
    always @(posedge clk) begin
      a <= s_wen[s] | s_ren[s];
      d <= 32'hA000_0000 + s;
    end
    assign s_ack[s] = a;
    assign s_rdata[32*s+:32] = d;
    assign s_err[s] = 1'b0;
  end
end
endgenerate

//---------------------------------------------------------------------------------
// Master

integer errors = 0;
integer checks = 0;

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

task axi_write;
  input [31:0] a;
  input [31:0] d;
  begin
    @(negedge clk);
    AWVALID = 1'b1;
    AWADDR  = a;
    WVALID  = 1'b1;
    WDATA   = d;
    while (!AWREADY) @(negedge clk);
    @(negedge clk);
    AWVALID = 1'b0;
    while (!WREADY) @(negedge clk);
    @(negedge clk);
    WVALID = 1'b0;
    while (!BVALID) @(negedge clk);
  end
endtask

// Reads back to back: the next address right after each address handshake
reg [31:0] got   [0:7];
reg [31:0] addrs [0:7];
integer    n_got = 0;

always @(posedge clk)
  if (RVALID) begin
    got[n_got] <= RDATA;
    n_got <= n_got + 1;
  end

task reads;
  input integer n;
  integer k;
  begin
    n_got = 0;
    @(negedge clk);
    ARVALID = 1'b1;
    ARADDR  = addrs[0];
    for (k = 0; k < n; k = k + 1) begin
      while (!ARREADY) @(negedge clk);
      @(negedge clk);
      if (k + 1 < n)
        ARADDR = addrs[k + 1];
      else
        ARVALID = 1'b0;
    end
    repeat (40) @(negedge clk);
  end
endtask

initial begin
  $display("sys_bus_axi_tb");
  repeat (5) @(negedge clk);
  rstn = 1'b1;
  repeat (5) @(negedge clk);

  // Register reads, the last write having gone to the buffer
  axi_write(32'h0021_0010, 32'h55);
  repeat (5) @(negedge clk);
  addrs[0] = 32'h0020_0008;
  addrs[1] = 32'h0020_000C;
  addrs[2] = 32'h0020_0010;
  addrs[3] = 32'h0030_0000;
  reads(4);
  check(n_got == 4, "four reads answered after a buffer write");
  check(got[0] === 32'h102 && got[1] === 32'h103 && got[2] === 32'h104 && got[3] === 32'hA000_0003,
        "register reads after a buffer write");

  // The same after a register write
  axi_write(32'h0020_0000, 32'h100);
  repeat (5) @(negedge clk);
  reads(4);
  check(got[0] === 32'h102 && got[1] === 32'h103 && got[2] === 32'h104 && got[3] === 32'hA000_0003,
        "register reads after a register write");

  // A register read, then buffer reads
  addrs[0] = 32'h0020_0008;
  addrs[1] = 32'h0021_0020;
  addrs[2] = 32'h0021_0024;
  addrs[3] = 32'h0020_000C;
  reads(4);
  check(got[0] === 32'h102 && got[1] === 32'h2008 && got[2] === 32'h2009 && got[3] === 32'h103,
        "a register read, then buffer reads");

  // Single reads with idle cycles between them, after a buffer write
  axi_write(32'h0021_0010, 32'h55);
  repeat (5) @(negedge clk);
  addrs[0] = 32'h0020_0008;
  reads(1);
  check(got[0] === 32'h102, "single register read after a buffer write");
  addrs[0] = 32'h0021_0010;
  reads(1);
  check(got[0] === 32'h55, "the buffer holds the written value");

  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks failed)", errors, checks);
  $finish;
end

endmodule
