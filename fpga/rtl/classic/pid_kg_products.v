/*
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Products of the global gain KG with KP, KI and KD, for both parameter sets
 * of one PID.
 *
 * The PID applies KG by multiplying the error with these products, so that
 * the integrator holds the KG-scaled value and a change of KG, by a register
 * write or by a switch of the parameter set, does not make the output jump.
 * The gains are constant between register writes, so one multiplier computes
 * the six products in turn, off the signal path: each product is refreshed
 * every 6 clock cycles and follows a register write within 10 cycles.
 *
 * Each product is round(K * KG / 2^6), with K and KG in their register units
 * (KG = 2^12 is unity gain), i.e. 18 fractional bits more than K / 2^PSR. At
 * unity KG the product is exactly K * 2^6.
 */
`timescale 1ns / 1ps

module pid_kg_products #(
    parameter K_BITS = 24,             // width of the gain registers
    parameter P_BITS = 2*K_BITS - 6    // width of the products
)
(
    input  wire              clk_i,
    input  wire              rstn_i,
    // set 0 (parameter set 1)
    input  wire [K_BITS-1:0] kp0_i,
    input  wire [K_BITS-1:0] ki0_i,
    input  wire [K_BITS-1:0] kd0_i,
    input  wire [K_BITS-1:0] kg0_i,
    // set 1 (parameter set 2)
    input  wire [K_BITS-1:0] kp1_i,
    input  wire [K_BITS-1:0] ki1_i,
    input  wire [K_BITS-1:0] kd1_i,
    input  wire [K_BITS-1:0] kg1_i,
    // products
    output reg  [P_BITS-1:0] kpg0_o,
    output reg  [P_BITS-1:0] kig0_o,
    output reg  [P_BITS-1:0] kdg0_o,
    output reg  [P_BITS-1:0] kpg1_o,
    output reg  [P_BITS-1:0] kig1_o,
    output reg  [P_BITS-1:0] kdg1_o
);

// Index of the product being computed: 0-2 = KP, KI, KD of set 0, 3-5 = set 1
reg [2:0] idx;
always @(posedge clk_i) begin
    if (rstn_i == 1'b0)
        idx <= 3'd0;
    else
        idx <= (idx == 3'd5) ? 3'd0 : idx + 3'd1;
end

// Stage 1: operands
reg [K_BITS-1:0] op_k;
reg [K_BITS-1:0] op_g;
reg [2:0]        idx_1;
always @(posedge clk_i) begin
    case (idx)
        3'd0:    op_k <= kp0_i;
        3'd1:    op_k <= ki0_i;
        3'd2:    op_k <= kd0_i;
        3'd3:    op_k <= kp1_i;
        3'd4:    op_k <= ki1_i;
        default: op_k <= kd1_i;
    endcase
    op_g  <= (idx < 3'd3) ? kg0_i : kg1_i;
    idx_1 <= idx;
end

// Stages 2 and 3: product, two pipeline registers for the DSP cascade
reg [2*K_BITS-1:0] prod_2;
reg [2*K_BITS-1:0] prod_3;
reg [2:0]          idx_2;
reg [2:0]          idx_3;
always @(posedge clk_i) begin
    prod_2 <= op_k * op_g;
    prod_3 <= prod_2;
    idx_2  <= idx_1;
    idx_3  <= idx_2;
end

// Stage 4: rounding and storage
wire [2*K_BITS-1:0] prod_rnd = prod_3 + {{2*K_BITS-6{1'b0}}, 6'b100000};
wire [P_BITS-1:0]   prod_shr = prod_rnd[2*K_BITS-1:6];
always @(posedge clk_i) begin
    if (rstn_i == 1'b0) begin
        kpg0_o <= {P_BITS{1'b0}};
        kig0_o <= {P_BITS{1'b0}};
        kdg0_o <= {P_BITS{1'b0}};
        kpg1_o <= {P_BITS{1'b0}};
        kig1_o <= {P_BITS{1'b0}};
        kdg1_o <= {P_BITS{1'b0}};
    end else begin
        case (idx_3)
            3'd0:    kpg0_o <= prod_shr;
            3'd1:    kig0_o <= prod_shr;
            3'd2:    kdg0_o <= prod_shr;
            3'd3:    kpg1_o <= prod_shr;
            3'd4:    kig1_o <= prod_shr;
            default: kdg1_o <= prod_shr;
        endcase
    end
end

endmodule
