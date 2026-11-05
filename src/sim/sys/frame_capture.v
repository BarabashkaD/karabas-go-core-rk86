`timescale 1ns / 1ps
// Video frames on the pins, sampled on every falling edge of the reference clock.
// A line starts at a rising edge of hs, a frame at a rising edge of vs. Checks: every line H_TOTAL
// clocks, every frame V_TOTAL lines (the first, partial line and frame are not checked); nbad_h /
// nbad_v count the violations, nlines the checked lines.
// Frame hash: SEED, then on every change of rgb the offset in the frame and the colour (X/Z -> 0) with
// its X/Z mask, folded as in pin_trace.v; at the end of the frame its length and line count.
// simout/frames.txt: "F <frame> <start cycle> <cycles> <lines> <hash hex> <last event> [snap <name>]".
//   snap(name)   blocks until the first complete frame that started at least SNAP_DELAY cycles after
//                the call (24 ms: one CRT frame) has ended; that frame is tagged with the name; a fatal
//                stop if it has not ended 4 VGA frames after that; snap_hash is its hash
//   snap_d(name, delay)  the same with another delay (cycles; >= 1: the frame must start after the call)
// last_hash / nframes: the hash and the count of the frames ended so far (the TB waits on them)
// simout/snaps.txt: the pixels of every snapped frame, for tools/render.py:
//   "SNAP <name> <frame> <start cycle>", then "<line> <x> <rgb hex>" on the first sample and on every
//   change of rgb (line: rising edges of hs since the rising edge of vs, from 0; x: samples since the
//   last rising edge of hs, from 0), then "END <frame> <cycles> <lines> <hash>"
module frame_capture #(
	parameter integer H_TOTAL = 1057,
	parameter integer V_TOTAL = 629,
	parameter integer SNAP_DELAY = 960000
) (
	input refclk,
	input [63:0] cyc,
	input hs,
	input vs,
	input [23:0] rgb,
	input [8*32-1:0] last_event
);
localparam [63:0] SEED = 64'hCBF29CE484222325;
integer ffr = 0, nframes = 0, nlines = 0, nbad_h = 0, nbad_v = 0;
integer hcnt = 0, lines = 0;
reg seen_hs = 1'b0, seen_vs = 1'b0, phs = 1'b0, pvs = 1'b0;
reg [63:0] fh = SEED, fstart = 64'd0;
reg [23:0] prgb = 24'd0;
reg snap_pending = 1'b0, snap_done = 1'b0;
reg [63:0] snap_after = 64'd0, snap_limit = 64'd0;
reg [8*32-1:0] snap_name;
reg [63:0] last_hash = 64'd0, snap_hash = 64'd0;

// colour value (X/Z -> 0) and X/Z mask, by continuous assignments
wire [23:0] cv, cx;
genvar g;
generate
	for (g = 0; g < 24; g = g + 1) begin : cls
		assign cv[g] = rgb[g] === 1'b1;
		assign cx[g] = rgb[g] !== 1'b0 && rgb[g] !== 1'b1;
	end
endgenerate

// the fold of pin_trace.v: t * 64'h100000001B3 as shifts and adds
function [63:0] fold(input [63:0] h0, input [63:0] w);
	reg [63:0] t;
	begin
		t = h0 ^ w;
		t = (t << 40) + (t << 8) + (t << 7) + (t << 5) + (t << 4) + (t << 1) + t;
		fold = t ^ (t >> 29);
	end
endfunction

// pixels of the snapped frames
integer fsnap = 0;
reg dumping = 1'b0, dfirst = 1'b1;
reg [23:0] dprgb = 24'd0;

initial begin
	ffr = $fopen("simout/frames.txt", "w");
	fsnap = $fopen("simout/snaps.txt", "w");
end

always @(negedge refclk) begin
	hcnt = hcnt + 1;
	if (hs === 1'b1 && phs === 1'b0) begin
		if (seen_hs) begin
			nlines = nlines + 1;
			if (hcnt != H_TOTAL) begin
				nbad_h = nbad_h + 1;
				if (nbad_h <= 10) $display("VIDEO line of %0d clocks (expected %0d) at cycle %0d", hcnt, H_TOTAL, cyc);
			end
		end
		seen_hs = 1'b1;
		hcnt = 0;
		lines = lines + 1;
	end
	if (vs === 1'b1 && pvs === 1'b0) begin
		if (seen_vs) begin
			fh = fold(fh, cyc - fstart);
			fh = fold(fh, lines);
			if (lines != V_TOTAL) begin
				nbad_v = nbad_v + 1;
				if (nbad_v <= 10) $display("VIDEO frame of %0d lines (expected %0d) at cycle %0d", lines, V_TOTAL, cyc);
			end
			$fwrite(ffr, "F %0d %0d %0d %0d %h %0s", nframes, fstart, cyc - fstart, lines, fh, last_event);
			if (dumping) begin
				$fwrite(fsnap, "END %0d %0d %0d %h\n", nframes, cyc - fstart, lines, fh);
				dumping = 1'b0;
			end
			if (snap_pending && fstart >= snap_after) begin
				$fwrite(ffr, " snap %0s", snap_name);
				$display("SNAP %0s: frame %0d, start cycle %0d, hash %h", snap_name, nframes, fstart, fh);
				snap_hash = fh;
				snap_pending = 1'b0;
				snap_done = 1'b1;
			end
			$fwrite(ffr, "\n");
			last_hash = fh;
			nframes = nframes + 1;
		end
		seen_vs = 1'b1;
		fh = SEED;
		fstart = cyc;
		lines = 0;
		prgb = 24'd0;
		// the frame of a pending snap (the first that starts SNAP_DELAY after the call) is dumped
		if (snap_pending && cyc >= snap_after) begin
			dumping = 1'b1;
			$fwrite(fsnap, "SNAP %0s %0d %0d\n", snap_name, nframes, cyc);
		end
	end
	if (seen_vs && rgb !== prgb) begin
		fh = fold(fh, cyc - fstart);
		fh = fold(fh, {16'd0, cx, cv});
		prgb = rgb;
	end
	if (dumping && (rgb !== dprgb || dfirst)) begin
		$fwrite(fsnap, "%0d %0d %h\n", lines, hcnt, rgb);
		dprgb = rgb;
		dfirst = 1'b0;
	end
	if (!dumping) dfirst = 1'b1;
	phs = hs;
	pvs = vs;
end

task snap(input [8*32-1:0] name);
	snap_d(name, SNAP_DELAY);
endtask

task snap_d(input [8*32-1:0] name, input [63:0] delay);
	begin
		snap_name = name;
		snap_after = cyc + delay;
		snap_done = 1'b0;
		snap_pending = 1'b1;
		snap_limit = snap_after + 4 * H_TOTAL * V_TOTAL;    // the frame must end within 4 VGA frames
		wait (snap_done || cyc >= snap_limit);
		if (!snap_done) tb_sys.fatal("frame_capture: snap without a complete frame within the delay + 4 VGA frames");
	end
endtask

task finish;
	begin
		$fflush(ffr);
		$fflush(fsnap);
	end
endtask
endmodule
