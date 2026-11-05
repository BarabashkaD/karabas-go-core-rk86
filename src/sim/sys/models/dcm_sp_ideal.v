`timescale 1ps / 1ps
// An ideal DCM_SP for simulation speed (compiled into work, shadows unisims_ver).
// CLK0 follows CLKIN. CLKFX / CLKFX180 are ideal clocks of half period P*CLKFX_DIVIDE/CLKFX_MULTIPLY/2,
// P the CLKIN period measured over the first START_CYCLES rising edges; they start on the CLKIN
// rising edge number START_CYCLES (t0) and every edge k is scheduled from absolute time,
// t0 + k*half (real, rounded per edge), so they stay phase-aligned with CLKIN.
// LOCKED rises LOCK_OUT_CYCLES cycles of the slowest output (CLK0) after t0, a quarter of its
// period after one of its falling edges, moved by a quarter of the CLKFX half period if that time
// coincides with an edge. CLKIN_PERIOD is ignored (pllx5 declares 40 ns but is fed 25 ns);
// the other outputs are 0.
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
	parameter integer START_CYCLES = 16,
	parameter integer LOCK_OUT_CYCLES = 4
) (
	output CLK0, output CLK90, output CLK180, output CLK270,
	output CLK2X, output CLK2X180, output CLKDV,
	output reg CLKFX = 1'b0, output reg CLKFX180 = 1'b0,
	output reg LOCKED = 1'b0, output PSDONE, output [7:0] STATUS,
	input CLKIN, input CLKFB, input RST, input PSCLK, input PSEN, input PSINCDEC, input DSSEN
);
assign CLK0 = CLKIN;
assign {CLK90, CLK180, CLK270, CLK2X, CLK2X180, CLKDV, PSDONE} = 7'b0;
assign STATUS = 8'h00;

integer n = 0;
real t_first = 0.0, t0 = 0.0, period = 0.0, hfx = 0.0;
reg started = 1'b0;
always @(posedge CLKIN) if (!started) begin
	n = n + 1;
	if (n == 1) t_first = $realtime;
	if (n == START_CYCLES) begin
		t0 = $realtime;
		period = (t0 - t_first) / (START_CYCLES - 1);
		hfx = period * CLKFX_DIVIDE / (2.0 * CLKFX_MULTIPLY);
		started = 1'b1;
	end
end

function on_edge(input real t, input real h);
	real q;
	begin
		q = t / h;
		on_edge = ((q - $rtoi(q)) * h < 1.0) || (($rtoi(q) + 1.0 - q) * h < 1.0);
	end
endfunction

integer k;
real t, tl;
always @(posedge started) begin
	fork
		begin
			k = 0;
			forever begin
				t = t0 + k * hfx;
				if (t > $realtime) #(t - $realtime);
				CLKFX = (k % 2 == 0);
				CLKFX180 = (k % 2 != 0);
				k = k + 1;
			end
		end
		begin
			tl = period * (LOCK_OUT_CYCLES + 0.75);   // a quarter period after a falling edge of CLK0
			while (on_edge(tl, period / 2.0) || on_edge(tl, hfx))
				tl = tl + hfx / 4.0;
			#(t0 + tl - $realtime) LOCKED = 1'b1;
		end
	join
end
endmodule
