`timescale 1ps / 1ps
// An ideal DCM_SP for simulation speed (compiled into work, shadows unisims_ver).
// CLK0 follows CLKIN; CLKFX / CLKFX180 are ideal clocks of the measured CLKIN period
// * CLKFX_DIVIDE / CLKFX_MULTIPLY, started on a CLKIN edge after LOCK_CYCLES cycles.
// CLKIN_PERIOD is ignored (pllx5 declares 40 ns but is fed 25 ns); other outputs are 0.
module DCM_SP #(
	parameter real CLKDV_DIVIDE = 2.0,
	parameter integer CLKFX_DIVIDE = 1,
	parameter integer CLKFX_MULTIPLY = 4,
	parameter CLKIN_DIVIDE_BY_2 = "FALSE",
	parameter real CLKIN_PERIOD = 10.0,
	parameter CLKOUT_PHASE_SHIFT = "NONE",
	parameter CLK_FEEDBACK = "1X",
	parameter DESKEW_ADJUST = "SYSTEM_SYNCHRONOUS",
	parameter integer PHASE_SHIFT = 0,
	parameter STARTUP_WAIT = "FALSE",
	parameter integer LOCK_CYCLES = 16
) (
	output reg CLK0 = 1'b0, output CLK90, output CLK180, output CLK270,
	output CLK2X, output CLK2X180, output CLKDV,
	output reg CLKFX = 1'b0, output reg CLKFX180 = 1'b1,
	output reg LOCKED = 1'b0, output PSDONE, output [7:0] STATUS,
	input CLKIN, input CLKFB, input RST, input PSCLK, input PSEN, input PSINCDEC, input DSSEN
);
assign {CLK90, CLK180, CLK270, CLK2X, CLK2X180, CLKDV, PSDONE} = 7'b0;
assign STATUS = 8'h00;
always @(CLKIN) CLK0 = CLKIN;
integer n = 0;
time t_last = 0, period = 0;
always @(posedge CLKIN) if (!LOCKED) begin
	if (t_last != 0) period = $time - t_last;
	t_last = $time;
	n = n + 1;
	if (n == LOCK_CYCLES) LOCKED <= 1'b1;
end
real half;
always @(posedge LOCKED) begin
	half = period * CLKFX_DIVIDE / (2.0 * CLKFX_MULTIPLY);
	forever begin CLKFX = 1'b1; CLKFX180 = 1'b0; #(half); CLKFX = 1'b0; CLKFX180 = 1'b1; #(half); end
end
endmodule
