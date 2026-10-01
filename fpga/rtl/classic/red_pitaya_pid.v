/**
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * $Id: red_pitaya_pid.v 961 2014-01-21 11:40:39Z matej.oblak $
 *
 * @brief Red Pitaya MIMO PID controller.
 *
 * @Author Matej Oblak
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in Verilog hardware description language (HDL).
 * Please visit http://en.wikipedia.org/wiki/Verilog
 * for more details on the language used herein.
 */



/**
 * GENERAL DESCRIPTION:
 *
 * Multiple input multiple output controller.
 *
 *
 *                 /-------\       /-----------\
 *   CHA -----+--> | PID11 | ------| SUM & SAT | ---> CHA
 *            |    \-------/       \-----------/
 *            |                            ^
 *            |    /-------\               |
 *            ---> | PID21 | ----------    |
 *                 \-------/           |   |
 *                                     |   |
 *  INPUT                              |   |         OUTPUT
 *                                     |   |
 *                 /-------\           |   |
 *            ---> | PID12 | --------------
 *            |    \-------/           |
 *            |                        ˇ
 *            |    /-------\       /-----------\
 *   CHB -----+--> | PID22 | ------| SUM & SAT | ---> CHB
 *                 \-------/       \-----------/
 *
 *
 * MIMO controller is build from four equal submodules, each can have
 * different settings.
 *
 * Each output is sum of two controllers with different input. That sum is also
 * saturated to protect from wrapping.
 *
 * Each PID has two parameter sets, "parameter set 1" (set 0 here) and
 * "parameter set 2" (set 1), of set point, KP, KI, KD, KII, KG, lock window
 * and holdoff. The set in use is fixed by a register or follows a digital
 * input, either way round. The parameters switch
 * stage by stage as they enter the pipeline, so every output sample is
 * computed with one set. After a switch, the lock state of the PID cannot go
 * from locked to unlocked for the holdoff of the new set.
 *
 * Per PID, four counters count events too fast for the software to see:
 * switches of the parameter set, holdoffs during which the relock input left
 * the window, holdoffs that ended with it outside the window, and unlocks
 * (changes of the lock status from locked to unlocked while the hold is off).
 *
 */
`timescale 1ns / 1ps
module red_pitaya_pid (
   // signals
   input                   clk_i           ,  //!< processing clock
   input                   rstn_i          ,  //!< processing reset - active low
   input        [ 14-1: 0] dat_a_i         ,  //!< input data CHA
   input        [ 14-1: 0] dat_b_i         ,  //!< input data CHB
   input        [    1: 0] railed_a_i      ,  //!< input CHA railed
   input        [    1: 0] railed_b_i      ,  //!< input CHB railed
   input        [ 12-1: 0] relock_a_i      ,  // auxiliary ADC A
   input        [ 12-1: 0] relock_b_i      ,  // auxiliary ADC B
   input        [ 12-1: 0] relock_c_i      ,  // auxiliary ADC C
   input        [ 12-1: 0] relock_d_i      ,  // auxiliary ADC D
   input signed [ 14-1: 0] out_a_center_i  ,  // center of out 1 range
   input signed [ 14-1: 0] out_b_center_i  ,  // center of out 2 range
   input        [  8-1: 0] dio_p_i         ,  // extension connector DIO0_P-DIO7_P (asynchronous)
   input        [  8-1: 0] dio_n_i         ,  // extension connector DIO0_N-DIO7_N (asynchronous)
   output       [ 14-1: 0] dat_a_o         ,  //!< output data CHA
   output       [ 14-1: 0] dat_b_o         ,  //!< output data CHB
   output       [  4-1: 0] lock_status_o    ,  // lock status

   // system bus
   input      [ 32-1: 0] sys_addr        ,  //!< bus address
   input      [ 32-1: 0] sys_wdata       ,  //!< bus write data
   input                 sys_wen         ,  //!< bus write enable
   input                 sys_ren         ,  //!< bus read enable
   output reg [ 32-1: 0] sys_rdata       ,  //!< bus read data
   output reg            sys_err         ,  //!< bus error indicator
   output reg            sys_ack            //!< bus acknowledge signal
);

localparam  PSR = 12         ;              // p gain = Kp >> PSR
localparam  ISR = 28         ;              // i gain = Ki >> ISR
localparam  DSR = 8          ;              // D gain = Kd >> DSR
localparam  KP_BITS = 24     ;
localparam  KI_BITS = 24     ;
localparam  KD_BITS = 24     ;
localparam  G_BITS = 2*KP_BITS - 6;         // width of the products with KG
localparam  GSR = 6          ;              // extra fractional bits of the products with KG
localparam  RELOCK_STEP_BITS = 24;
localparam  RELOCK_STEPSR = 18;
// Read at 0xFC: 'PS' (two parameter sets) and the version of this register map
// (2: the event counters at 0x200)
localparam  FEATURE_ID = 32'h5053_0002;

// Per-set registers are indexed with n = 4*set + PID; the set 1 registers sit
// at the set 0 address + 0x100
reg         [14-1: 0    ] set_sp               [7:0];
reg         [KP_BITS-1:0] set_kp               [7:0];
reg         [KI_BITS-1:0] set_ki               [7:0];
reg         [KD_BITS-1:0] set_kd               [7:0];
reg         [KI_BITS-1:0] set_kii              [7:0];
reg         [KP_BITS-1:0] set_kg               [7:0];
reg         [12-1:0]      relock_minval        [7:0];
reg         [12-1:0]      relock_maxval        [7:0];
reg         [32-1:0]      holdoff              [7:0];  // clock cycles

wire        [14-1: 0    ] pid_in               [3:0];
wire signed [14-1: 0    ] pid_out              [3:0];
reg         [3:0]         pid_inverted              ;
reg         [3:0]         set_irst                  ;
reg         [3:0]         set_irst_when_railed      ;
reg         [3:0]         set_hold                  ;
reg         [3:0]         set_output_enabled        ;
reg         [3:0]         set_ext_reset_enabled     ;
reg         [3:0]         set_lock_status_out_en    ;
wire        [3:0]         pid_irst                  ;
wire        [3:0]         pid_ctr_rst               ;
wire signed [14-1:0]      pid_ctr_val          [3:0];
wire                      pid_hold             [3:0];
wire        [1:0]         pid_railed_i         [3:0];
wire        [1:0]         output_enabled       [3:0];
wire        [3:0]         ext_reset                 ;
reg         [2-1:0]       ext_reset_source     [3:0];

wire signed [15-1:0]      pid_sum              [3:0];
wire signed [14-1:0]      pid_sat              [3:0];

reg         [3:0]                  relock_lock_status;
reg         [3:0]                  relock_enabled;
reg         [RELOCK_STEP_BITS-1:0] relock_stepsize  [3:0];
reg         [2-1:0]                relock_source    [3:0];
wire                               relock_clear_o   [3:0];
wire signed [14-1:0]               relock_signal_o  [3:0];
wire                               relock_hold_o    [3:0];
wire        [12-1:0]               relock_signal_i  [3:0];
wire                               relock_hold_i    [3:0];
wire                               relock_locked_o  [3:0];
wire        [3:0]                  relock_in_window ;

wire        [12-1:0]               relock_i         [3:0];
assign relock_i[0] = relock_a_i;
assign relock_i[1] = relock_b_i;
assign relock_i[2] = relock_c_i;
assign relock_i[3] = relock_d_i;

//---------------------------------------------------------------------------------
//  Digital inputs: external lock reset and parameter set selection

// The inputs, in the order of the source registers: DIO5_P, DIO6_P, DIO7_P,
// DIO0_N (also the external lock reset sources 0-3), DIO5_N, DIO6_N, DIO7_N
wire        [7-1:0]        dio_in = {dio_n_i[7], dio_n_i[6], dio_n_i[5], dio_n_i[0],
                                     dio_p_i[7], dio_p_i[6], dio_p_i[5]};
(* ASYNC_REG = "TRUE" *) reg [7-1:0] dio_sync_1;
(* ASYNC_REG = "TRUE" *) reg [7-1:0] dio_sync_2;

always @(posedge clk_i) begin
   dio_sync_1 <= dio_in;
   dio_sync_2 <= dio_sync_1;
end

// Levels for the parameter set selection: a level is taken over once the
// synchronized input has shown it for 4 consecutive clock cycles, which
// rejects glitches and the chatter of a slow edge
reg         [7-1:0]        dio_level;
reg         [2-1:0]        dio_count            [6:0];

genvar dio_index;
generate for (dio_index = 0; dio_index < 7; dio_index = dio_index + 1) begin: g_dio
    always @(posedge clk_i) begin
       if (rstn_i == 1'b0) begin
          dio_level[dio_index] <= 1'b0;
          dio_count[dio_index] <= 2'd0;
       end
       else if (dio_sync_2[dio_index] == dio_level[dio_index])
          dio_count[dio_index] <= 2'd0;
       else if (dio_count[dio_index] == 2'd3) begin
          dio_level[dio_index] <= dio_sync_2[dio_index];
          dio_count[dio_index] <= 2'd0;
       end
       else
          dio_count[dio_index] <= dio_count[dio_index] + 2'd1;
    end
end
endgenerate

wire        [8-1:0]        dio_level_sel = {1'b0, dio_level};

// Parameter set selection per PID: mode 0 = set 0 (parameter set 1), 1 = set 1
// (parameter set 2), 2 = the selected input, high selecting set 1, 3 = the
// selected input, high selecting set 0
reg         [2-1:0]        pset_mode            [3:0];
reg         [3-1:0]        pset_input           [3:0];
wire        [3:0]          pset_next                 ;
reg         [3:0]          pset_d0                   ;  // set point, lock window, holdoff
reg         [3:0]          pset_d1                   ;  // gains
wire        [3:0]          pset_switch               ;  // the set changes (at the next clock edge)
reg         [3:0]          pset_switch_q             ;
reg         [32-1:0]       holdoff_count        [3:0];
wire        [3:0]          holdoff_on                ;
reg         [3:0]          holdoff_on_q              ;
reg         [3:0]          holdoff_violated          ;

// Event counters (they wrap around)
reg         [32-1:0]       cnt_switches         [3:0];  // parameter set switches
reg         [32-1:0]       cnt_holdoff_left     [3:0];  // holdoffs with the window left
reg         [32-1:0]       cnt_holdoff_out      [3:0];  // holdoffs that ended outside the window
reg         [32-1:0]       cnt_unlocks          [3:0];  // locked -> unlocked while the hold is off
reg         [3:0]          holdoff_violated_q        ;
reg         [3:0]          lock_q                    ;

// Active parameters
reg         [14-1:0]       act_sp               [3:0];
reg         [12-1:0]       act_minval           [3:0];
reg         [12-1:0]       act_maxval           [3:0];
reg         [G_BITS-1:0]   act_kpg              [3:0];
reg         [G_BITS-1:0]   act_kig              [3:0];
reg         [G_BITS-1:0]   act_kdg              [3:0];
reg         [KI_BITS-1:0]  act_kii              [3:0];
reg         [3:0]          act_kg_zero               ;

// Products with KG, of both sets
wire        [G_BITS-1:0]   kpg                  [7:0];
wire        [G_BITS-1:0]   kig                  [7:0];
wire        [G_BITS-1:0]   kdg                  [7:0];

genvar pid_index;

generate for (pid_index = 0; pid_index < 4; pid_index = pid_index + 1) begin: g_pid
    assign pset_next[pid_index] = (pset_mode[pid_index] == 2'd1)
                               || ((pset_mode[pid_index] == 2'd2) &&  dio_level_sel[pset_input[pid_index]])
                               || ((pset_mode[pid_index] == 2'd3) && !dio_level_sel[pset_input[pid_index]]);
    assign pset_switch[pid_index] = pset_d0[pid_index] != pset_d1[pid_index];
    assign holdoff_on[pid_index] = holdoff_count[pid_index] != 32'd0;

    always @(posedge clk_i) begin
       if (rstn_i == 1'b0) begin
          pset_d0[pid_index]          <= 1'b0;
          pset_d1[pid_index]          <= 1'b0;
          pset_switch_q[pid_index]    <= 1'b0;
          holdoff_count[pid_index]    <= 32'd0;
          holdoff_on_q[pid_index]     <= 1'b0;
          holdoff_violated[pid_index] <= 1'b0;
       end
       else begin
          pset_d0[pid_index] <= pset_next[pid_index];
          pset_d1[pid_index] <= pset_d0[pid_index];
          // The holdoff starts with the lock window of the new set
          if (pset_switch[pid_index])
             holdoff_count[pid_index] <= holdoff[4*pset_d0[pid_index]+pid_index];
          else if (holdoff_on[pid_index])
             holdoff_count[pid_index] <= holdoff_count[pid_index] - 32'd1;
          // Whether the lock window was left during the holdoff, until the next switch. The
          // window result lags the holdoff by one cycle, so the first result after a
          // switch still belongs to the old window.
          holdoff_on_q[pid_index]  <= holdoff_on[pid_index];
          pset_switch_q[pid_index] <= pset_switch[pid_index];
          if (pset_switch[pid_index] || pset_switch_q[pid_index])
             holdoff_violated[pid_index] <= 1'b0;
          else if (holdoff_on_q[pid_index] && !relock_in_window[pid_index])
             holdoff_violated[pid_index] <= 1'b1;
       end
    end

    always @(posedge clk_i) begin
       act_sp[pid_index]      <= set_sp[4*pset_d0[pid_index]+pid_index];
       act_minval[pid_index]  <= relock_minval[4*pset_d0[pid_index]+pid_index];
       act_maxval[pid_index]  <= relock_maxval[4*pset_d0[pid_index]+pid_index];
       act_kpg[pid_index]     <= kpg[4*pset_d1[pid_index]+pid_index];
       act_kig[pid_index]     <= kig[4*pset_d1[pid_index]+pid_index];
       act_kdg[pid_index]     <= kdg[4*pset_d1[pid_index]+pid_index];
       act_kii[pid_index]     <= set_kii[4*pset_d1[pid_index]+pid_index];
       act_kg_zero[pid_index] <= set_kg[4*pset_d1[pid_index]+pid_index] == {KP_BITS{1'b0}};
    end

    pid_kg_products #(
      .K_BITS  ( KP_BITS)
    ) i_kg_products (
      .clk_i   ( clk_i                ),
      .rstn_i  ( rstn_i               ),
      .kp0_i   ( set_kp[pid_index]    ),
      .ki0_i   ( set_ki[pid_index]    ),
      .kd0_i   ( set_kd[pid_index]    ),
      .kg0_i   ( set_kg[pid_index]    ),
      .kp1_i   ( set_kp[4+pid_index]  ),
      .ki1_i   ( set_ki[4+pid_index]  ),
      .kd1_i   ( set_kd[4+pid_index]  ),
      .kg1_i   ( set_kg[4+pid_index]  ),
      .kpg0_o  ( kpg[pid_index]       ),
      .kig0_o  ( kig[pid_index]       ),
      .kdg0_o  ( kdg[pid_index]       ),
      .kpg1_o  ( kpg[4+pid_index]     ),
      .kig1_o  ( kig[4+pid_index]     ),
      .kdg1_o  ( kdg[4+pid_index]     )
    );

    assign ext_reset[pid_index] = dio_sync_2[ext_reset_source[pid_index]] && set_ext_reset_enabled[pid_index];
    assign pid_hold[pid_index] = relock_hold_o[pid_index] || set_hold[pid_index] || ext_reset[pid_index];
    assign pid_sum[pid_index] = pid_out[pid_index] + relock_signal_o[pid_index];
    assign pid_sat[pid_index] = (^pid_sum[pid_index][15-1:15-2]) ?
                                {pid_sum[pid_index][15-1], {13{~pid_sum[pid_index][15-1]}}} :
                                pid_sum[pid_index][14-1:0];

    assign relock_signal_i[pid_index] = relock_i[relock_source[pid_index]];

    red_pitaya_pid_block #(
      .PSR     (  PSR   ),
      .ISR     (  ISR   ),
      .DSR     (  DSR   ),
      .KI_BITS ( KI_BITS),
      .G_BITS  ( G_BITS ),
      .GSR     (  GSR   )
    ) i_pid (
       // data
      .clk_i         (  clk_i                  ),  // clock
      .rstn_i        (  rstn_i                 ),  // reset - active low
      .railed_i      (  pid_railed_i[pid_index]),  // output railed
      .hold_i        (  pid_hold[pid_index]    ),  // PID internal state hold
      .dat_i         (  pid_in[pid_index]      ),  // input data
      .dat_o         (  pid_out[pid_index]     ),  // output data

       // settings
      .set_sp_i      (  act_sp[pid_index]      ),  // set point
      .set_kpg_i     (  act_kpg[pid_index]     ),  // Kp * Kg
      .set_kig_i     (  act_kig[pid_index]     ),  // Ki * Kg
      .set_kdg_i     (  act_kdg[pid_index]     ),  // Kd * Kg
      .set_kii_i     (  act_kii[pid_index]     ),  // Kii (second integrator gain)
      .set_kg_zero_i (  act_kg_zero[pid_index] ),  // Kg is zero
      .inverted_i    (  pid_inverted[pid_index]),  // feedback sign
      .int_rst_i     (  pid_irst[pid_index]    ),  // integrator reset
      .int_ctr_rst_i (  pid_ctr_rst[pid_index] ),
      .int_ctr_val_i (  pid_ctr_val[pid_index] )
    );

    pid_relock #(
        .STEPSR(RELOCK_STEPSR),
        .STEP_BITS(RELOCK_STEP_BITS)
    ) i_relock (
        .clk_i(clk_i),
        .on_i(relock_enabled[pid_index] && ~pid_irst[pid_index]), // Turn off relock if integrator reset is enabled
        .min_val_i(act_minval[pid_index]),
        .max_val_i(act_maxval[pid_index]),
        .stepsize_i(relock_stepsize[pid_index]),
        .signal_i(relock_signal_i[pid_index]),
        .railed_i(pid_railed_i[pid_index]),
        .hold_i(relock_hold_i[pid_index]),
        .freeze_i(holdoff_on[pid_index]),
        .hold_o(relock_hold_o[pid_index]),
        .locked_o(relock_locked_o[pid_index]),
        .in_window_o(relock_in_window[pid_index]),
        .clear_o(relock_clear_o[pid_index]),
        .signal_o(relock_signal_o[pid_index])
    );
end
endgenerate

assign pid_in[0] = dat_a_i;
assign pid_in[1] = dat_b_i;
assign pid_in[2] = dat_a_i;
assign pid_in[3] = dat_b_i;

assign pid_irst[0] = set_irst[0] || ext_reset[0];
assign pid_irst[1] = set_irst[1] || ext_reset[1];
assign pid_irst[2] = set_irst[2] || ext_reset[2];
assign pid_irst[3] = set_irst[3] || ext_reset[3];

// The automatic integrator reset is off during the holdoff: a set switch can rail the output briefly
assign pid_ctr_rst[0] = (set_irst_when_railed[0] && (railed_a_i[0] || railed_a_i[1]) && !holdoff_on[0]) || relock_clear_o[0];
assign pid_ctr_rst[1] = (set_irst_when_railed[1] && (railed_a_i[0] || railed_a_i[1]) && !holdoff_on[1]) || relock_clear_o[1];
assign pid_ctr_rst[2] = (set_irst_when_railed[2] && (railed_b_i[0] || railed_b_i[1]) && !holdoff_on[2]) || relock_clear_o[2];
assign pid_ctr_rst[3] = (set_irst_when_railed[3] && (railed_b_i[0] || railed_b_i[1]) && !holdoff_on[3]) || relock_clear_o[3];

assign pid_ctr_val[0] = out_a_center_i;
assign pid_ctr_val[1] = out_a_center_i;
assign pid_ctr_val[2] = out_b_center_i;
assign pid_ctr_val[3] = out_b_center_i;

assign pid_railed_i[0] = railed_a_i;
assign pid_railed_i[1] = railed_a_i;
assign pid_railed_i[2] = railed_b_i;
assign pid_railed_i[3] = railed_b_i;

assign relock_hold_i[0] = set_hold[0] || ext_reset[0];
assign relock_hold_i[1] = set_hold[1] || ext_reset[1];
assign relock_hold_i[2] = set_hold[2] || ext_reset[2];
assign relock_hold_i[3] = set_hold[3] || ext_reset[3];

// Determine whether outputs of PIDs are enabled
assign output_enabled[0] = set_output_enabled[0] && !ext_reset[0];
assign output_enabled[1] = set_output_enabled[1] && !ext_reset[1];
assign output_enabled[2] = set_output_enabled[2] && !ext_reset[2];
assign output_enabled[3] = set_output_enabled[3] && !ext_reset[3];

// Update register holding lock status
// This register is then written to memory (but not read back from memory)
always @(posedge clk_i) begin
   // `relock_lock_status <= relock_locked_o;` leads to error "Cannot access memory relock_locked_o directly"
   relock_lock_status[0] <= relock_locked_o[0];
   relock_lock_status[1] <= relock_locked_o[1];
   relock_lock_status[2] <= relock_locked_o[2];
   relock_lock_status[3] <= relock_locked_o[3];
end
// Output of lock status to top module, where it is written to digital output
// assign lock_status_o = relock_lock_status;
assign lock_status_o[0] = relock_lock_status[0] && set_lock_status_out_en[0];
assign lock_status_o[1] = relock_lock_status[1] && set_lock_status_out_en[1];
assign lock_status_o[2] = relock_lock_status[2] && set_lock_status_out_en[2];
assign lock_status_o[3] = relock_lock_status[3] && set_lock_status_out_en[3];

//---------------------------------------------------------------------------------
//  Event counters

generate for (pid_index = 0; pid_index < 4; pid_index = pid_index + 1) begin: g_cnt
    always @(posedge clk_i) begin
       if (rstn_i == 1'b0) begin
          cnt_switches[pid_index]       <= 32'd0;
          cnt_holdoff_left[pid_index]   <= 32'd0;
          cnt_holdoff_out[pid_index]    <= 32'd0;
          cnt_unlocks[pid_index]        <= 32'd0;
          holdoff_violated_q[pid_index] <= 1'b0;
          lock_q[pid_index]             <= 1'b0;
       end
       else begin
          if (pset_switch[pid_index])
             cnt_switches[pid_index] <= cnt_switches[pid_index] + 32'd1;
          // The flag rises once per holdoff
          holdoff_violated_q[pid_index] <= holdoff_violated[pid_index];
          if (holdoff_violated[pid_index] && !holdoff_violated_q[pid_index])
             cnt_holdoff_left[pid_index] <= cnt_holdoff_left[pid_index] + 32'd1;
          // The holdoff has just ended (run out, or cut short by a switch into a set
          // without one) with the relock input outside the window: the lock drops
          if (holdoff_on_q[pid_index] && !holdoff_on[pid_index] && !relock_in_window[pid_index])
             cnt_holdoff_out[pid_index] <= cnt_holdoff_out[pid_index] + 32'd1;
          // Every loss of lock while the hold is off (the lockbox monitor merges
          // them into lock drops)
          lock_q[pid_index] <= relock_lock_status[pid_index];
          if (!set_hold[pid_index] && lock_q[pid_index] && !relock_lock_status[pid_index])
             cnt_unlocks[pid_index] <= cnt_unlocks[pid_index] + 32'd1;
       end
    end
end
endgenerate

//---------------------------------------------------------------------------------
//  Sum and saturation

reg  [ 15-1: 0] out_1_sum   ;
reg  [ 14-1: 0] out_1_sat   ;
reg  [ 15-1: 0] out_2_sum   ;
reg  [ 14-1: 0] out_2_sat   ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      out_1_sat <= 14'd0 ;
      out_2_sat <= 14'd0 ;
   end
   else begin
      // Add signal of enabled PID lockboxes for out 1
      if (output_enabled[0] && (!output_enabled[1]))
         out_1_sum <= $signed(pid_sat[0]);
      else if (output_enabled[1] && (!output_enabled[0]))
         out_1_sum <= $signed(pid_sat[1]);
      else if (output_enabled[0] && output_enabled[1])
         out_1_sum <= $signed(pid_sat[0]) + $signed(pid_sat[1]);
      else
         out_1_sum <= 14'h0;

      // Add signal of enabled PID lockboxes for out 2
      if (output_enabled[2] && (!output_enabled[3]))
         out_2_sum <= $signed(pid_sat[2]);
      else if (output_enabled[3] && (!output_enabled[2]))
         out_2_sum <= $signed(pid_sat[3]);
      else if (output_enabled[2] && output_enabled[3])
         out_2_sum <= $signed(pid_sat[2]) + $signed(pid_sat[3]);
      else
         out_2_sum <= 14'h0;

      if (out_1_sum[15-1:15-2]==2'b01) // positive sat
         out_1_sat <= 14'h1FFF ;
      else if (out_1_sum[15-1:15-2]==2'b10) // negative sat
         out_1_sat <= 14'h2000 ;
      else
         out_1_sat <= out_1_sum[14-1:0] ;

      if (out_2_sum[15-1:15-2]==2'b01) // positive sat
         out_2_sat <= 14'h1FFF ;
      else if (out_2_sum[15-1:15-2]==2'b10) // negative sat
         out_2_sat <= 14'h2000 ;
      else
         out_2_sat <= out_2_sum[14-1:0] ;
   end
end

assign dat_a_o = out_1_sat ;
assign dat_b_o = out_2_sat ;

//---------------------------------------------------------------------------------
//
//  System bus connection

// Numerical parameters write, per set
genvar reg_index;
generate for (reg_index = 0; reg_index < 8; reg_index = reg_index + 1) begin: g_set_reg
    always @(posedge clk_i) begin
       if (rstn_i == 1'b0) begin
          set_sp[reg_index]          <= 14'd0 ;
          set_kp[reg_index]          <= {KP_BITS{1'b0}} ;
          set_ki[reg_index]          <= {KI_BITS{1'b0}} ;
          set_kd[reg_index]          <= {KD_BITS{1'b0}} ;
          set_kii[reg_index]         <= {KI_BITS{1'b0}} ;
          set_kg[reg_index]          <= {KP_BITS{1'b0}} ;
          relock_minval[reg_index]   <= 12'd0;
          relock_maxval[reg_index]   <= 12'd0;
          holdoff[reg_index]         <= 32'd0;
       end
       else begin
          if (sys_wen) begin
             if (sys_addr[19:0]==('h010+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_sp[reg_index] <= sys_wdata[14-1:0];
             if (sys_addr[19:0]==('h020+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_kp[reg_index] <= sys_wdata[KP_BITS-1:0];
             if (sys_addr[19:0]==('h030+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_ki[reg_index] <= sys_wdata[KI_BITS-1:0];
             if (sys_addr[19:0]==('h040+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_kd[reg_index] <= sys_wdata[KD_BITS-1:0];
             if (sys_addr[19:0]==('h050+'h100*(reg_index/4)+4*(reg_index%4)))
                 relock_minval[reg_index]  <= sys_wdata[12-1:0] ;
             if (sys_addr[19:0]==('h060+'h100*(reg_index/4)+4*(reg_index%4)))
                 relock_maxval[reg_index]  <= sys_wdata[12-1:0] ;
             if (sys_addr[19:0]==('h090+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_kii[reg_index] <= sys_wdata[KI_BITS-1:0];
             if (sys_addr[19:0]==('h0a0+'h100*(reg_index/4)+4*(reg_index%4)))
                 set_kg[reg_index] <= sys_wdata[KP_BITS-1:0];
             if (sys_addr[19:0]==('h0d0+'h100*(reg_index/4)+4*(reg_index%4)))
                 holdoff[reg_index] <= sys_wdata;
          end
       end
    end
end
endgenerate

// Numerical parameters write, shared by both sets
generate for (pid_index = 0; pid_index < 4; pid_index = pid_index + 1) begin: g_pid_reg
    always @(posedge clk_i) begin
       if (rstn_i == 1'b0) begin
          relock_stepsize[pid_index] <= {RELOCK_STEP_BITS{1'b0}};
          relock_source[pid_index]   <= 2'd0;
          ext_reset_source[pid_index]<= 2'd0;
          pset_mode[pid_index]       <= 2'd0;
          pset_input[pid_index]      <= 3'd2;  // DIO7_P
       end
       else begin
          if (sys_wen) begin
             if (sys_addr[19:0]==('h70+4*pid_index))
                 relock_stepsize[pid_index]  <= sys_wdata[RELOCK_STEP_BITS-1:0] ;
             if (sys_addr[19:0]==('h80+4*pid_index))
                 relock_source[pid_index]  <= sys_wdata[2-1:0] ;
             if (sys_addr[19:0]==('hb0+4*pid_index))
                 ext_reset_source[pid_index]  <= sys_wdata[2-1:0] ;
             if (sys_addr[19:0]==('hc0+4*pid_index)) begin
                 pset_mode[pid_index]  <= sys_wdata[2-1:0] ;
                 pset_input[pid_index] <= sys_wdata[7-1:4] ;
             end
          end
       end
    end
end
endgenerate

// Flags write
always @(posedge clk_i) begin
    if (rstn_i == 1'b0) begin
          set_ext_reset_enabled  <=  4'b0;
          set_lock_status_out_en <=  4'b1111;
          set_output_enabled     <=  4'b1111;
          relock_enabled         <=  4'b0   ;
          set_hold               <=  4'b0   ;
          set_irst_when_railed   <=  4'b0   ;
          pid_inverted           <=  4'b0   ;
          set_irst               <=  4'b1111;
    end
    else begin
        if (rstn_i & sys_wen & sys_addr[19:0]==20'h0) begin
            {set_output_enabled,
             relock_enabled,
             set_hold,
             set_irst_when_railed,
             pid_inverted,
             set_irst}
            <= sys_wdata[24-1:0];
            {set_lock_status_out_en}
            <= sys_wdata[32-1:28];
        end
        if (rstn_i & sys_wen & sys_addr[19:0]==20'h4)
            {set_ext_reset_enabled}
            <= sys_wdata[4-1:0];
    end
end

// Status of the parameter sets
wire [32-1:0] pset_status = {9'h0, dio_level, holdoff_violated, relock_in_window, holdoff_on, pset_d1};

wire sys_en;
assign sys_en = sys_wen | sys_ren;

// Read address: bit 8 = set, bits 7:4 = register, bits 3:2 = PID
wire [3-1:0] rd_n = {sys_addr[8], sys_addr[3:2]};
wire [2-1:0] rd_i = sys_addr[3:2];

always @(posedge clk_i)
if (rstn_i == 1'b0) begin
   sys_err <= 1'b0 ;
   sys_ack <= 1'b0 ;
end else begin
   sys_err <= 1'b0 ;
   sys_ack <= sys_en;

   if (sys_addr[19:10] != 10'h0)
      sys_rdata <= 32'h0;
   else if (sys_addr[9]) begin
      // The event counters at 0x200 + 0x10*k + 4*PID
      if (sys_addr[8:6] != 3'b000)
         sys_rdata <= 32'h0;
      else
         case (sys_addr[5:4])
            2'd0: sys_rdata <= cnt_switches[rd_i];
            2'd1: sys_rdata <= cnt_holdoff_left[rd_i];
            2'd2: sys_rdata <= cnt_holdoff_out[rd_i];
            default: sys_rdata <= cnt_unlocks[rd_i];
         endcase
   end
   else begin
      case (sys_addr[7:4])
         4'h0: begin
            if (!sys_addr[8] && (rd_i == 2'd0))
               sys_rdata <= {set_lock_status_out_en, relock_lock_status, set_output_enabled, relock_enabled,
                             set_hold, set_irst_when_railed, pid_inverted, set_irst};
            else if (!sys_addr[8] && (rd_i == 2'd1))
               sys_rdata <= {{32-4{1'b0}}, set_ext_reset_enabled};
            else
               sys_rdata <= 32'h0;
         end
         4'h1: sys_rdata <= {{32-14{1'b0}}, set_sp[rd_n]};
         4'h2: sys_rdata <= {{32-KP_BITS{1'b0}}, set_kp[rd_n]};
         4'h3: sys_rdata <= {{32-KI_BITS{1'b0}}, set_ki[rd_n]};
         4'h4: sys_rdata <= {{32-KD_BITS{1'b0}}, set_kd[rd_n]};
         4'h5: sys_rdata <= {{32-12{1'b0}}, relock_minval[rd_n]};
         4'h6: sys_rdata <= {{32-12{1'b0}}, relock_maxval[rd_n]};
         4'h7: sys_rdata <= sys_addr[8] ? 32'h0 : {{32-RELOCK_STEP_BITS{1'b0}}, relock_stepsize[rd_i]};
         4'h8: sys_rdata <= sys_addr[8] ? 32'h0 : {{32-2{1'b0}}, relock_source[rd_i]};
         4'h9: sys_rdata <= {{32-KI_BITS{1'b0}}, set_kii[rd_n]};
         4'ha: sys_rdata <= {{32-KP_BITS{1'b0}}, set_kg[rd_n]};
         4'hb: sys_rdata <= sys_addr[8] ? 32'h0 : {{32-2{1'b0}}, ext_reset_source[rd_i]};
         4'hc: sys_rdata <= sys_addr[8] ? 32'h0 : {{32-7{1'b0}}, pset_input[rd_i], 2'b00, pset_mode[rd_i]};
         4'hd: sys_rdata <= holdoff[rd_n];
         4'hf: begin
            if (!sys_addr[8] && (rd_i == 2'd0))
               sys_rdata <= pset_status;
            else if (!sys_addr[8] && (rd_i == 2'd3))
               sys_rdata <= FEATURE_ID;
            else
               sys_rdata <= 32'h0;
         end
         default: sys_rdata <= 32'h0;
      endcase
   end
end

endmodule
