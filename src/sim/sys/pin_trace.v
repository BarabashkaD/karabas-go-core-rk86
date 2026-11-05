`timescale 1ns / 1ps
// L0 trace: a hash of the observed vector, sampled on every falling edge of the reference clock.
// Each bit of obs is classified by a continuous assignment (evaluated only when the bit changes):
// value ov (X/Z -> 0), mask ox (X or Z -> 1), oxo (X only). When {ov, ox, oxo} differs from the previous
// sample (any change of a bit between 0, 1, X and Z), the cycle number, then ov (64-bit words), then ox
// (64-bit words) are folded into h:
//   h = (h ^ w) * 64'h100000001B3; h = h ^ (h >> 29)      (amendment A1)
// (the product is computed as shifts and adds, 0x100000001B3 = 2^40 + 2^8 + 2^7 + 2^5 + 2^4 + 2^1 + 1;
// the self-test compares it with the multiplication). The run stops if h ever becomes X.
// Every WIN cycles a line goes to simout/trace.txt:
//   W <window> <first cycle> <hash hex> <changes> <rising edges of cnt_sig[NCNT-1]> ... <cnt_sig[0]>
// and h restarts from SEED. A self-test at time 0 checks that the hash is never X and changes with
// every bit of obs (0 -> 1) and of the mask (0 -> X).
// X-check: while xchk_en = 1, every changed sample with an X bit (Z is accepted: undriven inouts, MD
// between cycles), and the sample at the rising edge of xchk_en, print "XCHECK OBS ..." (first 20) and
// count nxobs.
// Plusargs: +TRACE_FROM=<cycle> +TRACE_TO=<cycle>: every change in the range goes to
// simout/trace_detail.txt as "<cycle> <ov hex> <ox hex>".
module pin_trace #(
	parameter integer OBS_W = 8,
	parameter integer NCNT = 1,
	parameter integer WIN = 4096
) (
	input refclk,
	input [63:0] cyc,
	input [OBS_W-1:0] obs,
	input [NCNT-1:0] cnt_sig,
	input xchk_en
);
localparam integer NW = (OBS_W + 63) / 64;
localparam [63:0] SEED = 64'hCBF29CE484222325;

integer ftr = 0, fdet = 0, nxobs = 0, nchg = 0, nwin = 0, k;
reg [63:0] h = SEED;
reg [63:0] win_first = 64'd0;
reg [OBS_W-1:0] pv, px, pxo;
reg [64*NW-1:0] vv, xx;
reg [63:0] tr_from = 64'hFFFFFFFFFFFFFFFF, tr_to = 64'd0;
reg first = 1'b1, prev_chk = 1'b0;
reg [31:0] cnt_total [0:NCNT-1];
reg [31:0] cnt_mark [0:NCNT-1];

// per-bit classification
wire [OBS_W-1:0] ov, ox, oxo;
genvar g;
generate
	for (g = 0; g < OBS_W; g = g + 1) begin : cls
		assign ov[g] = obs[g] === 1'b1;
		assign ox[g] = obs[g] !== 1'b0 && obs[g] !== 1'b1;
		assign oxo[g] = obs[g] === 1'bx;
	end
endgenerate

function [63:0] fold(input [63:0] h0, input [63:0] w);
	reg [63:0] t;
	begin
		t = h0 ^ w;
		t = (t << 40) + (t << 8) + (t << 7) + (t << 5) + (t << 4) + (t << 1) + t;    // t * 64'h100000001B3
		fold = t ^ (t >> 29);
	end
endfunction

function [63:0] fold_mul(input [63:0] h0, input [63:0] w);
	reg [63:0] t;
	begin
		t = (h0 ^ w) * 64'h100000001B3;
		fold_mul = t ^ (t >> 29);
	end
endfunction

function [63:0] fold_obs(input [63:0] h0, input [63:0] c, input [64*NW-1:0] v, input [64*NW-1:0] x);
	integer i;
	reg [63:0] t;
	begin
		t = fold(h0, c);
		for (i = 0; i < NW; i = i + 1) t = fold(t, v[64*i +: 64]);
		for (i = 0; i < NW; i = i + 1) t = fold(t, x[64*i +: 64]);
		fold_obs = t;
	end
endfunction

// classification of a test vector (self-test only), the same rules as the continuous assignments
function [64*NW-1:0] cls_v(input [OBS_W-1:0] o);
	integer i;
	begin
		cls_v = 0;
		for (i = 0; i < OBS_W; i = i + 1) cls_v[i] = o[i] === 1'b1;
	end
endfunction
function [64*NW-1:0] cls_x(input [OBS_W-1:0] o);
	integer i;
	begin
		cls_x = 0;
		for (i = 0; i < OBS_W; i = i + 1) cls_x[i] = o[i] !== 1'b0 && o[i] !== 1'b1;
	end
endfunction

// self-test (A1)
task selftest;
	integer i, bad, seed;
	reg [OBS_W-1:0] o;
	reg [63:0] base, h1, hx, hc, a, b;
	begin
		bad = 0;
		seed = 7;
		for (i = 0; i < 1000; i = i + 1) begin
			a = {$random(seed), $random(seed)};
			b = {$random(seed), $random(seed)};
			if (fold(a, b) !== fold_mul(a, b)) bad = bad + 1;
		end
		if (bad) $display("PIN_TRACE selftest: shift-add fold differs from the multiplication in %0d of 1000 cases", bad);
		o = 0;
		base = fold_obs(SEED, 64'd0, cls_v(o), cls_x(o));
		hc = fold_obs(SEED, 64'd1, cls_v(o), cls_x(o));
		if (^base === 1'bx || ^hc === 1'bx || hc == base) bad = bad + 1;
		for (i = 0; i < OBS_W; i = i + 1) begin
			o = 0; o[i] = 1'b1;
			h1 = fold_obs(SEED, 64'd0, cls_v(o), cls_x(o));
			o[i] = 1'bx;
			hx = fold_obs(SEED, 64'd0, cls_v(o), cls_x(o));
			if (^h1 === 1'bx || ^hx === 1'bx || h1 == base || hx == base || hx == h1) begin
				bad = bad + 1;
				if (bad <= 5) $display("PIN_TRACE selftest: bit %0d: base %h, 1 -> %h, X -> %h", i, base, h1, hx);
			end
		end
		if (bad) begin
			$display("FATAL PIN_TRACE selftest failed: %0d cases", bad);
			$finish;
		end else
			$display("PIN_TRACE selftest OK: fold = multiplication (1000 cases); %0d bits, each bit of obs and of the mask changes the hash",
				OBS_W);
	end
endtask

task write_window;
	begin
		$fwrite(ftr, "W %0d %0d %h %0d", nwin, win_first, h, nchg);
		for (k = NCNT - 1; k >= 0; k = k - 1) begin
			$fwrite(ftr, " %0d", cnt_total[k] - cnt_mark[k]);
			cnt_mark[k] = cnt_total[k];
		end
		$fwrite(ftr, "\n");
		nwin = nwin + 1;
		h = SEED;
		nchg = 0;
	end
endtask

// the last, partial window; called by the TB at the end of the run
task finish;
	begin
		write_window;
		$fflush(ftr);
		if (fdet) $fflush(fdet);
	end
endtask

generate
	for (g = 0; g < NCNT; g = g + 1) begin : counters
		initial begin cnt_total[g] = 0; cnt_mark[g] = 0; end
		always @(posedge cnt_sig[g]) cnt_total[g] = cnt_total[g] + 1;
	end
endgenerate

initial begin
	selftest;
	ftr = $fopen("simout/trace.txt", "w");
	if ($value$plusargs("TRACE_FROM=%d", tr_from) | $value$plusargs("TRACE_TO=%d", tr_to))
		fdet = $fopen("simout/trace_detail.txt", "w");
end

always @(negedge refclk) begin
	if (cyc >= win_first + WIN) begin    // windows of WIN cycles from cycle 0
		write_window;
		win_first = win_first + WIN;
	end
	if (first || ov !== pv || ox !== px || oxo !== pxo) begin
		vv = ov;
		xx = ox;
		h = fold_obs(h, cyc, vv, xx);
		if (^h === 1'bx) begin
			$display("FATAL PIN_TRACE hash is X at cycle %0d", cyc);
			$finish;
		end
		nchg = nchg + 1;
		if (fdet && cyc >= tr_from && cyc <= tr_to) $fwrite(fdet, "%0d %h %h\n", cyc, ov, ox);
		if (xchk_en && |oxo) begin
			nxobs = nxobs + 1;
			if (nxobs <= 20) $display("XCHECK OBS cycle %0d: X bits %h (t=%0t)", cyc, oxo, $time);
		end
		pv = ov;
		px = ox;
		pxo = oxo;
		first = 1'b0;
	end else if (xchk_en && !prev_chk && |oxo) begin
		nxobs = nxobs + 1;
		if (nxobs <= 20) $display("XCHECK OBS cycle %0d: X bits %h (t=%0t)", cyc, oxo, $time);
	end
	prev_chk = xchk_en;
end
endmodule
