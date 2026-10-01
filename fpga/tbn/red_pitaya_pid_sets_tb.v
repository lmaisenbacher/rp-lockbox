/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Self-checking testbench of the PID module with two parameter sets
 * (red_pitaya_pid) against the module as it was before
 * (tbn/ref/red_pitaya_pid_ref, a frozen copy). Both receive the same bus
 * writes; the reference ignores the registers it does not have.
 *
 * Checks:
 *   1. KG = 1, P + I + II: the new output equals the reference three clock
 *      cycles later, bit for bit.
 *   2. D only, KG = 1: within 1 LSB of the reference two clock cycles later
 *      (D on the measurement rounds once instead of twice, and its path got
 *      one register less than P).
 *   3. P only, KG != 1, static: exactly the products' arithmetic, within
 *      ceil(KG) LSB of the reference; saturation where the reference wraps.
 *   4. Closed loop, KG = 1.72, P + I: both loops settle to the same output.
 *   5. Switching: KG halved, KI changed, set point and KD changed: no step
 *      beyond the expected P change; latency from the input to the gains.
 *   6. Modes 0, 1 and 3, the input filter.
 *   7. Lock status equals the reference with set 0; holdoff: no false drop,
 *      the window-left flag, the drop when the holdoff ends, locking during
 *      the holdoff.
 *   8. Register readback, reserved addresses, feature ID, external reset
 *      through the synchronizer.
 *   9. Event counters: set switches, holdoffs with the input outside the window, holdoffs
 *      ending outside the window, unlocks (every one, none while held);
 *      their addresses.
 *
 * Runs in Icarus Verilog and Vivado xsim (see fpga/sim/red_pitaya_pid_sets).
 * Prints PASS or FAIL with the number of failed checks.
 */
`timescale 1ns / 1ps

module red_pitaya_pid_sets_tb;

//---------------------------------------------------------------------------------
// Clock, reset, bus

reg clk = 1'b0;
always #4 clk = ~clk;
reg rstn = 1'b0;

reg  [32-1:0] sys_addr  = 32'h0;
reg  [32-1:0] sys_wdata = 32'h0;
reg           sys_wen   = 1'b0;
reg           sys_ren   = 1'b0;
wire [32-1:0] dut_rdata, ref_rdata;
wire          dut_ack, ref_ack, dut_err, ref_err;

//---------------------------------------------------------------------------------
// Signals

reg  signed [14-1:0] dat_dut = 14'sd0;
reg  signed [14-1:0] dat_ref = 14'sd0;
reg         [ 2-1:0] railed = 2'b00;
reg         [12-1:0] relock_a = 12'd0;
reg         [ 8-1:0] dio_p = 8'h0;
reg         [ 8-1:0] dio_n = 8'h0;
wire        [14-1:0] dut_out_a, dut_out_b, ref_out_a, ref_out_b;
wire        [ 4-1:0] dut_lock, ref_lock;
wire signed [14-1:0] dut_o = dut_out_a;
wire signed [14-1:0] ref_o = ref_out_a;

red_pitaya_pid dut (
  .clk_i          (clk       ),
  .rstn_i         (rstn      ),
  .dat_a_i        (dat_dut   ),
  .dat_b_i        (14'd0     ),
  .railed_a_i     (railed    ),
  .railed_b_i     (2'b00     ),
  .relock_a_i     (relock_a  ),
  .relock_b_i     (12'd0     ),
  .relock_c_i     (12'd0     ),
  .relock_d_i     (12'd0     ),
  .out_a_center_i (14'd0     ),
  .out_b_center_i (14'd0     ),
  .dio_p_i        (dio_p     ),
  .dio_n_i        (dio_n     ),
  .dat_a_o        (dut_out_a ),
  .dat_b_o        (dut_out_b ),
  .lock_status_o  (dut_lock  ),
  .sys_addr       (sys_addr  ),
  .sys_wdata      (sys_wdata ),
  .sys_wen        (sys_wen   ),
  .sys_ren        (sys_ren   ),
  .sys_rdata      (dut_rdata ),
  .sys_err        (dut_err   ),
  .sys_ack        (dut_ack   )
);

red_pitaya_pid_ref u_ref (
  .clk_i          (clk       ),
  .rstn_i         (rstn      ),
  .dat_a_i        (dat_ref   ),
  .dat_b_i        (14'd0     ),
  .railed_a_i     (railed    ),
  .railed_b_i     (2'b00     ),
  .relock_a_i     (relock_a  ),
  .relock_b_i     (12'd0     ),
  .relock_c_i     (12'd0     ),
  .relock_d_i     (12'd0     ),
  .out_a_center_i (14'd0     ),
  .out_b_center_i (14'd0     ),
  .reset_a_i      (1'b0      ),
  .reset_d_i      (1'b0      ),
  .dat_a_o        (ref_out_a ),
  .dat_b_o        (ref_out_b ),
  .lock_status_o  (ref_lock  ),
  .sys_addr       (sys_addr  ),
  .sys_wdata      (sys_wdata ),
  .sys_wen        (sys_wen   ),
  .sys_ren        (sys_ren   ),
  .sys_rdata      (ref_rdata ),
  .sys_err        (ref_err   ),
  .sys_ack        (ref_ack   )
);

//---------------------------------------------------------------------------------
// Register map (PID11 = index 0; set 1 at +0x100)

localparam A_CONF   = 32'h000;
localparam A_CONF2  = 32'h004;
localparam A_SP     = 32'h010;
localparam A_KP     = 32'h020;
localparam A_KI     = 32'h030;
localparam A_KD     = 32'h040;
localparam A_MIN    = 32'h050;
localparam A_MAX    = 32'h060;
localparam A_STEP   = 32'h070;
localparam A_SRC    = 32'h080;
localparam A_KII    = 32'h090;
localparam A_KG     = 32'h0a0;
localparam A_EXTSRC = 32'h0b0;
localparam A_PSET   = 32'h0c0;
localparam A_HOLD   = 32'h0d0;
localparam A_STATUS = 32'h0f0;
localparam A_ID     = 32'h0fc;
localparam SET1     = 32'h100;
localparam A_CNT    = 32'h200;  // + 0x10 * counter + 4 * PID

// conf for PID11 alone: lock status output, output enabled, others in reset
localparam [31:0] CONF_BASE = {4'b0001, 4'b0000, 4'b0001, 4'b0000, 4'b0000, 4'b0000, 4'b0000, 4'b1110};
localparam [31:0] CONF_INV  = 32'h0000_0010;  // PID11 inverted
localparam [31:0] CONF_REL  = 32'h0001_0000;  // PID11 relock enabled
localparam [31:0] CONF_IRST = 32'h0000_0001;  // PID11 integrator reset

//---------------------------------------------------------------------------------
// Checks

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

task wr;
  input [31:0] a;
  input [31:0] d;
  begin
    @(negedge clk);
    sys_addr  = a;
    sys_wdata = d;
    sys_wen   = 1'b1;
    @(negedge clk);
    sys_wen   = 1'b0;
  end
endtask

task rd;
  input  [31:0] a;
  output [31:0] d;
  integer k;
  begin
    @(negedge clk);
    sys_addr = a;
    sys_ren  = 1'b1;
    @(negedge clk);
    sys_ren  = 1'b0;
    // The data is taken with the acknowledge, as the bus does
    k = 0;
    while (!dut_ack && (k < 8)) begin
      @(negedge clk);
      k = k + 1;
    end
    check(dut_ack, "bus: read acknowledged");
    d = dut_rdata;
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

// Gains of one set of PID11, register units
task set_gains;
  input [31:0] set;
  input integer sp;
  input integer kp;
  input integer ki;
  input integer kd;
  input integer kii;
  input integer kg;
  begin
    wr(A_SP  + set, sp & 32'h3fff);
    wr(A_KP  + set, kp);
    wr(A_KI  + set, ki);
    wr(A_KD  + set, kd);
    wr(A_KII + set, kii);
    wr(A_KG  + set, kg);
  end
endtask

//---------------------------------------------------------------------------------
// Stimulus: 0 = constant, 1 = triangle and noise, 2 = closed loop

integer stim_mode = 0;
integer cval      = 0;
integer tri_amp   = 0;
integer tri_per   = 2000;
integer noise_on  = 0;
integer phase     = 0;
integer dist      = 0;
integer y_dut     = 0;  // plant states, 1/16 LSB
integer y_ref     = 0;
integer tri_val;
integer noise_val;
reg [16-1:0] lfsr = 16'hace1;

function signed [14-1:0] clamp14;
  input integer v;
  begin
    if (v > 8191)
      clamp14 = 14'sd8191;
    else if (v < -8192)
      clamp14 = -14'sd8192;
    else
      clamp14 = v;
  end
endfunction

always @(posedge clk) begin
  lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
  phase <= (phase + 1 >= tri_per) ? 0 : phase + 1;
  tri_val = (phase < tri_per/2) ? (-tri_amp + (4*tri_amp*phase)/tri_per)
                                : (3*tri_amp - (4*tri_amp*phase)/tri_per);
  noise_val = noise_on ? ($signed({1'b0, lfsr[3:0]}) - 8) : 0;
  case (stim_mode)
    0: begin
      dat_dut <= clamp14(cval);
      dat_ref <= clamp14(cval);
    end
    1: begin
      dat_dut <= clamp14(cval + tri_val + noise_val);
      dat_ref <= clamp14(cval + tri_val + noise_val);
    end
    default: begin
      // first-order plant with unity gain and a time constant of 8 cycles
      y_dut   <= y_dut + ((16*dut_o - y_dut) >>> 3);
      y_ref   <= y_ref + ((16*ref_o - y_ref) >>> 3);
      dat_dut <= clamp14((y_dut >>> 4) + dist);
      dat_ref <= clamp14((y_ref >>> 4) + dist);
    end
  endcase
end

// Outputs one to three cycles back
reg signed [14-1:0] ref_o_q   = 14'sd0;
reg signed [14-1:0] ref_o_qq  = 14'sd0;
reg signed [14-1:0] ref_o_qqq = 14'sd0;
reg signed [14-1:0] dut_o_q  = 14'sd0;
always @(posedge clk) begin
  ref_o_q  <= ref_o;
  ref_o_qq <= ref_o_q;
  ref_o_qqq <= ref_o_qq;
  dut_o_q  <= dut_o;
end

//---------------------------------------------------------------------------------
// Monitors, enabled by the tests

reg     cmp_delay1 = 1'b0;   // check 1: dut_o == ref_o three cycles back
reg     cmp_d      = 1'b0;   // check 2: |dut_o - ref_o two cycles back| <= 1
reg     cmp_lock   = 1'b0;   // check 7: dut_lock == ref_lock
reg     step_on    = 1'b0;   // largest output step, see max_step
integer max_step   = 0;
integer max_abs    = 0;      // largest output magnitude during check 1
integer mon_fail   = 0;
integer d_out;

always @(negedge clk) begin
  if (cmp_delay1 && ((dut_o > max_abs) || (-dut_o > max_abs)))
    max_abs = (dut_o > 0) ? dut_o : -dut_o;
  if (cmp_delay1 && (dut_o !== ref_o_qqq)) begin
    if (mon_fail < 5)
      $display("  delayed output differs: dut %0d ref %0d (t = %0t ns)", dut_o, ref_o_qqq, $time);
    mon_fail = mon_fail + 1;
  end
  if (cmp_d && ((dut_o - ref_o_qq > 1) || (ref_o_qq - dut_o > 1))) begin
    if (mon_fail < 5)
      $display("  D output differs: dut %0d ref %0d (t = %0t ns)", dut_o, ref_o_qq, $time);
    mon_fail = mon_fail + 1;
  end
  if (cmp_lock && (dut_lock[0] !== ref_lock[0])) begin
    if (mon_fail < 5)
      $display("  lock status differs: dut %0b ref %0b (t = %0t ns)", dut_lock[0], ref_lock[0], $time);
    mon_fail = mon_fail + 1;
  end
  if (step_on) begin
    d_out = dut_o - dut_o_q;
    if (d_out < 0)
      d_out = -d_out;
    if (d_out > max_step)
      max_step = d_out;
  end
end

// Registers that stand in for a combinational result must equal it in every
// cycle, in all PIDs: the sign of the second integrator's product (taken from
// the factors) and the holdoff flag (holdoff_count != 0). The counts of the
// cases met show that the tests reach them.
integer inv_fail     = 0;
integer n_kii_pos    = 0;
integer n_kii_neg    = 0;
integer n_kii_zero   = 0;  // the product is zero while the first integrator is not
integer n_holdoff_on = 0;
// The integrator adds its product clamped: with the integrator, the clamped
// product must give the same saturation, or else the same sum, as the full one
// (the full one is kept from the cycle before, when it was ki_mult_r), and the
// anti-windup's sign registers must carry the full product's sign
integer n_clamped    = 0;
integer n_int_sat    = 0;
localparam signed [64-1:0] INT_RANGE = 64'sd1 <<< 48;  // the integrator's range: +-2^48

genvar gk;
generate for (gk = 0; gk < 4; gk = gk + 1) begin: g_inv
  reg signed [64-1:0] ki_full = 64'sd0;
  reg signed [64-1:0] sum_full;
  reg signed [64-1:0] sum_clamped;
  integer             sat_full;
  integer             sat_clamped;
  always @(negedge clk) begin
    if ((^dut.g_pid[gk].i_pid.ki_mult_q !== 1'bx) && (^ki_full !== 1'bx)) begin
      sum_full    = ki_full + dut.g_pid[gk].i_pid.int_reg;
      sum_clamped = dut.g_pid[gk].i_pid.ki_mult_q + dut.g_pid[gk].i_pid.int_reg;
      sat_full    = (sum_full >= INT_RANGE) ? 1 : ((sum_full < -INT_RANGE) ? -1 : 0);
      sat_clamped = (sum_clamped >= INT_RANGE) ? 1 : ((sum_clamped < -INT_RANGE) ? -1 : 0);
      if ((sat_full != sat_clamped) || ((sat_full == 0) && (sum_full != sum_clamped))
       || (dut.g_pid[gk].i_pid.int_sum_pos !== (sat_clamped == 1))
       || (dut.g_pid[gk].i_pid.int_sum_neg !== (sat_clamped == -1))
       || (dut.g_pid[gk].i_pid.ki_mult_neg !== (ki_full < 0))
       || (dut.g_pid[gk].i_pid.ki_mult_pos !== (ki_full > 0))) begin
        if (inv_fail < 5)
          $display("  PID %0d: clamped integrator product differs (t = %0t ns)", gk, $time);
        inv_fail = inv_fail + 1;
      end
      if (ki_full != dut.g_pid[gk].i_pid.ki_mult_q)
        n_clamped = n_clamped + 1;
      if (sat_full != 0)
        n_int_sat = n_int_sat + 1;
    end
    ki_full = dut.g_pid[gk].i_pid.ki_mult_r;
  end
  always @(negedge clk) begin
    if ((dut.g_pid[gk].i_pid.kii_mult_pos !== (dut.g_pid[gk].i_pid.kii_mult > 0))
     || (dut.g_pid[gk].i_pid.kii_mult_neg !== (dut.g_pid[gk].i_pid.kii_mult < 0))) begin
      if (inv_fail < 5)
        $display("  PID %0d: product sign differs (t = %0t ns)", gk, $time);
      inv_fail = inv_fail + 1;
    end
    if (dut.holdoff_on[gk] !== (dut.holdoff_count[gk] != 32'd0)) begin
      if (inv_fail < 5)
        $display("  PID %0d: holdoff flag differs from the count (t = %0t ns)", gk, $time);
      inv_fail = inv_fail + 1;
    end
    if (dut.g_pid[gk].i_pid.kii_mult > 0)
      n_kii_pos = n_kii_pos + 1;
    if (dut.g_pid[gk].i_pid.kii_mult < 0)
      n_kii_neg = n_kii_neg + 1;
    if ((dut.g_pid[gk].i_pid.kii_mult == 0) && (dut.g_pid[gk].i_pid.int_shr != 0))
      n_kii_zero = n_kii_zero + 1;
    if (dut.holdoff_on[gk])
      n_holdoff_on = n_holdoff_on + 1;
  end
end
endgenerate

//---------------------------------------------------------------------------------
// Tests

reg  [31:0] r;
reg  [31:0] cnt_base [0:3];  // PID11's counters before check 9
integer     i;
integer     e;
integer     model;
integer     kpg;
integer     t_edge;
integer     t_sw;
integer     t_drop;
integer     out_before;
integer     lock_drops;
integer     hold_seen;
reg signed [63:0] prod;

// Start PID11 from a clean state with the given conf, error zero
task restart;
  input [31:0] conf;
  begin
    stim_mode = 0;
    cval = 0;
    wr(A_CONF, CONF_BASE | conf | CONF_IRST);
    cycles(20);
    wr(A_CONF, CONF_BASE | conf);
    cycles(5);
  end
endtask

initial begin
  $display("red_pitaya_pid_sets_tb");
  cycles(10);
  rstn = 1'b1;
  cycles(10);

  //-------------------------------------------------------------------------------
  $display("1. KG = 1, P + I + II: equal to the reference three cycles later");
  // A triangle with an offset: the integrators drift into saturation, the
  // output saturates on the peaks
  set_gains(0, 0, 8192, 1 << 23, 0, 1 << 14, 4096);
  restart(0);
  tri_amp = 1000; tri_per = 2000; noise_on = 1;
  stim_mode = 1;
  cval = 20;
  max_abs = 0;
  mon_fail = 0;
  cmp_delay1 = 1'b1;
  cycles(40000);
  cmp_delay1 = 1'b0;
  check(mon_fail == 0, "1: output equals the reference three cycles later");
  check(max_abs >= 8191, "1: the output reaches saturation");
  $display("   largest output %0d, I %0d, II %0d", max_abs,
           dut.g_pid[0].i_pid.int_shr, dut.g_pid[0].i_pid.iint_shr);
  check(dut.g_pid[0].i_pid.iint_shr == 16383, "1: the second integrator saturated");
  noise_on = 0;
  cval = 0;

  //-------------------------------------------------------------------------------
  $display("2. D only, KG = 1: within 1 LSB of the reference two cycles later");
  set_gains(0, 0, 0, 0, 3200, 0, 4096);
  restart(0);
  tri_amp = 300; tri_per = 2000; noise_on = 1;
  stim_mode = 1;
  cycles(20);
  mon_fail = 0;
  cmp_d = 1'b1;
  cycles(10000);
  cmp_d = 1'b0;
  check(mon_fail == 0, "2: D output within 1 LSB of the reference");
  noise_on = 0;

  //-------------------------------------------------------------------------------
  $display("3. P only, KG != 1: products' arithmetic, saturation");
  // KG = 0.88 and 1.72
  for (i = 0; i < 2; i = i + 1) begin
    if (i == 0)
      set_gains(0, 100, 3000, 0, 0, 0, 3604);
    else
      set_gains(0, 100, 6000, 0, 0, 0, 7045);
    restart(0);
    kpg = ((i == 0 ? 3000*3604 : 6000*7045) + 32) >>> 6;
    for (e = -8000; e <= 8000; e = e + 337) begin
      cval = e + 100;
      cycles(14);
      prod = e * kpg;
      model = prod >>> 18;
      if (model > 8191) model = 8191;
      if (model < -8192) model = -8192;
      check(dut_o == model, "3: P output equals the products' arithmetic");
      check((ref_o - model <= (i == 0 ? 1 : 2)) && (model - ref_o <= (i == 0 ? 1 : 2)),
            "3: reference within ceil(KG) LSB");
    end
  end
  // largest gains: any error saturates (the reference wraps)
  set_gains(0, 0, 24'hffffff, 0, 0, 0, 24'hffffff);
  restart(0);
  cval = 1;  cycles(20); check(dut_o == 8191,  "3: largest gain, +1 LSB saturates");
  cval = -1; cycles(20); check(dut_o == -8192, "3: largest gain, -1 LSB saturates");
  cval = 0;  cycles(20); check(dut_o == 0,     "3: largest gain, zero error");

  //-------------------------------------------------------------------------------
  $display("4. Closed loop, KG = 1.72, P + I: both loops settle alike");
  set_gains(0, 0, 476, 312000, 0, 0, 7045);
  restart(CONF_INV);
  y_dut = 0; y_ref = 0; dist = 1000;
  stim_mode = 2;
  cycles(30000);
  check((dat_dut <= 1) && (dat_dut >= -1), "4: new loop settled to the set point");
  check((dat_ref <= 1) && (dat_ref >= -1), "4: reference loop settled to the set point");
  check((dut_o - ref_o <= 2) && (ref_o - dut_o <= 2), "4: outputs agree");
  $display("   outputs: new %0d, reference %0d", dut_o, ref_o);
  stim_mode = 0; dist = 0;

  //-------------------------------------------------------------------------------
  $display("5. Switching");
  // mode 2, input DIO7_P (index 2)
  wr(A_PSET, 32'h0000_0022);
  // a) KG halved, integrator large: no jump
  set_gains(0,   0, 1024, 1 << 22, 0, 0, 4096);
  set_gains(SET1, 0, 1024, 1 << 22, 0, 0, 2048);
  restart(0);
  cval = 8;
  cycles(40000);
  out_before = dut_o;
  max_step = 0; step_on = 1'b1;
  dio_p[7] = 1'b1;
  cycles(100);
  step_on = 1'b0;
  check(out_before > 4000, "5a: integrator built up");
  check(max_step <= 2, "5a: KG halved, no output step");
  check(dut_o > out_before - 5, "5a: output continues from its value");
  $display("   before %0d, after %0d, largest step %0d", out_before, dut_o, max_step);
  dio_p[7] = 1'b0;
  cycles(50);
  // b) KI quadrupled: no step, faster slope
  set_gains(SET1, 0, 1024, 24'hfffffc, 0, 0, 4096);
  cycles(50);
  max_step = 0; step_on = 1'b1;
  out_before = dut_o;
  dio_p[7] = 1'b1;
  cycles(200);
  step_on = 1'b0;
  check(max_step <= 2, "5b: KI changed, no output step");
  // 200 cycles at 0.125 LSB per cycle without the switch, 0.5 after it
  check(dut_o - out_before > 60, "5b: faster slope after the switch");
  $display("   rise over 200 cycles %0d, largest step %0d", dut_o - out_before, max_step);
  dio_p[7] = 1'b0;
  cycles(50);
  // c) set point and KD changed, KP = 0: no D kick
  set_gains(0,    0,   0, 1 << 18, 3200, 0, 4096);
  set_gains(SET1, 500, 0, 1 << 18, 3200, 0, 4096);
  restart(0);
  cval = 0;
  cycles(100);
  max_step = 0; step_on = 1'b1;
  dio_p[7] = 1'b1;
  cycles(200);
  dio_p[7] = 1'b0;
  cycles(200);
  step_on = 1'b0;
  check(max_step <= 1, "5c: set point and KD changed, no D kick");
  // d) latency from the input to the gains
  set_gains(SET1, 0, 2000, 0, 0, 0, 4096);
  set_gains(0,    0, 1000, 0, 0, 0, 4096);
  cycles(50);
  @(negedge clk);
  dio_p[7] = 1'b1;
  t_edge = $time;
  while (dut.act_kpg[0] == dut.kpg[0])
    @(negedge clk);
  $display("   input to gains: %0d clock cycles", ($time - t_edge)/8);
  check(($time - t_edge)/8 <= 10, "5d: gains switched within 10 cycles");
  dio_p[7] = 1'b0;
  cycles(50);

  //-------------------------------------------------------------------------------
  $display("6. Modes and the input filter");
  wr(A_PSET, 32'h0000_0021);  // mode 1
  cycles(20);
  rd(A_STATUS, r);
  check(r[0] == 1'b1, "6: mode 1 selects set 1 with the input low");
  wr(A_PSET, 32'h0000_0020);  // mode 0
  dio_p[7] = 1'b1;
  cycles(20);
  rd(A_STATUS, r);
  check(r[0] == 1'b0, "6: mode 0 selects set 0 with the input high");
  check(r[16+2] == 1'b1, "6: status shows the input level");
  wr(A_PSET, 32'h0000_0023);  // mode 3
  cycles(20);
  rd(A_STATUS, r);
  check(r[0] == 1'b0, "6: mode 3 selects set 0 with the input high");
  dio_p[7] = 1'b0;
  cycles(20);
  rd(A_STATUS, r);
  check(r[0] == 1'b1, "6: mode 3 selects set 1 with the input low");
  wr(A_PSET, 32'h0000_0022);  // mode 2
  cycles(20);
  // 3-cycle glitch: rejected
  @(negedge clk); dio_p[7] = 1'b1;
  cycles(3);
  dio_p[7] = 1'b0;
  hold_seen = 0;
  for (i = 0; i < 30; i = i + 1) begin
    @(negedge clk);
    if (dut.pset_d1[0])
      hold_seen = 1;
  end
  check(hold_seen == 0, "6: 3-cycle glitch rejected");
  // 4 cycles: taken
  @(negedge clk); dio_p[7] = 1'b1;
  cycles(4);
  dio_p[7] = 1'b0;
  hold_seen = 0;
  for (i = 0; i < 30; i = i + 1) begin
    @(negedge clk);
    if (dut.pset_d1[0])
      hold_seen = 1;
  end
  check(hold_seen == 1, "6: 4-cycle pulse taken");
  // other inputs
  for (i = 0; i < 7; i = i + 1) begin
    wr(A_PSET, 32'h0000_0002 | (i << 4));
    case (i)
      0: dio_p[5] = 1'b1;
      1: dio_p[6] = 1'b1;
      2: dio_p[7] = 1'b1;
      3: dio_n[0] = 1'b1;
      4: dio_n[5] = 1'b1;
      5: dio_n[6] = 1'b1;
      default: dio_n[7] = 1'b1;
    endcase
    cycles(15);
    rd(A_STATUS, r);
    check(r[0] == 1'b1, "6: each input selects set 1");
    dio_p = 8'h0; dio_n = 8'h0;
    cycles(15);
    rd(A_STATUS, r);
    check(r[0] == 1'b0, "6: each input back to set 0");
  end

  //-------------------------------------------------------------------------------
  $display("7. Lock monitoring and holdoff");
  wr(A_PSET, 32'h0000_0020);  // mode 0
  set_gains(0, 0, 0, 0, 0, 0, 4096);
  set_gains(SET1, 0, 0, 0, 0, 0, 4096);
  wr(A_MIN, 100);         wr(A_MAX, 200);
  wr(A_MIN + SET1, 1000); wr(A_MAX + SET1, 2000);
  wr(A_HOLD, 300);        wr(A_HOLD + SET1, 1000);
  wr(A_STEP, 1000);
  wr(A_SRC, 0);
  restart(CONF_REL);
  // set 0 against the reference
  relock_a = 150;
  cycles(10);
  mon_fail = 0;
  cmp_lock = 1'b1;
  relock_a = 50;  cycles(200);
  relock_a = 150; cycles(200);
  relock_a = 250; cycles(200);
  relock_a = 150; cycles(200);
  cmp_lock = 1'b0;
  check(mon_fail == 0, "7: lock status equals the reference (set 0)");
  // switch to set 1 while locked; the signal moves into the new window after 500 cycles
  wr(A_PSET, 32'h0000_0022);
  cycles(10);
  check(dut_lock[0] == 1'b1, "7: locked before the switch");
  lock_drops = 0; hold_seen = 0;
  dio_p[7] = 1'b1;
  for (i = 0; i < 2000; i = i + 1) begin
    @(negedge clk);
    if (i == 500)
      relock_a = 1500;
    if (!dut_lock[0])
      lock_drops = lock_drops + 1;
    if (dut.relock_hold_o[0])
      hold_seen = 1;
  end
  check(lock_drops == 0, "7: no lock drop during the holdoff");
  check(hold_seen == 0, "7: no relock hold during the holdoff");
  rd(A_STATUS, r);
  check(r[1] == 1'b0 && r[0] == 1'b1, "7: set 1 active");
  check(r[12] == 1'b1, "7: input outside the window during the holdoff flagged");
  check(r[8] == 1'b1, "7: raw window result");
  // back to set 0 with the signal outside its window: drop when the holdoff ends
  @(negedge clk);
  dio_p[7] = 1'b0;
  while (dut.pset_d0[0])
    @(negedge clk);
  t_sw = $time;
  while (dut_lock[0])
    @(negedge clk);
  t_drop = $time;
  $display("   drop %0d cycles after the switch (holdoff 300)", (t_drop - t_sw)/8);
  check(((t_drop - t_sw)/8 >= 300) && ((t_drop - t_sw)/8 <= 306), "7: drop when the holdoff ends");
  // unlocked, outside both windows: locks during the holdoff of set 1
  relock_a = 500;
  cycles(100);
  check(dut_lock[0] == 1'b0, "7: unlocked outside both windows");
  dio_p[7] = 1'b1;
  cycles(200);
  relock_a = 1500;
  cycles(5);
  check(dut_lock[0] == 1'b1, "7: locks during the holdoff");
  rd(A_STATUS, r);
  check(r[4] == 1'b1, "7: holdoff still running");
  dio_p[7] = 1'b0;
  wr(A_PSET, 32'h0000_0020);
  cycles(500);

  //-------------------------------------------------------------------------------
  $display("8. Registers, external reset");
  for (i = 0; i < 8; i = i + 1) begin
    wr(A_SP   + 'h100*(i/4) + 4*(i%4), 14'h1000 + i);
    wr(A_KP   + 'h100*(i/4) + 4*(i%4), 24'h123400 + i);
    wr(A_KI   + 'h100*(i/4) + 4*(i%4), 24'h234500 + i);
    wr(A_KD   + 'h100*(i/4) + 4*(i%4), 24'h345600 + i);
    wr(A_MIN  + 'h100*(i/4) + 4*(i%4), 12'h100 + i);
    wr(A_MAX  + 'h100*(i/4) + 4*(i%4), 12'h200 + i);
    wr(A_KII  + 'h100*(i/4) + 4*(i%4), 24'h456700 + i);
    wr(A_KG   + 'h100*(i/4) + 4*(i%4), 24'h567800 + i);
    wr(A_HOLD + 'h100*(i/4) + 4*(i%4), 32'h89abcd00 + i);
  end
  for (i = 0; i < 8; i = i + 1) begin
    rd(A_SP   + 'h100*(i/4) + 4*(i%4), r); check(r == 14'h1000 + i,       "8: set point readback");
    rd(A_KP   + 'h100*(i/4) + 4*(i%4), r); check(r == 24'h123400 + i,     "8: KP readback");
    rd(A_KI   + 'h100*(i/4) + 4*(i%4), r); check(r == 24'h234500 + i,     "8: KI readback");
    rd(A_KD   + 'h100*(i/4) + 4*(i%4), r); check(r == 24'h345600 + i,     "8: KD readback");
    rd(A_MIN  + 'h100*(i/4) + 4*(i%4), r); check(r == 12'h100 + i,        "8: window min readback");
    rd(A_MAX  + 'h100*(i/4) + 4*(i%4), r); check(r == 12'h200 + i,        "8: window max readback");
    rd(A_KII  + 'h100*(i/4) + 4*(i%4), r); check(r == 24'h456700 + i,     "8: KII readback");
    rd(A_KG   + 'h100*(i/4) + 4*(i%4), r); check(r == 24'h567800 + i,     "8: KG readback");
    rd(A_HOLD + 'h100*(i/4) + 4*(i%4), r); check(r == 32'h89abcd00 + i,   "8: holdoff readback");
  end
  for (i = 0; i < 4; i = i + 1) begin
    wr(A_STEP + 4*i, 24'habcd00 + i);
    wr(A_PSET + 4*i, 32'h0000_0040 | (i % 3));
  end
  for (i = 0; i < 4; i = i + 1) begin
    rd(A_STEP + 4*i, r);         check(r == 24'habcd00 + i, "8: step size readback");
    rd(A_PSET + 4*i, r);         check(r == (32'h40 | (i % 3)), "8: parameter set control readback");
    rd(A_STEP + SET1 + 4*i, r);  check(r == 0, "8: no set 1 step size");
    rd(A_PSET + SET1 + 4*i, r);  check(r == 0, "8: no set 1 parameter set control");
  end
  for (i = 0; i < 4; i = i + 1)
    wr(A_PSET + 4*i, 0);
  rd(32'h008, r);        check(r == 0, "8: 0x008 reads 0");
  rd(32'h00c, r);        check(r == 0, "8: 0x00c reads 0");
  rd(32'h0e0, r);        check(r == 0, "8: 0x0e0 reads 0");
  rd(32'h0f4, r);        check(r == 0, "8: 0x0f4 reads 0");
  rd(32'h100, r);        check(r == 0, "8: 0x100 reads 0");
  rd(32'h180, r);        check(r == 0, "8: 0x180 reads 0");
  rd(32'h1b0, r);        check(r == 0, "8: 0x1b0 reads 0");
  rd(32'h1f0, r);        check(r == 0, "8: 0x1f0 reads 0");
  rd(32'h240, r);        check(r == 0, "8: 0x240 reads 0");
  rd(32'h300, r);        check(r == 0, "8: 0x300 reads 0");
  rd(32'h400, r);        check(r == 0, "8: 0x400 reads 0");
  rd(A_ID, r);           check(r == 32'h5053_0002, "8: feature ID");
  // external reset of PID11 from each of its four sources
  wr(A_CONF2, 32'h1);
  for (i = 0; i < 4; i = i + 1) begin
    wr(A_EXTSRC, i);
    cycles(5);
    check(dut.ext_reset[0] == 1'b0, "8: external reset low");
    case (i)
      0: dio_p[5] = 1'b1;
      1: dio_p[6] = 1'b1;
      2: dio_p[7] = 1'b1;
      default: dio_n[0] = 1'b1;
    endcase
    cycles(3);
    check(dut.ext_reset[0] == 1'b1, "8: external reset from its source");
    dio_p = 8'h0; dio_n = 8'h0;
    cycles(3);
    check(dut.ext_reset[0] == 1'b0, "8: external reset released");
  end
  wr(A_CONF2, 32'h0);

  //-------------------------------------------------------------------------------
  $display("9. Event counters");
  // Every counter register reads its counter
  for (i = 0; i < 16; i = i + 1) begin
    rd(A_CNT + 4*i, r);
    case (i / 4)
      0: e = dut.cnt_switches[i % 4];
      1: e = dut.cnt_holdoff_went_outside[i % 4];
      2: e = dut.cnt_holdoff_ended_outside[i % 4];
      default: e = dut.cnt_unlocks[i % 4];
    endcase
    check(r == e, "9: counter register reads its counter");
  end
  // PID11 locked in set 0, servo on; set 1's window apart from set 0's
  wr(A_PSET, 32'h0000_0020);
  wr(A_MIN, 100);         wr(A_MAX, 200);
  wr(A_MIN + SET1, 1000); wr(A_MAX + SET1, 2000);
  wr(A_HOLD, 300);        wr(A_HOLD + SET1, 1000);
  restart(CONF_REL);
  relock_a = 150;
  cycles(100);
  for (i = 0; i < 4; i = i + 1) begin
    rd(A_CNT + 'h10*i, r);
    cnt_base[i] = r;
  end
  // Three unlocks, short ones and one 100 cycles after the other: three
  relock_a = 50;  cycles(20);
  relock_a = 150; cycles(100);
  relock_a = 50;  cycles(20);
  relock_a = 150; cycles(100);
  relock_a = 50;  cycles(1);
  relock_a = 150; cycles(100);
  // Held: none
  wr(A_CONF, CONF_BASE | CONF_REL | 32'h0000_1000);
  relock_a = 50;  cycles(20);
  relock_a = 150; cycles(20);
  wr(A_CONF, CONF_BASE | CONF_REL);
  cycles(100);
  rd(A_CNT + 'h30, r);
  check(r - cnt_base[3] == 3, "9: three unlocks (every one counts, none while held)");
  // Into set 1 with the input outside its window, inside it before the holdoff
  // ends: a switch, a holdoff with the input outside the window, no unlock
  wr(A_PSET, 32'h0000_0022);
  dio_p[7] = 1'b1;
  cycles(500);
  relock_a = 1500;
  cycles(1000);
  check(dut_lock[0] == 1'b1, "9: locked in set 1");
  // Back into set 0 with the input outside its window: a switch, a holdoff
  // with the input outside the window that ends outside it, an unlock
  dio_p[7] = 1'b0;
  cycles(500);
  check(dut_lock[0] == 1'b0, "9: unlocked when the holdoff ended");
  relock_a = 150;
  cycles(100);
  // A switch with the input inside both windows: a switch only
  wr(A_MIN + SET1, 100);
  dio_p[7] = 1'b1;
  cycles(1200);
  dio_p[7] = 1'b0;
  cycles(500);
  rd(A_CNT,         r); check(r - cnt_base[0] == 4, "9: four set switches");
  rd(A_CNT + 'h10,  r); check(r - cnt_base[1] == 2, "9: two holdoffs with the input outside the window");
  rd(A_CNT + 'h20,  r); check(r - cnt_base[2] == 1, "9: one holdoff that ended outside the window");
  rd(A_CNT + 'h30,  r); check(r - cnt_base[3] == 4, "9: four unlocks");
  wr(A_PSET, 32'h0000_0020);

  //-------------------------------------------------------------------------------
  $display("10. Registered stand-ins for combinational results");
  // Integrator products beyond the clamp: the largest KI and KG with a large
  // error of either sign, and a positive product while the hold is on and the
  // integrator sits at its negative limit (saturation acts despite the hold)
  set_gains(0, 0, 0, (1 << 24) - 1, 0, 0, (1 << 24) - 1);
  restart(0);
  cval = 8000;
  cycles(200);
  cval = -8000;
  cycles(200);
  wr(A_CONF, CONF_BASE | 32'h0000_1000);
  cval = 8000;
  cycles(100);
  wr(A_CONF, CONF_BASE);
  cycles(100);
  cval = 0;
  $display("   cycles x PIDs: product > 0 %0d, < 0 %0d, zero with the integrator not %0d, holdoff %0d",
           n_kii_pos, n_kii_neg, n_kii_zero, n_holdoff_on);
  $display("   integrator product clamped %0d, integrator saturating %0d", n_clamped, n_int_sat);
  check(inv_fail == 0, "10: registered stand-ins equal their definitions");
  check((n_kii_pos > 0) && (n_kii_neg > 0) && (n_kii_zero > 0) && (n_holdoff_on > 0)
        && (n_clamped > 0) && (n_int_sat > 0), "10: every case met");

  //-------------------------------------------------------------------------------
  if (errors == 0)
    $display("PASS (%0d checks)", checks);
  else
    $display("FAIL (%0d of %0d checks failed)", errors, checks);
  $finish;
end

endmodule
