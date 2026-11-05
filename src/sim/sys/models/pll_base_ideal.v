`timescale 1ps / 1ps
// An ideal PLL_BASE for simulation speed, compiled into work so it shadows the
// unisims_ver model (the coregen pll.v instantiates PLL_BASE).
// CLKOUT0..2 are ideal clocks of half period CLKIN_PERIOD*DIVCLK_DIVIDE*CLKOUTn_DIVIDE/CLKFBOUT_MULT/2,
// 50 % duty, phase 0. They start together on the CLKIN rising edge number START_CYCLES (t0)
// and every edge k is scheduled from absolute time, t0 + k*half (real, rounded per edge), so the
// outputs stay phase-aligned with each other and with CLKIN (no drift from rounded periods).
// LOCKED rises LOCK_OUT_CYCLES cycles of the slowest output after t0, a quarter of its period
// after one of its falling edges, and is moved by a quarter of the fastest half period if that
// time coincides with an edge of CLKIN or of any output. RST, CLKFBIN, phases and duty cycles
// are ignored; CLKOUT3..5 stay 0 (unused by the rk86 designs); CLKFBOUT follows CLKIN.
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
	parameter integer START_CYCLES = 16,
	parameter integer LOCK_OUT_CYCLES = 4
) (
	output CLKFBOUT,
	output reg CLKOUT0 = 1'b0,
	output reg CLKOUT1 = 1'b0,
	output reg CLKOUT2 = 1'b0,
	output CLKOUT3,
	output CLKOUT4,
	output CLKOUT5,
	output reg LOCKED = 1'b0,
	input CLKFBIN,
	input CLKIN,
	input RST
);
localparam real BASE = CLKIN_PERIOD * 1000.0 * DIVCLK_DIVIDE / CLKFBOUT_MULT / 2.0;   // ps
localparam real H0 = BASE * CLKOUT0_DIVIDE, H1 = BASE * CLKOUT1_DIVIDE, H2 = BASE * CLKOUT2_DIVIDE;
localparam real HMAX = (H0 > H1 ? (H0 > H2 ? H0 : H2) : (H1 > H2 ? H1 : H2));
localparam real HMIN = (H0 < H1 ? (H0 < H2 ? H0 : H2) : (H1 < H2 ? H1 : H2));
localparam real HIN = CLKIN_PERIOD * 1000.0 / 2.0;
assign CLKFBOUT = CLKIN;
assign {CLKOUT3, CLKOUT4, CLKOUT5} = 3'b000;

integer n = 0;
reg started = 1'b0;
real t0 = 0.0;
always @(posedge CLKIN) if (!started) begin
	n = n + 1;
	if (n == START_CYCLES) begin t0 = $realtime; started = 1'b1; end
end

// edge k of an output with half period h at t0 + k*h
task automatic run_clock(input integer which, input real h);
	integer k;
	real t;
	begin
		k = 0;
		forever begin
			t = t0 + k * h;
			if (t > $realtime) #(t - $realtime);
			case (which)
			0: CLKOUT0 = (k % 2 == 0);
			1: CLKOUT1 = (k % 2 == 0);
			2: CLKOUT2 = (k % 2 == 0);
			endcase
			k = k + 1;
		end
	end
endtask

function on_edge(input real t, input real h);
	real q;
	begin
		q = t / h;
		on_edge = ((q - $rtoi(q)) * h < 1.0) || (($rtoi(q) + 1.0 - q) * h < 1.0);
	end
endfunction

real tl;
always @(posedge started) begin
	fork
		run_clock(0, H0);
		run_clock(1, H1);
		run_clock(2, H2);
		begin
			tl = HMAX * (2.0 * LOCK_OUT_CYCLES + 1.5);   // a quarter period after a falling edge
			while (on_edge(tl, H0) || on_edge(tl, H1) || on_edge(tl, H2) || on_edge(tl, HIN))
				tl = tl + HMIN / 4.0;
			#(t0 + tl - $realtime) LOCKED = 1'b1;
		end
	join
end
endmodule
