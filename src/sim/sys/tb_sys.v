`timescale 1ns / 1ps
// System testbench of the RK86 core: the unchanged board top, an SRAM model, the MCU side of the link,
// the L0 pin trace, the frame capture and the chained scenario (chain.vh).
// fuse -d BOARD_GO (board_go.vh); BOARD_MINIG comes with board_minig.vh (plan Task 6).
// Outputs in simout/: events.txt ("<cycle> <name>"), trace.txt, frames.txt, sram_wr.txt.
// The run ends with "TB_CYCLES <n>" and "RESULT <chain> PASS|FAIL ..." in the log.
// Plusargs: +CHAIN=smoke (default), +RAM_INIT, +ROMLOAD=preload, +SRAM_LOG=0 (sram_model.v),
// +TRACE_FROM / +TRACE_TO (pin_trace.v), +VCD_FROM=<cycle> +VCD_TO=<cycle> (simout/tb.vcd of the whole
// TB hierarchy, debugging only).
module tb_sys;

// reference cycle counter: rising edges of refclk, so it is stable at the sampling (falling) edge
reg [63:0] cyc = 64'd0;

`ifdef BOARD_GO
`include "board_go.vh"
`elsif BOARD_MINIG
`include "board_minig.vh"
`else
`include "define_BOARD_GO_or_BOARD_MINIG.vh"
`endif

always @(posedge refclk) cyc <= cyc + 64'd1;

// events
integer fev = 0;
reg [8*32-1:0] last_event = "start";
task mark_event(input [8*32-1:0] name);
	begin
		$fwrite(fev, "%0d %0s\n", cyc, name);
		last_event = name;
		$display("EVENT %0s cycle %0d (t=%0t)", name, cyc, $time);
	end
endtask

// checks and errors of the scenario
integer nerr = 0;
reg xchk_en = 1'b0;

pin_trace #(.OBS_W(OBS_W), .NCNT(NCNT)) trace(.refclk(refclk), .cyc(cyc), .obs(obs), .cnt_sig(cnt_sig),
	.xchk_en(xchk_en));
frame_capture #(.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL)) frames(.refclk(refclk), .cyc(cyc), .hs(vid_hs),
	.vs(vid_vs), .rgb(vid_rgb), .last_event(last_event));

// VCD window (debugging)
reg [63:0] vcd_from = 64'hFFFFFFFFFFFFFFFF, vcd_to = 64'hFFFFFFFFFFFFFFFF;
initial begin
	if ($value$plusargs("VCD_FROM=%d", vcd_from)) begin
		if (!$value$plusargs("VCD_TO=%d", vcd_to)) vcd_to = vcd_from + 64'd10000;
		wait (cyc >= vcd_from);
		$dumpfile("simout/tb.vcd");
		$dumpvars(0, tb_sys);
		wait (cyc >= vcd_to);
		$dumpoff;
		$dumpflush;
	end
end

// register X-check of the sim copies (amendment A5): every rising edge of sim_ctl.xcheck runs the
// module-local checkers; returns the number of registers found X by this check
task xcheck_regs(input [8*32-1:0] when, output integer n);
	integer before;
	begin
		before = sim_ctl.xtotal;
		sim_ctl.xcheck = 1'b1;
		#1;
		n = sim_ctl.xtotal - before;
		$display("XCHECK REGS %0s: %0d registers X (verilog %0d, vhdl %0d in total) at cycle %0d", when, n,
			sim_ctl.xcount, sim_ctl.vxcount, cyc);
		sim_ctl.xcheck = 1'b0;
		#1;
	end
endtask

`include "chain.vh"

endmodule
