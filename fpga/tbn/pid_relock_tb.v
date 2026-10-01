/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Self-checking testbench of the relock sweep (pid_relock) against the module
 * as it was in 1.3.2 (tbn/ref/pid_relock_ref.v). The step size is 17.18 times
 * the slew rate in V/s.
 *   1. Step sizes below 2^15 (slew rates below 1907 V/s): the outputs equal
 *      the reference's, cycle by cycle, through sweeping, the rails, hold,
 *      locking with the return to zero, and losing the lock while railed.
 *   2. Larger step sizes, up to the largest the register holds: the sweep
 *      starts at 256 times the step size, doubles up to full scale, reaches
 *      both ends of the output range, never wraps, holds, and returns to zero
 *      when locked.
 *
 * Runs in Icarus Verilog and Vivado xsim (see fpga/sim/red_pitaya_relock).
 * Prints PASS or FAIL with the number of failed checks.
 */
`timescale 1ns / 1ps

module pid_relock_tb;

reg clk = 1'b0;
always #4 clk = ~clk;

reg         on       = 1'b0;
reg  [11:0] min_val  = 12'd100;
reg  [11:0] max_val  = 12'd200;
reg  [23:0] stepsize = 24'd0;
reg  [11:0] signal   = 12'd50;   // outside the window: unlocked
reg  [1:0]  railed   = 2'b00;
reg         hold     = 1'b0;

wire               hold_dut, locked_dut, clear_dut, in_window_dut;
wire signed [13:0] out_dut;
wire               hold_ref, locked_ref, clear_ref;
wire signed [13:0] out_ref;

pid_relock dut (
  .clk_i       (clk         ),
  .on_i        (on          ),
  .min_val_i   (min_val     ),
  .max_val_i   (max_val     ),
  .stepsize_i  (stepsize    ),
  .signal_i    (signal      ),
  .railed_i    (railed      ),
  .hold_i      (hold        ),
  .freeze_i    (1'b0        ),
  .hold_o      (hold_dut    ),
  .locked_o    (locked_dut  ),
  .in_window_o (in_window_dut),
  .clear_o     (clear_dut   ),
  .signal_o    (out_dut     )
);

pid_relock_ref uref (
  .clk_i       (clk         ),
  .on_i        (on          ),
  .min_val_i   (min_val     ),
  .max_val_i   (max_val     ),
  .stepsize_i  (stepsize    ),
  .signal_i    (signal      ),
  .railed_i    (railed      ),
  .hold_i      (hold        ),
  .hold_o      (hold_ref    ),
  .locked_o    (locked_ref  ),
  .clear_o     (clear_ref   ),
  .signal_o    (out_ref     )
);

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

task cycles;
  input integer n;
  integer k;
  begin
    for (k = 0; k < n; k = k + 1)
      @(negedge clk);
  end
endtask

// Relock off and on again with step size s, unlocked
task restart;
  input [23:0] s;
  begin
    on = 1'b0; stepsize = s; signal = 12'd50; railed = 2'b00; hold = 1'b0;
    cycles(3);
    on = 1'b1;
  end
endtask

// Cycle-by-cycle comparison with the reference while `compare` is set
reg     compare    = 1'b0;
integer mismatches = 0;
always @(negedge clk)
  if (compare && ((out_dut !== out_ref) || (hold_dut !== hold_ref)
                  || (locked_dut !== locked_ref) || (clear_dut !== clear_ref)))
    mismatches = mismatches + 1;

// The sweep while `watch` is set: its amplitudes, the ends of the output range
// reached (by the module under test and by the reference), and the largest
// change of the output from one cycle to the next
localparam signed [63:0] AMP_MAX = 64'h1FFF << 18;
reg               watch = 1'b0;
reg signed [63:0] amp_prev, amp_now, amp_expected;
integer           amp_count, amp_errors, max_delta;
reg               seen_top, seen_bottom, ref_top, ref_bottom;
reg signed [13:0] out_prev;

task start_watch;
  begin
    amp_prev = 0; amp_count = 0; amp_errors = 0; max_delta = 0;
    seen_top = 1'b0; seen_bottom = 1'b0; ref_top = 1'b0; ref_bottom = 1'b0;
    out_prev = out_dut;
    watch = 1'b1;
  end
endtask

always @(negedge clk) begin
  if (watch) begin
    amp_now = dut.sweep_amplitude_f;
    if (amp_now != amp_prev) begin
      if (amp_count == 0)
        amp_expected = 256 * stepsize;
      else
        amp_expected = 2 * amp_prev;
      if ((amp_now != amp_expected) || ((amp_count > 0) && (amp_prev >= AMP_MAX)))
        amp_errors = amp_errors + 1;
      amp_count = amp_count + 1;
      amp_prev = amp_now;
    end
    // the ends of the range: 8191 (14'h1FFF) and -8192 (14'h2000)
    if (out_dut == 14'sh1FFF) seen_top    = 1'b1;
    if (out_dut == 14'sh2000) seen_bottom = 1'b1;
    if (out_ref == 14'sh1FFF) ref_top     = 1'b1;
    if (out_ref == 14'sh2000) ref_bottom  = 1'b1;
    if (out_dut - out_prev > max_delta)
      max_delta = out_dut - out_prev;
    if (out_prev - out_dut > max_delta)
      max_delta = out_prev - out_dut;
    out_prev = out_dut;
  end
end

reg [23:0]        small_steps [0:2];
reg [23:0]        large_steps [0:7];
reg [23:0]        s;
reg signed [13:0] out_held;
integer           i, n, limit;

initial begin
  small_steps[0] = 24'd1000;      //   58 V/s
  small_steps[1] = 24'd8590;      //  500 V/s
  small_steps[2] = 24'd32767;     // 1907 V/s, the largest the old sweep handled
  large_steps[0] = 24'd32768;     // 1907 V/s, the old start amplitude negative
  large_steps[1] = 24'd34360;     // 2000 V/s
  large_steps[2] = 24'd65536;     // 3815 V/s, the old start amplitude 0
  large_steps[3] = 24'd85899;     // 5000 V/s
  large_steps[4] = 24'd1717987;   // 100 kV/s
  large_steps[5] = 24'd8387583;   // 488 kV/s, the doubled amplitude at the end of the range
  large_steps[6] = 24'd10307922;  // 600 kV/s, the old step negative
  large_steps[7] = 24'hFFFFFF;    // 977 kV/s, the largest step size

  //-------------------------------------------------------------------------------
  $display("1. Step sizes below 2^15: equal to the reference");
  for (i = 0; i < 3; i = i + 1) begin
    s = small_steps[i];
    restart(s);
    mismatches = 0;
    compare = 1'b1;
    cycles(200000);                                  // sweeping
    railed = 2'b10; cycles(50);  railed = 2'b00;    // upper rail
    cycles(20000);
    railed = 2'b01; cycles(50);  railed = 2'b00;    // lower rail
    cycles(20000);
    hold = 1'b1;    cycles(1000); hold = 1'b0;
    cycles(20000);
    signal = 12'd150; cycles(60000);                 // locked: back towards zero
    railed = 2'b10; signal = 12'd50; cycles(5);      // lock lost while railed
    railed = 2'b00; cycles(50000);
    compare = 1'b0;
    $display("   step %0d (%0.0f V/s): %0d differences", s, s / 17.179869, mismatches);
    check(mismatches == 0, "1: outputs equal the reference");
  end

  //-------------------------------------------------------------------------------
  $display("2. Larger step sizes: full-scale sweep, no wrap, back to zero");
  for (i = 0; i < 8; i = i + 1) begin
    s = large_steps[i];
    // Long enough for the doublings and two full sweeps
    limit = ((64'd1 << 36) / s) + 1000;
    restart(s);
    @(negedge clk);
    start_watch;
    n = 0;
    while (!(seen_top && seen_bottom) && (n < limit)) begin
      @(negedge clk);
      n = n + 1;
    end
    // Two more periods of the sweep at its final amplitude, which can run up
    // to the end of the internal range
    cycles(((64'd1 << 35) / s) + 100);
    check(amp_prev >= AMP_MAX, "2: the amplitude doubled up to full scale");
    // Hold freezes the sweep
    hold = 1'b1;
    cycles(2);
    out_held = out_dut;
    cycles(50);
    check(out_dut == out_held, "2: hold freezes the sweep");
    hold = 1'b0;
    watch = 1'b0;
    $display("   step %0d (%0.0f V/s): %0d amplitudes, both ends after %0d cycles, largest change %0d; 1.3.2: %0s",
             s, s / 17.179869, amp_count, n, max_delta,
             (ref_top && ref_bottom) ? "both ends" : "not both ends");
    check(amp_count >= 1, "2: the sweep started");
    check(amp_errors == 0, "2: amplitudes 256 * step, doubled up to full scale");
    check(seen_top && seen_bottom, "2: the sweep reaches both ends of the range");
    check(max_delta <= (s >> 18) + 1, "2: the output never wraps");
    // Locked: back to zero
    signal = 12'd150;
    n = 0;
    while (!((dut.state_f == 2'b00) && (out_dut == 0)) && (n < limit)) begin
      @(negedge clk);
      n = n + 1;
    end
    check(n < limit, "2: back to zero when locked");
  end

  //-------------------------------------------------------------------------------
  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks failed)", errors, checks);
  $finish;
end

endmodule
