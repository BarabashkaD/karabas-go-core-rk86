`timescale 1ps / 1ps
// An ideal PLL_BASE for simulation speed, compiled into work so it shadows the
// unisims_ver model (both the coregen pll.v and the netlist instantiate PLL_BASE).
// Outputs are ideal clocks of period CLKIN_PERIOD*DIVCLK_DIVIDE*CLKOUTn_DIVIDE/CLKFBOUT_MULT,
// 50 % duty, phase 0, started on a CLKIN rising edge after LOCK_CYCLES input cycles; LOCKED
// rises with them. RST, CLKFBIN, phases and duty cycles are ignored.
module PLL_BASE #(
	parameter BANDWIDTH = "OPTIMIZED",
	parameter CLK_FEEDBACK = "CLKFBOUT",
	parameter COMPENSATION = "SYSTEM_SYNCHRONOUS",
	parameter RESET_ON_LOSS_OF_LOCK = "FALSE",
	parameter integer DIVCLK_DIVIDE = 1,
	parameter integer CLKFBOUT_MULT = 1,
	parameter real CLKFBOUT_PHASE = 0.0,
	parameter real CLKIN_PERIOD = 10.0,
	parameter real REF_JITTER = 0.1,
	parameter integer CLKOUT0_DIVIDE = 1, parameter real CLKOUT0_PHASE = 0.0, parameter real CLKOUT0_DUTY_CYCLE = 0.5,
	parameter integer CLKOUT1_DIVIDE = 1, parameter real CLKOUT1_PHASE = 0.0, parameter real CLKOUT1_DUTY_CYCLE = 0.5,
	parameter integer CLKOUT2_DIVIDE = 1, parameter real CLKOUT2_PHASE = 0.0, parameter real CLKOUT2_DUTY_CYCLE = 0.5,
	parameter integer CLKOUT3_DIVIDE = 1, parameter real CLKOUT3_PHASE = 0.0, parameter real CLKOUT3_DUTY_CYCLE = 0.5,
	parameter integer CLKOUT4_DIVIDE = 1, parameter real CLKOUT4_PHASE = 0.0, parameter real CLKOUT4_DUTY_CYCLE = 0.5,
	parameter integer CLKOUT5_DIVIDE = 1, parameter real CLKOUT5_PHASE = 0.0, parameter real CLKOUT5_DUTY_CYCLE = 0.5,
	parameter integer LOCK_CYCLES = 16
) (
	output reg CLKFBOUT = 1'b0,
	output reg CLKOUT0 = 1'b0,
	output reg CLKOUT1 = 1'b0,
	output reg CLKOUT2 = 1'b0,
	output reg CLKOUT3 = 1'b0,
	output reg CLKOUT4 = 1'b0,
	output reg CLKOUT5 = 1'b0,
	output reg LOCKED = 1'b0,
	input CLKFBIN,
	input CLKIN,
	input RST
);
localparam real BASE = CLKIN_PERIOD * 1000.0 * DIVCLK_DIVIDE / CLKFBOUT_MULT / 2.0; // ps
integer n = 0;
always @(posedge CLKIN) if (!LOCKED) begin
	n = n + 1;
	if (n == LOCK_CYCLES) LOCKED <= 1'b1;
end
always @(posedge LOCKED) begin
	fork
		forever begin CLKOUT0 = 1'b1; #(BASE * CLKOUT0_DIVIDE); CLKOUT0 = 1'b0; #(BASE * CLKOUT0_DIVIDE); end
		forever begin CLKOUT1 = 1'b1; #(BASE * CLKOUT1_DIVIDE); CLKOUT1 = 1'b0; #(BASE * CLKOUT1_DIVIDE); end
		forever begin CLKOUT2 = 1'b1; #(BASE * CLKOUT2_DIVIDE); CLKOUT2 = 1'b0; #(BASE * CLKOUT2_DIVIDE); end
	join
end
// CLKOUT3..5 and CLKFBOUT are unused by the rk86 designs; CLKFBOUT follows CLKIN.
always @(CLKIN) CLKFBOUT = CLKIN;
endmodule
