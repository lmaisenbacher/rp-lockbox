/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Self-checking testbench of the scope's input filter: rtl/red_pitaya_dfilt1.sv
 * against tbn/ref/red_pitaya_dfilt1_ref.sv, the filter before its recursive
 * stages were restructured for timing. The output and the states of those
 * stages must agree in every clock cycle: with the calibration coefficients the API
 * sets, with random and extreme coefficients, while the states wrap around, and
 * across a reset. Prints PASS or FAIL with the number of failed checks.
 */
`timescale 1ns / 1ps

module red_pitaya_dfilt1_tb;

reg clk = 1'b0;
always #4 clk = ~clk;

reg                 rstn = 1'b0;
reg signed [14-1:0] dat  = 14'sd0;
reg signed [18-1:0] aa   = 18'sd0;
reg signed [25-1:0] bb   = 25'sd0;
reg signed [25-1:0] kk   = 25'sd0;
reg signed [25-1:0] pp   = 25'sd0;
wire signed [14-1:0] out_new, out_ref;

red_pitaya_dfilt1 dut (
  .adc_clk_i (clk), .adc_rstn_i (rstn), .adc_dat_i (dat), .adc_dat_o (out_new),
  .cfg_aa_i (aa), .cfg_bb_i (bb), .cfg_kk_i (kk), .cfg_pp_i (pp));

red_pitaya_dfilt1_ref orig (
  .adc_clk_i (clk), .adc_rstn_i (rstn), .adc_dat_i (dat), .adc_dat_o (out_ref),
  .cfg_aa_i (aa), .cfg_bb_i (bb), .cfg_kk_i (kk), .cfg_pp_i (pp));

//---------------------------------------------------------------------------------
// Every cycle: the output and the recursive states

integer errors = 0;
integer checks = 0;
integer wraps  = 0;   // cycles in which the reference's 49-bit sum leaves 48 bits
integer moving = 0;   // cycles in which the state changes

always @(negedge clk) begin
  checks = checks + 1;
  if ((out_new !== out_ref) || (dut.r3_reg !== orig.r3_reg_dsp1)
   || (dut.r3_reg !== orig.r3_reg_dsp2) || (dut.r3_shr !== orig.r3_shr)
   || (dut.r4_reg !== orig.r4_reg)) begin
    if (errors < 5)
      $display("  FAIL: out %0d / %0d, r3 %0d / %0d, r3 >>> 8 %0d / %0d (t = %0t ns)",
               out_new, out_ref, dut.r3_reg, orig.r3_reg_dsp1, dut.r3_shr,
               orig.r3_shr, $time);
    errors = errors + 1;
  end
  if (orig.r3_sum[49-1] != orig.r3_sum[48-1])
    wraps = wraps + 1;
  if (orig.r3_sum[48-1:25] != orig.r3_reg_dsp1)
    moving = moving + 1;
end

//---------------------------------------------------------------------------------
// Stimulus

// `n` cycles of the input: 0 = random over the full scale, 1 = a square wave of
// amplitude `amp` with a little noise, 2 = the constant `amp`
task run;
  input integer n;
  input integer kind;
  input integer amp;
  integer k;
  begin
    for (k = 0; k < n; k = k + 1) begin
      @(posedge clk);
      #1;
      case (kind)
        0: dat = $random;
        1: dat = (((k / 500) % 2) ? amp : -amp) + ($random % 8);
        default: dat = amp;
      endcase
    end
  end
endtask

task coefficients;
  input integer a;
  input integer b;
  input integer p;
  input integer g;
  begin
    @(posedge clk);
    #1;
    aa = a;
    bb = b;
    pp = p;
    kk = g;
  end
endtask

integer i;

initial begin
  $display("red_pitaya_dfilt1_tb");
  repeat (5) @(posedge clk);
  #1 rstn = 1'b1;

  // The coefficients the API sets for the two input gains
  $display("1. Calibration coefficients");
  coefficients('h7D93, 'h437C7, 'h2666, 'hd9999a);
  run(20000, 1, 4000);
  run(20000, 0, 0);
  coefficients('h4C5F, 'h2F38B, 'h2666, 'hd9999a);
  run(20000, 1, 6000);
  run(20000, 0, 0);

  $display("2. Random coefficients");
  for (i = 0; i < 60; i = i + 1) begin
    coefficients($random, $random, $random, $random);
    run(3000, i % 3, $random % 8192);
  end

  $display("3. Extreme coefficients and inputs");
  coefficients(-(1 << 17), (1 << 24) - 1, (1 << 24) - 1, (1 << 24) - 1);
  run(5000, 2, 8191);
  run(5000, 2, -8192);
  run(5000, 0, 0);
  coefficients((1 << 17) - 1, -(1 << 24), -(1 << 24), -(1 << 24));
  run(5000, 2, -8192);
  run(5000, 0, 0);
  for (i = -2; i <= 2; i = i + 1) begin
    coefficients(i, (1 << 24) - 1, 0, 'h7fffff);
    run(3000, 2, (i % 2) ? 8191 : -8192);
    run(3000, 0, 0);
  end

  $display("4. Reset while running");
  run(100, 0, 0);
  #1 rstn = 1'b0;
  run(10, 0, 0);
  #1 rstn = 1'b1;
  coefficients('h7D93, 'h437C7, 'h2666, 'hd9999a);
  run(5000, 1, 3000);

  $display("   cycles %0d, of them with the state moving %0d, wrapping %0d", checks, moving,
           wraps);
  if (moving < checks / 2) begin
    $display("  FAIL: the state hardly moved");
    errors = errors + 1;
  end
  if (wraps == 0) begin
    $display("  FAIL: no wrap-around exercised");
    errors = errors + 1;
  end
  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks failed)", errors, checks);
  $finish;
end

endmodule
