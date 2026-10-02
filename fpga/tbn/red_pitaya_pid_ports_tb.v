/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Port-level test of the independence of the four PIDs: gains and set points
 * per set and PID, the parameter set selection by mode and by digital input
 * (all seven inputs, with the glitch filter), the external lock reset per PID
 * and source, and the lock windows, holdoffs, status bits and event counters
 * per PID. It uses the ports only, so it runs on the synthesized netlist as
 * well as on the RTL and catches synthesis errors the RTL simulation cannot
 * see (see the note on Vivado 2017.2 in red_pitaya_pid.v). The lines
 * starting with "LOG" can be compared between the two runs.
 */
`timescale 1ns / 1ps
module red_pitaya_pid_ports_tb;
reg clk = 1'b0;
always #4 clk = ~clk;
reg rstn = 1'b0;
reg  [31:0] sys_addr = 0, sys_wdata = 0;
reg         sys_wen = 0, sys_ren = 0;
wire [31:0] rdata;
wire        ack, err;
reg  [13:0] in_a = 14'd100, in_b = 14'd100;
reg  [11:0] aux0 = 12'd150, aux1 = 12'd150, aux2 = 12'd150, aux3 = 12'd150;
reg  [7:0]  dio_p = 8'h0, dio_n = 8'h0;
wire [13:0] out_a, out_b;
wire [3:0]  lock;
red_pitaya_pid dut (
  .clk_i(clk), .rstn_i(rstn), .dat_a_i(in_a), .dat_b_i(in_b), .railed_a_i(2'b00),
  .railed_b_i(2'b00), .relock_a_i(aux0), .relock_b_i(aux1), .relock_c_i(aux2),
  .relock_d_i(aux3), .out_a_center_i(14'd0), .out_b_center_i(14'd0), .dio_p_i(dio_p),
  .dio_n_i(dio_n), .dat_a_o(out_a), .dat_b_o(out_b), .lock_status_o(lock),
  .sys_addr(sys_addr), .sys_wdata(sys_wdata), .sys_wen(sys_wen), .sys_ren(sys_ren),
  .sys_rdata(rdata), .sys_err(err), .sys_ack(ack));

integer errors = 0, checks = 0;
reg [8*40-1:0] ctx;

task check_eq(input integer got, input integer exp, input [8*24-1:0] what);
  begin
    checks = checks + 1;
    if (got !== exp) begin
      errors = errors + 1;
      $display("FAIL %0s, %0s: %0d, expected %0d", ctx, what, got, exp);
    end
  end
endtask

task wr(input [31:0] a, input [31:0] d);
  begin
    @(negedge clk); sys_addr = a; sys_wdata = d; sys_wen = 1;
    @(negedge clk); sys_wen = 0;
    repeat (4) @(negedge clk);
  end
endtask

task rd(input [31:0] a, output [31:0] d);
  integer n;
  begin
    @(negedge clk); sys_addr = a; sys_ren = 1;
    @(negedge clk); sys_ren = 0;
    n = 0;
    while (ack !== 1'b1 && n < 10) begin
      @(negedge clk); n = n + 1;
    end
    d = rdata;
    repeat (2) @(negedge clk);
  end
endtask

task settle(input integer n);
  repeat (n) @(negedge clk);
endtask

// The selectable inputs in the order of the source registers
task set_dio(input integer i, input v);
  case (i)
    0: dio_p[5] = v;
    1: dio_p[6] = v;
    2: dio_p[7] = v;
    3: dio_n[0] = v;
    4: dio_n[5] = v;
    5: dio_n[6] = v;
    6: dio_n[7] = v;
  endcase
endtask

task pulse(input integer i, input integer n);
  begin
    @(negedge clk); set_dio(i, 1'b1);
    repeat (n) @(negedge clk);
    set_dio(i, 1'b0);
  end
endtask

// KG of PID k in set s: unique sums of the two PIDs on each output
function integer kg_of(input integer k, input integer s);
  kg_of = s ? ((k % 2) ? 8 : 4) : ((k % 2) ? 2 : 1);
endfunction

task reset_all;
  begin
    @(negedge clk); rstn = 0;
    settle(10);
    rstn = 1;
    settle(10);
  end
endtask

task set_modes(input [3:0] c);
  integer k;
  for (k = 0; k < 4; k = k + 1)
    wr(32'h0c0 + 4 * k, c[k]);
endtask

task check_outputs_kg(input [3:0] c);
  begin
    check_eq($signed(out_a), 100 * (kg_of(0, c[0]) + kg_of(1, c[1])), "OUT1");
    check_eq($signed(out_b), 100 * (kg_of(2, c[2]) + kg_of(3, c[3])), "OUT2");
  end
endtask

integer k, s, c, i, j, n, peak_a, peak_b, exp_a, exp_b;
integer combos [0:5];
reg [31:0] st, d0, d1, d2, d3;

initial begin
  combos[0] = 0; combos[1] = 1; combos[2] = 2; combos[3] = 4; combos[4] = 8; combos[5] = 15;
  settle(30);
  rstn = 1;
  settle(10);

  // 1. Gains: P only (KP 1), KG per PID and set; all 16 combinations of the sets
  wr(32'h000, 32'hF0F0_0000);  // outputs and lock status outputs on, no integrator reset
  for (k = 0; k < 4; k = k + 1)
    for (s = 0; s < 2; s = s + 1) begin
      wr(32'h020 + 32'h100 * s + 4 * k, 1 << 12);
      wr(32'h0a0 + 32'h100 * s + 4 * k, kg_of(k, s) << 12);
    end
  for (c = 0; c < 16; c = c + 1) begin
    $sformat(ctx, "1. gains, sets %b", c[3:0]);
    set_modes(c);
    settle(80);
    check_outputs_kg(c);
    rd(32'h0f0, st);
    check_eq(st[3:0], c, "active sets");
    $display("LOG 1 %b %0d %0d %h", c[3:0], $signed(out_a), $signed(out_b), st);
  end

  // 2. Set points: KG 1 in both sets, set point 10 (k+1) in set 2
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h0a0 + 4 * k, 1 << 12);
    wr(32'h1a0 + 4 * k, 1 << 12);
    wr(32'h110 + 4 * k, 10 * (k + 1));
  end
  for (c = 0; c < 16; c = c + 1) begin
    $sformat(ctx, "2. set points, sets %b", c[3:0]);
    set_modes(c);
    settle(80);
    check_eq($signed(out_a), (100 - (c[0] ? 10 : 0)) + (100 - (c[1] ? 20 : 0)), "OUT1");
    check_eq($signed(out_b), (100 - (c[2] ? 30 : 0)) + (100 - (c[3] ? 40 : 0)), "OUT2");
    $display("LOG 2 %b %0d %0d", c[3:0], $signed(out_a), $signed(out_b));
  end
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h110 + 4 * k, 0);
    wr(32'h0a0 + 4 * k, kg_of(k, 0) << 12);
    wr(32'h1a0 + 4 * k, kg_of(k, 1) << 12);
  end
  set_modes(4'b0000);

  // 3. Selection by the digital inputs
  // 3a. Each input's level, alone, in the status
  for (i = 0; i < 7; i = i + 1) begin
    $sformat(ctx, "3a. input %0d", i);
    set_dio(i, 1'b1);
    settle(20);
    rd(32'h0f0, st);
    check_eq(st[22:16], 1 << i, "input levels");
    set_dio(i, 1'b0);
    settle(20);
  end
  // 3b. PID k follows input k (high: set 2); each input alone, then all
  for (k = 0; k < 4; k = k + 1)
    wr(32'h0c0 + 4 * k, 2 | (k << 4));
  for (i = 0; i < 4; i = i + 1) begin
    $sformat(ctx, "3b. PID k on input k, input %0d high", i);
    set_dio(i, 1'b1);
    settle(80);
    check_outputs_kg(1 << i);
    rd(32'h0f0, st);
    check_eq(st[3:0], 1 << i, "active sets");
    set_dio(i, 1'b0);
    settle(80);
    check_outputs_kg(0);
  end
  $sformat(ctx, "3b. inputs 0-3 high");
  for (i = 0; i < 4; i = i + 1) set_dio(i, 1'b1);
  settle(80);
  check_outputs_kg(4'b1111);
  for (i = 0; i < 4; i = i + 1) set_dio(i, 1'b0);
  settle(80);
  // 3c. PIDs 0-2 follow inputs 4-6, PID 3 follows input 0 inverted (high: set 1)
  for (k = 0; k < 3; k = k + 1)
    wr(32'h0c0 + 4 * k, 2 | ((k + 4) << 4));
  wr(32'h0cc, 3 | (0 << 4));
  for (i = 0; i < 7; i = i + 1) begin
    $sformat(ctx, "3c. inputs 4-6 and 0 inverted, input %0d", i);
    set_dio(i, 1'b1);
    settle(80);
    c = 4'b1000;
    if (i >= 4) c = c | (1 << (i - 4));
    if (i == 0) c = c & 4'b0111;
    check_outputs_kg(c);
    rd(32'h0f0, st);
    check_eq(st[3:0], c, "active sets");
    $display("LOG 3c %0d %0d %0d %h", i, $signed(out_a), $signed(out_b), st);
    set_dio(i, 1'b0);
    settle(80);
  end
  // 3d. All four on input 2 (DIO7_P), PID 1 inverted
  wr(32'h0c0, 2 | (2 << 4));
  wr(32'h0c4, 3 | (2 << 4));
  wr(32'h0c8, 2 | (2 << 4));
  wr(32'h0cc, 2 | (2 << 4));
  $sformat(ctx, "3d. one input for all, low");
  settle(80);
  check_outputs_kg(4'b0010);
  $sformat(ctx, "3d. one input for all, high");
  set_dio(2, 1'b1);
  settle(80);
  check_outputs_kg(4'b1101);
  set_dio(2, 1'b0);
  settle(80);
  // 3e. The glitch filter of each input: 3 cycles are ignored, 4 switch (twice)
  for (i = 0; i < 7; i = i + 1) begin
    $sformat(ctx, "3e. filter of input %0d", i);
    set_modes(4'b0000);
    k = i % 4;
    wr(32'h0c0 + 4 * k, 2 | (i << 4));
    settle(20);
    rd(32'h200 + 4 * k, d0);
    pulse(i, 3);
    settle(20);
    rd(32'h200 + 4 * k, d1);
    check_eq(d1 - d0, 0, "switches after 3 cycles");
    pulse(i, 4);
    settle(20);
    rd(32'h200 + 4 * k, d2);
    check_eq(d2 - d1, 2, "switches after 4 cycles");
    $display("LOG 3e %0d %0d %0d %0d", i, d0, d1, d2);
  end
  set_modes(4'b0000);
  settle(80);

  // 4. External lock reset: it takes the PID off its output
  // 4a. One PID enabled at a time, its source (k+1) mod 4; each source raised
  for (k = 0; k < 4; k = k + 1)
    wr(32'h0b0 + 4 * k, (k + 1) % 4);
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h004, 1 << k);
    for (i = 0; i < 4; i = i + 1) begin
      $sformat(ctx, "4a. reset enabled PID %0d, source %0d", k, i);
      set_dio(i, 1'b1);
      settle(40);
      exp_a = 300 - (((k == 0) && (i == 1)) ? 100 : 0) - (((k == 1) && (i == 2)) ? 200 : 0);
      exp_b = 300 - (((k == 2) && (i == 3)) ? 100 : 0) - (((k == 3) && (i == 0)) ? 200 : 0);
      check_eq($signed(out_a), exp_a, "OUT1");
      check_eq($signed(out_b), exp_b, "OUT2");
      set_dio(i, 1'b0);
      settle(40);
      check_outputs_kg(0);
    end
  end
  // 4b. All enabled, all on source 3 (DIO0_N)
  wr(32'h004, 4'b1111);
  for (k = 0; k < 4; k = k + 1)
    wr(32'h0b0 + 4 * k, 3);
  $sformat(ctx, "4b. all on source 3");
  set_dio(3, 1'b1);
  settle(40);
  check_eq($signed(out_a), 0, "OUT1");
  check_eq($signed(out_b), 0, "OUT2");
  set_dio(3, 1'b0);
  settle(40);
  check_outputs_kg(0);
  wr(32'h004, 0);

  // 5. Lock windows, holdoffs, status and counters
  reset_all;
  wr(32'h000, 32'hF0F0_0000);
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h080 + 4 * k, k);              // monitor: auxiliary input k
    wr(32'h050 + 4 * k, 100);            // set 1 window 100-200
    wr(32'h060 + 4 * k, 200);
    wr(32'h150 + 4 * k, 1000 + 10 * k);  // set 2 window outside
    wr(32'h160 + 4 * k, 1100 + 10 * k);
    wr(32'h1d0 + 4 * k, 40 * (k + 1));   // holdoff entering set 2
  end
  settle(20);
  $sformat(ctx, "5. start");
  check_eq(lock, 4'b1111, "lock status");
  rd(32'h0f0, st);
  check_eq(st[11:8], 4'b1111, "in window");
  for (k = 0; k < 4; k = k + 1) begin
    $sformat(ctx, "5. PID %0d to set 2, in holdoff", k);
    wr(32'h0c0 + 4 * k, 1);
    check_eq(lock, 4'b1111, "lock status");
    rd(32'h0f0, st);
    check_eq(st[3:0], 1 << k, "active sets");
    check_eq(st[7:4], 1 << k, "holdoff running");
    check_eq(st[11:8], 4'b1111 & ~(1 << k), "in window");
    check_eq(st[15:12], 1 << k, "went outside");
    $display("LOG 5h %0d %b %h", k, lock, st);
    $sformat(ctx, "5. PID %0d to set 2, after holdoff", k);
    settle(40 * (k + 1) + 20);
    check_eq(lock, 4'b1111 & ~(1 << k), "lock status");
    rd(32'h0f0, st);
    check_eq(st[7:4], 0, "holdoff running");
    check_eq(st[15:12], 1 << k, "went outside");
    for (j = 0; j < 4; j = j + 1) begin
      rd(32'h200 + 4 * j, d0);
      rd(32'h210 + 4 * j, d1);
      rd(32'h220 + 4 * j, d2);
      rd(32'h230 + 4 * j, d3);
      $sformat(ctx, "5. PID %0d to set 2, counters of PID %0d", k, j);
      check_eq(d0, (j < k) ? 2 : (j == k) ? 1 : 0, "switches");
      check_eq(d1, (j <= k) ? 1 : 0, "went outside");
      check_eq(d2, (j <= k) ? 1 : 0, "ended outside");
      check_eq(d3, (j <= k) ? 1 : 0, "unlocks");
      $display("LOG 5c %0d %0d %0d %0d %0d %0d", k, j, d0, d1, d2, d3);
    end
    $sformat(ctx, "5. PID %0d back to set 1", k);
    wr(32'h0c0 + 4 * k, 0);
    settle(30);
    check_eq(lock, 4'b1111, "lock status");
    rd(32'h0f0, st);
    check_eq(st[15:0], 16'h0F00, "status");
  end
  // A switch into a window the monitor is in: no violation
  $sformat(ctx, "5. PID 2 to set 2, inside");
  wr(32'h158, 100);
  wr(32'h168, 200);
  wr(32'h0c8, 1);
  check_eq(lock, 4'b1111, "lock status");
  settle(150);
  check_eq(lock, 4'b1111, "lock status");
  rd(32'h0f0, st);
  check_eq(st[15:0], 16'h0F04, "status");
  rd(32'h208, d0);
  rd(32'h218, d1);
  check_eq(d0, 3, "switches");
  check_eq(d1, 1, "went outside");
  wr(32'h0c8, 0);
  settle(30);
  // Monitor inputs: PID 3 watches auxiliary input 0 as well
  wr(32'h08c, 0);
  settle(20);
  $sformat(ctx, "5. input 0 outside");
  aux0 = 12'd50;
  settle(20);
  check_eq(lock, 4'b0110, "lock status");
  aux0 = 12'd150;
  settle(20);
  $sformat(ctx, "5. input 1 outside");
  aux1 = 12'd50;
  settle(20);
  check_eq(lock, 4'b1101, "lock status");
  aux1 = 12'd150;
  settle(20);
  for (j = 0; j < 4; j = j + 1) begin
    rd(32'h230 + 4 * j, d3);
    $sformat(ctx, "5. unlocks of PID %0d", j);
    check_eq(d3, (j == 2) ? 1 : 2, "unlocks");
  end
  // The lock status outputs, per PID
  $sformat(ctx, "5. lock status outputs 0 and 2");
  wr(32'h000, 32'h50F0_0000);
  settle(10);
  check_eq(lock, 4'b0101, "lock status");
  wr(32'h000, 32'hF0F0_0000);

  // 6. Integrators and D, logged for the comparison between runs
  reset_all;
  wr(32'h000, 32'hF0F0_0000);
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h0a0 + 4 * k, 1 << 12);
    wr(32'h1a0 + 4 * k, 1 << 12);
    wr(32'h030 + 4 * k, (1 + k) << 20);
    wr(32'h130 + 4 * k, (5 + 3 * k) << 20);
  end
  // 6a. I
  for (c = 0; c < 6; c = c + 1) begin
    set_modes(combos[c]);
    settle(20);
    wr(32'h000, 32'hF0F0_000F);
    wr(32'h000, 32'hF0F0_0000);
    for (n = 0; n < 5; n = n + 1) begin
      settle(50);
      $display("LOG 6a %b %0d %0d %0d", combos[c][3:0], n, $signed(out_a), $signed(out_b));
    end
  end
  // 6b. II in set 2 only, and KG 0 in set 2 of PID 1
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h030 + 4 * k, (1 + k) << 18);
    wr(32'h130 + 4 * k, (1 + k) << 18);
    wr(32'h190 + 4 * k, (1 + k) << 20);
  end
  wr(32'h1a4, 0);
  for (c = 0; c < 6; c = c + 1) begin
    set_modes(combos[c]);
    settle(20);
    wr(32'h000, 32'hF0F0_000F);
    wr(32'h000, 32'hF0F0_0000);
    for (n = 0; n < 5; n = n + 1) begin
      settle(60);
      $display("LOG 6b %b %0d %0d %0d", combos[c][3:0], n, $signed(out_a), $signed(out_b));
    end
  end
  // 6c. D on the measurement: a step of the inputs by 50 (the integrators held at 0)
  wr(32'h000, 32'hF0F0_000F);
  for (k = 0; k < 4; k = k + 1) begin
    wr(32'h0a0 + 4 * k, 1 << 12);
    wr(32'h1a0 + 4 * k, 1 << 12);
    wr(32'h040 + 4 * k, (1 + k) << 8);
    wr(32'h140 + 4 * k, (5 + 3 * k) << 8);
  end
  for (c = 0; c < 6; c = c + 1) begin
    $sformat(ctx, "6c. D, sets %b", combos[c][3:0]);
    set_modes(combos[c]);
    settle(40);
    @(negedge clk);
    in_a = in_a + 14'd50;
    in_b = in_b + 14'd50;
    peak_a = 0;
    peak_b = 0;
    for (n = 0; n < 16; n = n + 1) begin
      @(negedge clk);
      if ($signed(out_a) > peak_a) peak_a = $signed(out_a);
      if ($signed(out_b) > peak_b) peak_b = $signed(out_b);
      $display("LOG 6c %b %0d %0d %0d", combos[c][3:0], n, $signed(out_a), $signed(out_b));
    end
    check_eq(peak_a, 50 * ((combos[c][0] ? 5 : 1) + (combos[c][1] ? 8 : 2)), "D peak OUT1");
    check_eq(peak_b, 50 * ((combos[c][2] ? 11 : 3) + (combos[c][3] ? 14 : 4)), "D peak OUT2");
    settle(20);
  end

  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks)", errors, checks);
  $finish;
end
endmodule
