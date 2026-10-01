/**
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * $Id: red_pitaya_pid_block.v 961 2014-01-21 11:40:39Z matej.oblak $
 *
 * @brief Red Pitaya PID controller.
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
 * Proportional-integral-derivative (PID) controller.
 *
 *
 *        /---\         /---\      /-----------\
 *   IN --| - |----+--> | P | ---> | SUM & SAT | ---> OUT
 *        \---/    |    \---/      \-----------/
 *          ^      |                   ^  ^
 *          |      |    /---\          |  |
 *   set ----      +--> | I | ---------   |
 *   point              \---/             |
 *                                        |
 *               /---\                    |
 *   IN -------> | D | -------------------
 *               \---/
 *
 *
 * The error, the difference between set point and input signal, drives the
 * proportional and the integral part. The derivative part acts on the change
 * of the input signal itself (derivative on measurement), which equals the
 * change of the error for a constant set point and gives no kick when the set
 * point or KD changes. The parts are summed and saturated before they are
 * given to the output.
 *
 * The global gain KG enters through the products KP*KG, KI*KG and KD*KG
 * (`pid_kg_products`), with which the error is multiplied. The integrators
 * therefore hold KG-scaled values, and a change of KG changes the slope of
 * the output, never its value. For a constant KG the controller is the same
 * as with KG applied to the sum of the parts.
 *
 * The integral part has a separate input to reset the integrator value to 0,
 * and one to reset the output to the center of the output range.
 */

`timescale 1ns / 1ps
module red_pitaya_pid_block #(
   parameter     PSR     = 12                   ,  // P, global gain = Kp, Kg >> PSR
   parameter     ISR     = 28                   ,  // I, II gain = Ki, Kii >> ISR
   parameter     DSR     = 8                    ,  // D gain = Kd >> DSR
   parameter     KI_BITS = 24                   ,  // width of Kii
   parameter     G_BITS  = 42                   ,  // width of the KG products
   parameter     GSR     = 6                       // extra fractional bits of the KG products
)
(
   // data
   input                        clk_i           ,  // clock
   input                        rstn_i          ,  // reset - active low
   input         [    1: 0]     railed_i        ,  // output railed
   input                        hold_i          ,  // hold PID state
   input signed  [ 14-1: 0]     dat_i           ,  // input data
   output signed [ 14-1: 0]     dat_o           ,  // output data

   // settings
   input signed [ 14-1: 0]      set_sp_i        ,  // set point
   input        [ G_BITS-1: 0]  set_kpg_i       ,  // Kp * Kg
   input        [ G_BITS-1: 0]  set_kig_i       ,  // Ki * Kg (1/s)
   input        [ G_BITS-1: 0]  set_kdg_i       ,  // Kd * Kg
   input        [ KI_BITS-1: 0] set_kii_i       ,  // Kii (second integrator gain) (1/s)
   input                        set_kg_zero_i   ,  // Kg is zero
   input                        inverted_i      ,  // feedback sign
   input                        int_rst_i       ,  // integrator reset
   input                        int_ctr_rst_i   ,  // integrator reset to center of the output range
   input signed [ 14-1: 0]      int_ctr_val_i      // center value of the output range
);

//---------------------------------------------------------------------------------
//  Set point error and change of the input

reg signed [ 15-1: 0] error        ;
reg signed [ 15-1: 0] dmeas        ;  // change of the input, with the feedback sign
reg signed [ 14-1: 0] dat_q        ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      error <= 15'h0 ;
      dmeas <= 15'h0 ;
      dat_q <= 14'h0 ;
   end
   else begin
      dat_q <= dat_i;
      if (inverted_i == 1'b0) begin
         error <= dat_i - set_sp_i;
         dmeas <= dat_i - dat_q;
      end
      else begin
         error <= -(dat_i - set_sp_i);
         dmeas <= -(dat_i - dat_q);
      end
   end
end

//---------------------------------------------------------------------------------
//  Proportional part

// Signed wires of the (always positive) KG products, required to make signed arithmetic work
wire signed [G_BITS+1-1: 0] kpg_signed = {1'b0, set_kpg_i};
wire signed [G_BITS+1-1: 0] kig_signed = {1'b0, set_kig_i};
wire signed [G_BITS+1-1: 0] kdg_signed = {1'b0, set_kdg_i};

// The product is registered without reset and hold, so that it can take the
// pipeline registers of the multiplier cascade; hold acts on the stage after it
reg  signed [G_BITS+1+15-1: 0]         kp_mult ;
reg  signed [G_BITS+1+15-PSR-GSR-1: 0] kp_reg  ;

always @(posedge clk_i) begin
   kp_mult <= error * kpg_signed;
   if (rstn_i == 1'b0)
      kp_reg <= {G_BITS+1+15-PSR-GSR{1'b0}};
   else if (!hold_i)
      kp_reg <= kp_mult[G_BITS+1+15-1:PSR+GSR];
end

//---------------------------------------------------------------------------------
//  Integrator

// Error multiplied with KI*KG, the value added to the integrator. Three
// register stages: the integrator then lags the proportional part by one
// more clock cycle than the output adds to it, as it did when KG was applied
// to the sum.
reg  signed [G_BITS+1+15-1: 0] ki_mult    ;
reg  signed [G_BITS+1+15-1: 0] ki_mult_r  ;
reg  signed [G_BITS+1+15-1: 0] ki_mult_q  ;
// New integrator value, before saturation
wire signed [G_BITS+1+15  : 0] int_sum    ;
// Integrator, with GSR fractional bits more than the integrator gain
reg  signed [15+ISR+GSR-1: 0]  int_reg    ;
// Most-significant 15 bits of the integrator, added to the output
wire signed [15-1: 0]          int_shr    ;  // Twice the DAC range (14 bit) should be enough

always @(posedge clk_i) begin
   ki_mult   <= error * kig_signed;
   ki_mult_r <= ki_mult;
   ki_mult_q <= ki_mult_r;
end

assign int_sum = ki_mult_q + int_reg;

// `int_sum` lies within the range of `int_reg` if its bits above the sign bit
// of `int_reg` all equal its sign bit
wire int_sum_pos = !int_sum[G_BITS+1+15] &&  (|int_sum[G_BITS+1+15-1:15+ISR+GSR-1]);
wire int_sum_neg =  int_sum[G_BITS+1+15] && !(&int_sum[G_BITS+1+15-1:15+ISR+GSR-1]);

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      int_reg  <= {15+ISR+GSR{1'b0}};
   end
   else begin
      if (int_rst_i || int_ctr_rst_i)
         int_reg <= {15+ISR+GSR{1'b0}}; // reset (the center reset sets the second integrator)
      else if (int_sum_pos) // positive saturation
         int_reg <= {1'b0, {15+ISR+GSR-1{1'b1}}}; // max positive
      else if (int_sum_neg) // negative saturation
         int_reg <= {1'b1, {15+ISR+GSR-1{1'b0}}}; // max negative
      else if ((railed_i[0] && (ki_mult_q < 0)) // anti-windup lower rail
            || (railed_i[1] && (ki_mult_q > 0)) // anti-windup upper rail
            || (hold_i)) // integrator hold
         int_reg <= int_reg;
      else
         int_reg <= int_sum[15+ISR+GSR-1:0];
   end
end

assign int_shr = int_reg[15+ISR+GSR-1:ISR+GSR];

//---------------------------------------------------------------------------------
//  Second integrator

// LM: Register holding current 1st integrator value multiplied with 2nd integrator gain
reg signed  [KI_BITS+1+15-1: 0] kii_mult  ;
// LM: Register holding new 2nd integrator value (44-bit)
wire signed [15+ISR+1-1: 0]     iint_sum  ;
// LM: Internal register holding 2nd integrator value (43-bit)
reg signed  [15+ISR-1: 0]       iint_reg  ;
wire signed [15-1: 0]           iint_shr  ;  // Twice the DAC range (14 bit) should be enough
// LM: Signed wire of (always positive) 2nd integrator gain
wire signed [KI_BITS+1-1: 0]    kii_signed = {1'b0, set_kii_i};

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      kii_mult  <= {KI_BITS+1+15{1'b0}};
      iint_reg  <= {15+ISR{1'b0}};
   end
   else begin
      // LM: Multiply 1st integrator output with (signed wire) 2nd integrator gain `kii_signed`
      // to get value to be added to 2nd integrator register
      kii_mult <= int_shr * kii_signed;

      if (int_rst_i)
         iint_reg <= {15+ISR{1'b0}}; // reset
      else if (int_ctr_rst_i)
         iint_reg <= {int_ctr_val_i[13], int_ctr_val_i, {ISR{1'b0}}}; // reset to center of output range
      else if (iint_sum[15+ISR:15+ISR-1] == 2'b01) // positive saturation
         iint_reg <= {1'b0, {15+ISR-1{1'b1}}}; // max positive
      else if (iint_sum[15+ISR:15+ISR-1] == 2'b10) // negative saturation
         iint_reg <= {1'b1, {15+ISR-1{1'b0}}}; // max negative
      else if ((railed_i[0] && (kii_mult < 0)) // anti-windup lower rail
            || (railed_i[1] && (kii_mult > 0)) // anti-windup upper rail
            || (hold_i) // LM: integrator hold
            || (set_kg_zero_i)) // a zero KG freezes the first integrator, and with it the output
         iint_reg <= iint_reg;
      else
         // LM: Move all bits except MSB from `iint_sum` into `iint_reg`. Because `iint_sum` is
         // limited to (by the saturation switch above) below MSB 01 and above MSB 11, this
         // operation will preserve the sign information.
         iint_reg <= iint_sum[15+ISR-1:0]; // use sum as it is
   end
end

// LM: Add 1st integrator output * 2nd integrator gain (= `kii_mult`) to
// internal 2nd integrator register, which is the basis of the new 2nd integrator value
assign iint_sum = kii_mult + iint_reg;
// LM: Select most-significant 15 bits from internal 2nd integrator register to be added to output
assign iint_shr = iint_reg[15+ISR-1:ISR];

//---------------------------------------------------------------------------------
//  Derivative

// Registered like the proportional part's product
reg  signed [G_BITS+1+15-1: 0]         kd_mult ;
reg  signed [G_BITS+1+15-DSR-GSR-1: 0] kd_reg  ;

always @(posedge clk_i) begin
   kd_mult <= dmeas * kdg_signed;
   if (rstn_i == 1'b0)
      kd_reg <= {G_BITS+1+15-DSR-GSR{1'b0}};
   else if (!hold_i)
      kd_reg <= kd_mult[G_BITS+1+15-1:DSR+GSR];
end

//---------------------------------------------------------------------------------
//  Sum together - saturate output

localparam PD_BITS = G_BITS+1+15-DSR-GSR+1; // width of P + D (D is the wider part)

reg  signed [PD_BITS-1: 0] pd_reg  ;
reg  signed [   14-1: 0]   pid_out ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0)
      pd_reg <= {PD_BITS{1'b0}};
   else
      pd_reg <= kp_reg + kd_reg;
end

// P + D beyond +-2^16 saturates the output whatever the integrators hold
// (+-2^15 together), so only its 17 low bits enter the sum
wire pd_pos = !pd_reg[PD_BITS-1] &&  (|pd_reg[PD_BITS-2:16]);
wire pd_neg =  pd_reg[PD_BITS-1] && !(&pd_reg[PD_BITS-2:16]);
wire signed [18-1: 0] out_sum = $signed(pd_reg[17-1:0]) + int_shr + iint_shr;
wire out_pos = !out_sum[17] &&  (|out_sum[16:13]);
wire out_neg =  out_sum[17] && !(&out_sum[16:13]);

always @(posedge clk_i) begin
   if (rstn_i == 1'b0)
      pid_out <= 14'b0 ;
   else if (pd_pos || (!pd_neg && out_pos)) // positive overflow
      pid_out <= 14'h1FFF ;
   else if (pd_neg || out_neg) // negative overflow
      pid_out <= 14'h2000 ;
   else
      pid_out <= out_sum[14-1:0] ;
end

assign dat_o = pid_out ;

endmodule
