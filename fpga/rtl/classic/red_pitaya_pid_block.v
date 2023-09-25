/**
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, Lothar Maisenbacher
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
 *   point         |    \---/             |
 *                 |                      |
 *                 |    /---\             |
 *                 ---> | D | ------------
 *                      \---/
 *
 *
 * Proportional-integral-derivative (PID) controller is made from three parts.
 *
 * Error which is difference between set point and input signal is driven into
 * propotional, integral and derivative part. Each calculates its own value which
 * is then summed and saturated before given to output.
 *
 * Integral part has also separate input to reset integrator value to 0.
 *
 */

`timescale 1ns / 1ps
module red_pitaya_pid_block #(
   parameter     PSR     = 12                   ,  // P, global gain = Kp, Kg >> PSR
   parameter     ISR     = 28                   ,  // I, II gain = Ki, Kii >> ISR
   parameter     DSR     = 8                    ,  // D gain = Kd >> DSR
   parameter     KP_BITS = 24                   ,
   parameter     KI_BITS = 24                   ,
   parameter     KD_BITS = 24
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
   input        [ KP_BITS-1: 0] set_kp_i        ,  // Kp
   input        [ KI_BITS-1: 0] set_ki_i        ,  // Ki (1/s)
   input        [ KD_BITS-1: 0] set_kd_i        ,  // Kd
   input        [ KI_BITS-1: 0] set_kii_i       ,  // Kii (second integrator gain) (1/s)
   input        [ KP_BITS-1: 0] set_kg_i        ,  // Kg (global gain)
   input                        inverted_i      ,  // feedback sign
   input                        int_rst_i       ,  // integrator reset
   input                        int_ctr_rst_i   ,  // integrator reset to center of the output range
   input signed [ 14-1: 0]      int_ctr_val_i      // center value of the output range
);

//---------------------------------------------------------------------------------
//  Set point error calculation
reg signed [ 15-1: 0] error        ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      error <= 15'h0 ;
   end
   else begin
       if (inverted_i == 1'b0)
          error <= dat_i - set_sp_i;
      else
          error <= -(dat_i - set_sp_i);
   end
end

//---------------------------------------------------------------------------------
//  Proportional part
reg signed   [KP_BITS+1+15-PSR-1: 0] kp_reg   ;
wire signed  [KP_BITS+1+15-1: 0]     kp_mult  ;
wire signed  [KP_BITS+1-1: 0]        kp_signed;  // Required to make signed arithmetic work
assign kp_signed = set_kp_i                   ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      kp_reg  <= {KP_BITS+1+15-PSR{1'b0}};
   end
   else if (hold_i)
      kp_reg <= kp_reg;
   else begin
      kp_reg <= kp_mult[KP_BITS+1+15-1:PSR] ;
   end
end

assign kp_mult = error * kp_signed;

//---------------------------------------------------------------------------------
//  Integrator

// LM: Register holding current error signal multiplied with integrator gain
reg signed  [KI_BITS+1+15-1: 0] ki_mult  ;
// LM: Register holding new integrator value (40-bit)
wire signed [15+ISR+1-1: 0]     int_sum  ;
// LM: Internal register holding integrator value (39-bit)
reg signed  [15+ISR-1: 0]       int_reg  ;
wire signed [15-1: 0]           int_shr  ;  // Twice the DAC range (14 bit) should be enough
// LM: Signed wire of (always positive) integrator gain
wire signed [KI_BITS+1-1: 0]    ki_signed;  // Required to make signed arithmetic work
assign ki_signed = set_ki_i              ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      ki_mult  <= {KI_BITS+1+15{1'b0}};
      int_reg  <= {15+ISR{1'b0}};
   end
   else begin
      // LM: Multiply current error signal value with (signed wire) integrator gain (`ki_signed`)
      // to get value to be added to integrator register
      ki_mult <= error * ki_signed;

      if (int_rst_i)
         int_reg <= {15+ISR{1'b0}}; // reset
      else if (int_ctr_rst_i)
         int_reg <= {int_ctr_val_i[13], int_ctr_val_i, {ISR{1'b0}}}; // reset to center of output range
      else if (int_sum[15+ISR:15+ISR-1] == 2'b01) // positive saturation
         int_reg <= {1'b0, {15+ISR-1{1'b1}}}; // max positive
      else if (int_sum[15+ISR:15+ISR-1] == 2'b10) // negative saturation
         int_reg <= {1'b1, {15+ISR-1{1'b0}}}; // max negative
      else if ((railed_i[0] && (ki_mult < 0)) // anti-windup lower rail
            || (railed_i[1] && (ki_mult > 0)) // anti-windup upper rail
            || (hold_i)) // LM: integrator hold
         int_reg <= int_reg;
      else
         // LM: Move all bits except MSB from `int_sum` into `int_reg`. Because `int_sum` is
         // limited to (by the saturation switch above) below MSB 01 and above MSB 11, this
         // operation will preserve the sign information.
         int_reg <= int_sum[15+ISR-1:0]; // use sum as it is
   end
end

// LM: Add error signal * integrator gain (= `ki_mult`) to internal integrator register,
// which is the basis of the new integrator value
assign int_sum = ki_mult + int_reg;
// LM: Select most-significant 15 bits from internal integrator register to be added to output
assign int_shr = int_reg[15+ISR-1:ISR];

//---------------------------------------------------------------------------------
//  Second integrator

// LM: Register holding current 1st integrator value multiplied with 2nd integrator gain
reg signed  [KI_BITS+1+15-1: 0] kii_mult  ;
// LM: Register holding new 2nd integrator value (40-bit)
wire signed [15+ISR+1-1: 0]     iint_sum  ;
// LM: Internal register holding 2nd integrator value (39-bit)
reg signed  [15+ISR-1: 0]       iint_reg  ;
wire signed [15-1: 0]           iint_shr  ;  // Twice the DAC range (14 bit) should be enough
// LM: Signed wire of (always positive) 2nd integrator gain
wire signed [KI_BITS+1-1: 0]    kii_signed;  // Required to make signed arithmetic work
assign kii_signed = set_kii_i             ;

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
            || (hold_i)) // LM: integrator hold
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

// wire  [    29-1: 0] kd_mult       ;
// reg   [29-DSR-1: 0] kd_reg        ;
// reg   [29-DSR-1: 0] kd_reg_r      ;
// reg   [29-DSR  : 0] kd_reg_s      ;
wire signed [    32-1: 0] kd_mult       ;
reg signed  [32-DSR-1: 0] kd_reg        ;
reg signed  [32-DSR-1: 0] kd_reg_r      ;
reg signed  [32-DSR  : 0] kd_reg_s      ;
// LM: Signed wire of (always positive) derivative gain
wire signed [KD_BITS+1-1: 0]    kd_signed;  // Required to make signed arithmetic work
assign kd_signed = set_kd_i              ;


always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      kd_reg   <= {32-DSR{1'b0}};
      kd_reg_r <= {32-DSR{1'b0}};
      kd_reg_s <= {32-DSR+1{1'b0}};
   end
   else if (hold_i)
      kd_reg <= kd_reg;
   else begin
      kd_reg   <= kd_mult[32-1:DSR] ;
      kd_reg_r <= kd_reg;
      kd_reg_s <= kd_reg - kd_reg_r;
   end
end

// assign kd_mult = $signed(error) * $signed(set_kd_i) ;
assign kd_mult = error * kd_signed;

//---------------------------------------------------------------------------------
//  Sum together - saturate output
wire signed  [   33-1: 0] pid_sum     ; // biggest posible bit-width
reg signed   [   14-1: 0] pid_out     ;
// Global gain
wire signed  [KP_BITS+1-1: 0]        kg_signed;  // Required to make signed arithmetic work
assign kg_signed = set_kg_i                   ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      pid_out    <= 14'b0 ;
   end
   else begin
      // if ({pid_sum[33-1],|pid_sum[32-2:13]} == 2'b01) //positive overflow
      if ({pid_sum[33-1],|pid_sum[32-2:13+PSR]} == 2'b01) //positive overflow
         pid_out <= 14'h1FFF ;
      // else if ({pid_sum[33-1],&pid_sum[33-2:13]} == 2'b10) //negative overflow
      else if ({pid_sum[33-1],&pid_sum[33-2:13+PSR]} == 2'b10) //negative overflow
         pid_out <= 14'h2000 ;
      else
         // pid_out <= pid_sum[14-1:0] ;
         pid_out <= pid_sum[14+PSR-1:+PSR] ;
   end
end

// assign pid_sum = kp_reg + $signed(int_shr) + $signed(iint_shr) + $signed(kd_reg_s) ;
assign pid_sum = kg_signed * (kp_reg + $signed(int_shr) + $signed(iint_shr) + $signed(kd_reg_s));

assign dat_o = pid_out ;

endmodule
