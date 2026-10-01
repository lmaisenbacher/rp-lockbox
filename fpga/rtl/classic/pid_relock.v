/*
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, Lothar Maisenbacher 
 *
 * All rights reserved.
 *
 * Generates a triangle wave sweep of increasing amplitude if signal_i is not
 * between min_val_i and max_val_i.
 *
 * While freeze_i is high (the holdoff after a switch of the parameter set),
 * the lock state can go from unlocked to locked but not back: a transient of
 * signal_i outside the window then neither counts as a drop nor starts the
 * sweep, while an unlocked loop can still catch the resonance.
 *
 * Based on code by David Leibrandt (National Institute of Standards and 
 * Technology)
 */
`timescale 1ns / 1ps

module pid_relock #(
    parameter STEPSR    = 18,// slew rate (DAC counts per clock cycle) =
                             //stepsize >> STEPSR
    parameter STEP_BITS = 24
)
(
    input  wire                        clk_i,
    input  wire                        on_i,
    input  wire        [12-1:0]        min_val_i,
    input  wire        [12-1:0]        max_val_i,
    input  wire        [STEP_BITS-1:0] stepsize_i,
    input  wire        [12-1:0]        signal_i,
    input  wire        [1:0]           railed_i, // 0th bit: lower rail, 1st 
                                                 // bit: upper rail
    input  wire                        hold_i,
    input  wire                        freeze_i,  // no locked -> unlocked transition
    output wire                        hold_o,
    output wire                        locked_o,  // lock state
    output reg                         in_window_o, // signal_i within the window, not frozen
    output reg                         clear_o,
    output wire signed [14-1:0]        signal_o
);

// Is there auxiliary signal within the desired range,
// indiciating we are close to a resonance?
wire in_window = (min_val_i < signal_i) && (signal_i < max_val_i);
reg near_resonance;
always @(posedge clk_i) begin
    in_window_o <= in_window;
    if (in_window || (freeze_i && near_resonance)) begin
        near_resonance <= 1'b1;
    end else begin
        near_resonance <= 1'b0;
    end
end
assign locked_o = near_resonance;

// Are we locked?
reg locked_f;
always @(posedge clk_i) begin
    if (in_window || (freeze_i && locked_f) || !on_i) begin
        locked_f <= 1'b1;
        clear_o <= 1'b0;
    end else begin
        locked_f <= 1'b0;
        if (locked_f && (railed_i[0] || railed_i[1]))
            /* if we just became unlocked and we're railed, send the signal to
              reset the loop filter integrators
            */
            clear_o <= 1'b1;
        else
            clear_o <= 1'b0;
    end
end

assign hold_o = (on_i && (!locked_f));

// State machine definitions
localparam ZERO      = 2'b00;
localparam GOINGUP   = 2'b01;
localparam GOINGDOWN = 2'b10;

// State
reg        [1:0]         state_f;
reg signed [14+STEPSR:0] current_val_f;
reg signed [14+STEPSR:0] sweep_amplitude_f;

// The step size as a signed value of the width of the sweep, zero-extended:
// always positive, and shifted by 8 for the start amplitude without losing
// bits (stepsize_i itself would read as negative from bit 23 on, and shifted
// at its own width it lost its upper bits)
localparam AMP_BITS = 14 + STEPSR + 1;
wire signed [AMP_BITS-1:0] step = {{(AMP_BITS-STEP_BITS){1'b0}}, stepsize_i};
// The amplitude up to which the sweep amplitude is doubled (full scale)
localparam signed [AMP_BITS-1:0] AMP_MAX = {1'b0, 14'h1FFF, {STEPSR{1'b0}}};
// One step up or down, saturating at the ends of the range: the sweep runs up
// to one step beyond its amplitude, which can exceed the range at large steps
localparam signed [AMP_BITS-1:0] VAL_POS = {1'b0, {(AMP_BITS-1){1'b1}}};
localparam signed [AMP_BITS-1:0] VAL_NEG = {1'b1, {(AMP_BITS-1){1'b0}}};
wire signed [AMP_BITS:0] val_up   = current_val_f + step;
wire signed [AMP_BITS:0] val_down = current_val_f - step;

// State machine
always @(posedge clk_i) begin
    if (!on_i) begin // relock off
        current_val_f <= {14+STEPSR+1{1'b0}};
        sweep_amplitude_f <= {14+STEPSR+1{1'b0}};
        state_f <= ZERO;
    end else begin
        if (!hold_i) begin
            if (state_f == GOINGUP)
                current_val_f <= (val_up[AMP_BITS] != val_up[AMP_BITS-1]) ? VAL_POS : val_up[AMP_BITS-1:0];
            else if (state_f == GOINGDOWN)
                current_val_f <= (val_down[AMP_BITS] != val_down[AMP_BITS-1]) ? VAL_NEG : val_down[AMP_BITS-1:0];
            else
                current_val_f <= {14+STEPSR+1{1'b0}};

            if (locked_f) begin // if we're locked, go towards zero
                sweep_amplitude_f <= {14+STEPSR+1{1'b0}};
                if (current_val_f > step)
                    state_f <= GOINGDOWN;
                else if (current_val_f < -step)
                    state_f <= GOINGUP;
                else
                    state_f <= ZERO;
            end else begin // otherwise, implement a sweep of increasing amplitude
                if (state_f == ZERO) begin
                    state_f <= GOINGUP;
                end else if ((current_val_f > sweep_amplitude_f) || railed_i[1]) begin
                    state_f <= GOINGDOWN;
                    if (state_f == GOINGUP) begin // increase the sweep amplitude every time we transition from GOINGUP to GOINGDOWN
                        if (sweep_amplitude_f == {14+STEPSR+1{1'b0}})
                            sweep_amplitude_f <= step <<< 8; // start amplitude = 256*stepsize
                        else if (sweep_amplitude_f < AMP_MAX)
                            sweep_amplitude_f <= (sweep_amplitude_f <<< 1); // double sweep amplitude
                    end
                end else if ((current_val_f < -sweep_amplitude_f) || railed_i[0]) begin
                    state_f <= GOINGUP;
                end
            end
        end
    end
end

// saturation
assign signal_o = (^current_val_f[14+STEPSR:14+STEPSR-1])?
                  {current_val_f[14+STEPSR], {13{~current_val_f[14+STEPSR]}}}:
                  current_val_f[14+STEPSR-1:STEPSR];

endmodule
