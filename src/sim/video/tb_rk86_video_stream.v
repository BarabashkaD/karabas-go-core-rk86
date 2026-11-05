// Self-checking testbench of rk86_video and rk86_video_stream (docs/contract.md, section
// rk86_video_stream), for iverilog; src/sim/video/run_video_sim.py builds and runs it.
// The CRT k580wg75 and the DMA k580wt57 are wired as in rk86_machine and programmed with
// the bytes of the stock BIOS (BIOS.BIN, FACF-FAFA) and the BIOS cursor sequence; the
// screen memory at 76D0 holds a known pattern with a reverse video field (attribute codes
// 90h and 80h) in one row. For four frames the testbench checks on every dot the outputs of
// rk86_video_stream against their definitions, the dot strobe and the frame and line
// lengths; on frames 2 and 3 it compares every dot with a rendering of the screen by
// FONT.BIN at the documented geometry, with the cursor (on in frame 2, off in frame 3:
// both blink phases) and the attributes.
// Plusarg +font=<path of FONT.BIN>; parameter FONT_LATENCY: clk from the edge where
// font_addr changes to font_data (0: combinational); parameter FRAMES: frames to run.
`default_nettype none

module tb_rk86_video_stream;

parameter FONT_LATENCY = 1;          // the font core of rk_video: 1 (no output register)
parameter FRAMES = 4;                // frames 0 to 3; the glyphs are checked on 2 and 3
localparam FRAME_CLK = 959760;       // 620 lines x 516 dots x 3 clk
localparam CUR_X = 11;               // the cursor: column 11, row 4 (BIOS coordinates)
localparam CUR_Y = 4;
localparam FRAME0 = 13;              // the frame counter of the CRT in frame 0: frame 2 has 15
                                     // (bit 3 set: cursor on), frame 3 has 16 (cursor off)
localparam AK = 10;                  // the row with the attributes
localparam AP = 20;                  // 90h (reverse video) at byte 20 of row AK
localparam AQ = 40;                  // 80h (normal) at byte AQ + 1 of row AK

reg clk = 1'b0;
always #1 clk = ~clk;

//--------- font ROM model --------------
reg [7:0] font [0:1023];
wire [9:0] font_addr;
wire [7:0] font_data;

generate
	if (FONT_LATENCY == 0) begin : g_rom0
		assign font_data = font[font_addr];
	end else begin : g_rom
		reg [7:0] font_pipe [1:FONT_LATENCY];
		integer j;
		assign font_data = font_pipe[FONT_LATENCY];
		always @(posedge clk) begin
			font_pipe[1] <= font[font_addr];
			for (j = 2; j <= FONT_LATENCY; j = j + 1)
				font_pipe[j] <= font_pipe[j - 1];
		end
	end
endgenerate

//--------- memory: the screen of the BIOS, 30 rows of 78 bytes at 76D0 --------------
reg [7:0] mem [0:65535];
wire [15:0] dma_addr;
wire [7:0] mem_o = mem[dma_addr];

// the pattern code at row k, column c of the screen
function [7:0] scr;
	input integer k;
	input integer c;
begin
	if (k == 3 && c == 8)
		scr = 8'h52;                 // 'R' at 77C2: the first character of the BIOS banner
	else
		scr = 8'h20 + (k * 7 + c) % 96;
end
endfunction

// byte o (0..77) of row k in the memory. Row AK: 90h at byte AP, 80h at byte AQ + 1. In
// the transparent attribute mode of the BIOS setup each attribute code takes a column and
// the CRT reads the byte after it into its fifo (k580wg75.v:168, 178-179), so the row
// reads one byte more per attribute; the end-of-row code F1h at byte 77 (column 75, never
// shown) stops the row after 78 bytes, so the rows below keep their place in the memory.
function [7:0] mem_byte;
	input integer k;
	input integer o;
begin
	if (k == AK && o == AP)
		mem_byte = 8'h90;
	else if (k == AK && o == AQ + 1)
		mem_byte = 8'h80;
	else if (k == AK && o == 77)
		mem_byte = 8'hF1;
	else
		mem_byte = scr(k, o);
end
endfunction

// the code shown at row k, column c (0..74): in row AK the column of an attribute shows
// the byte after it (k580wg75.v:149), the columns after it the bytes one further
function [7:0] disp;
	input integer k;
	input integer c;
begin
	if (k == AK && c >= AQ)
		disp = scr(k, c + 2);
	else if (k == AK && c >= AP)
		disp = scr(k, c + 1);
	else
		disp = scr(k, c);
end
endfunction

// reverse video at row k, column c: from the column of 90h to the column before 80h, on
// every line of the row (attr is restored from exattr on each line, k580wg75.v:127, 132);
// 80h ends it in the same row, so no attribute carries into the next row
function rev;
	input integer k;
	input integer c;
begin
	rev = k == AK && c >= AP && c < AQ;
end
endfunction

//--------- CPU side: the writes of the BIOS --------------
reg crt_a = 1'b0;
reg [7:0] crt_d = 8'h00;
reg crt_we_n = 1'b1;
reg [3:0] dma_a = 4'h0;
reg [7:0] dma_d = 8'h00;
reg dma_we_n = 1'b1;
reg dma_reset = 1'b1;

//--------- DMA and CRT, wired as in rk86_machine --------------
wire cce, hrtc, vrtc;
wire hlda;
wire [3:0] dma_dack;
wire crt_drq, crt_irq;
wire [3:0] line;
wire [6:0] ochar;
wire lten, vsp, rvv;

k580wt57 dma(.clk(clk), .ce(cce), .reset(dma_reset),
	.iaddr(dma_a), .idata(dma_d), .drq({1'b0,crt_drq,2'b00}), .iwe_n(dma_we_n), .ird_n(1'b1),
	.hlda(hlda), .hrq(hlda), .dack(dma_dack), .odata(), .oaddr(dma_addr),
	.owe_n(), .ord_n(), .oiowe_n(), .oiord_n());

k580wg75 crt(.clk(clk), .ce(cce),
	.iaddr(crt_a), .idata(crt_d), .iwe_n(crt_we_n), .ird_n(1'b1),
	.vrtc(vrtc), .hrtc(hrtc), .dack(dma_dack[2]), .ichar(mem_o), .drq(crt_drq), .irq(crt_irq),
	.odata(), .line(line), .ochar(ochar), .lten(lten), .vsp(vsp),
	.rvv(rvv), .hilight(), .lattr(), .gattr());

//--------- under test --------------
wire pix_ce, pix;
wire [10:0] h_cnt, v_cnt;
wire s_ce, s_de, s_dot, s_hs, s_vs, s_ls, s_fs, s_le, s_fe;

rk86_video vid(.clk(clk), .line(line), .ichar(ochar), .vsp(vsp), .lten(lten), .rvv(rvv),
	.cce(cce), .hrtc(hrtc), .vrtc(vrtc), .font_addr(font_addr), .font_data(font_data),
	.pix_ce(pix_ce), .pix(pix), .h_cnt(h_cnt), .v_cnt(v_cnt));

rk86_video_stream st(.pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc),
	.h_cnt(h_cnt), .v_cnt(v_cnt),
	.ce(s_ce), .de(s_de), .dot(s_dot), .hs(s_hs), .vs(s_vs),
	.line_start(s_ls), .frame_start(s_fs), .line_end(s_le), .frame_end(s_fe));

//--------- checker state --------------
integer errors = 0;
integer n_clk = 0;                   // clk edges from the start
integer gap = 0;                     // clk edges since the last ce
integer h = 0;                       // the dot sampled at this ce: dot h of line v
integer v = 0;
integer frame = -1;                  // the frame of that dot, from the first frame start
integer fs_clk = 0;                  // n_clk at the last frame start
integer n_dot = 0, n_de = 0, n_hs = 0, n_vs = 0, n_ls = 0, n_le = 0, n_fe = 0;
integer r_de = 0, r_hs = 0, r_vs = 0;        // rising edges of de, hs, vs
// coverage guards of the reference (dots checked per frame, lit dots of the reference)
integer n_glyph = 0, n_lit = 0, n_spot = 0, n_cur = 0, n_rev = 0;
integer n_dut = 0;                   // lit dots of the DUT (s_dot) in the frame
integer n_dut_nc = 0;                // the same, outside the cursor cell
integer dut2 = -1;                   // n_dut_nc of frame 2
reg dma_done = 1'b0;
reg done = 1'b0;
reg first = 1'b1;
reg prev_ce = 1'b0;
reg p_de = 1'b0, p_hs = 1'b0, p_vs = 1'b0;   // de, hs, vs of the previous dot
reg [30:0] prev_vec = 31'd0;
wire [30:0] vec = {h_cnt, v_cnt, pix, s_de, s_dot, s_hs, s_vs, s_ls, s_fs, s_le, s_fe};

// The expected dot (hh, vv) for the BIOS programming: column c on h 24+6c..29+6c (glyph
// bit 5 first), row k on v 20k..20k+19, scan row s = (v mod 20) / 2: glyph row s-1 on
// s = 1..8 (inverted under reverse video), blank on s = 0 and 9 except the cursor
// underline on s = 9 when the cursor is on (cur); code 0 (a blank glyph) on h 0..23, dark:
// no attribute is in effect at the start of any line of this screen.
function ref_pix;
	input integer hh;
	input integer vv;
	input cur;
	integer c, k, s;
	reg [7:0] w;
begin
	ref_pix = 1'b0;
	if (vv < 600 && hh >= 24) begin
		c = (hh - 24) / 6;
		k = vv / 20;
		s = (vv % 20) / 2;
		if (s == 9 && k == CUR_Y && c == CUR_X)
			ref_pix = cur;
		else if (s >= 1 && s <= 8) begin
			w = font[disp(k, c) * 8 + s - 1];
			if (rev(k, c))
				w = ~w;
			ref_pix = w[5 - (hh - 24) % 6];
		end
	end
end
endfunction

// the cursor blink phase of frame f: bit 3 of the frame counter of the CRT, which steps at
// each fall of vrtc (k580wg75.v:77, 122); frame f shows the counter FRAME0 + f
function cur_on;
	input integer f;
begin
	cur_on = ((FRAME0 + f) % 32) / 8 % 2 == 1;
end
endfunction

// 'R' (52h) at row 3, column 8, written out: h 72..77 (bit 5 on h 72), glyph rows
// 1E 11 11 1E 14 12 11 00 on v 62/63 .. 76/77, blank on v 60/61 and 78/79
function [5:0] spot_r;
	input integer vv;
begin
	case (vv)
	62, 63:  spot_r = 6'h1E;
	64, 65:  spot_r = 6'h11;
	66, 67:  spot_r = 6'h11;
	68, 69:  spot_r = 6'h1E;
	70, 71:  spot_r = 6'h14;
	72, 73:  spot_r = 6'h12;
	74, 75:  spot_r = 6'h11;
	default: spot_r = 6'h00;
	endcase
end
endfunction

task finish_run;
begin
	if (!done) begin
		done = 1'b1;
		if (errors == 0)
			$display("RESULT: PASS");
		else
			$display("RESULT: FAIL (%0d errors)", errors);
		$finish;
	end
end
endtask

task fail;
	input [8*64-1:0] what;
begin
	errors = errors + 1;
	if (errors <= 20)
		$display("ERROR: %0s: frame %0d h %0d v %0d (clk %0d)", what, frame, h, v, n_clk);
	if (errors == 20) begin
		$display("stopping after 20 errors");
		finish_run;
	end
end
endtask

task frame_done;
begin
	$display("frame %0d: clk %0d dots %0d de %0d hs %0d vs %0d line_start %0d line_end %0d frame_end %0d de_rise %0d hs_rise %0d vs_rise %0d glyph %0d spot %0d cursor %0d (%0s) reverse %0d lit %0d dut_lit %0d",
		frame, n_clk - fs_clk, n_dot, n_de, n_hs, n_vs, n_ls, n_le, n_fe, r_de, r_hs, r_vs,
		n_glyph, n_spot, n_cur, cur_on(frame) ? "on" : "off", n_rev, n_lit, n_dut);
	if (n_clk - fs_clk != FRAME_CLK)
		fail("frame length");
	if (n_dot != 319920 || n_de != 280800 || n_hs != 29760 || n_vs != 10320 || n_ls != 620)
		fail("dot counts of the frame");
	if (n_le != 600 || n_fe != 1)
		fail("line_end / frame_end counts of the frame");
	if (r_de != 600 || r_hs != 620 || r_vs != 1)
		fail("edge counts of the frame");
	if (frame >= 2) begin
		if (n_glyph != 284400 || n_spot != 120 || n_cur != 12 || n_rev != 1920)
			fail("glyph check counts");
		if (n_lit == 0)
			fail("no lit dot");
		if (n_dut != n_lit)
			fail("lit dots of the DUT differ from the reference");
		// the frames differ only in the cursor (on in frame 2, off in frame 3)
		if (frame == 2)
			dut2 = n_dut_nc;
		else if (n_dut_nc != dut2)
			fail("frames 2 and 3 differ in lit dots outside the cursor");
	end
end
endtask

task check_dot;
	reg e_de, e_hs, e_vs, e_ls, e_fs, e_le, e_fe, g;
	reg [5:0] row;
begin
	e_de = h < 468 && v < 600;
	e_hs = h >= 468;
	e_vs = v >= 600;
	e_ls = h == 0;
	e_fs = h == 0 && v == 0;
	e_le = e_de && h == 467;
	e_fe = e_le && v == 599;
	if (h_cnt !== h || v_cnt !== v) fail("h_cnt/v_cnt");
	if (s_de !== e_de) fail("de");
	if (s_hs !== e_hs) fail("hs");
	if (s_vs !== e_vs) fail("vs");
	if (s_ls !== e_ls) fail("line_start");
	if (s_fs !== e_fs) fail("frame_start");
	if (s_le !== e_le) fail("line_end");
	if (s_fe !== e_fe) fail("frame_end");
	if (s_dot !== (pix & s_de)) fail("dot is not pix & de");
	// edges, against the previous dot
	if (s_de && !p_de) begin
		r_de = r_de + 1;
		if (!s_ls) fail("de rises off line_start");
	end
	if (!s_de && p_de && !s_hs) fail("de falls off the rise of hs");
	if (s_hs && !p_hs) begin
		r_hs = r_hs + 1;
		if (h != 468) fail("hs rises off h_cnt 468");
	end
	if (s_vs && !p_vs) begin
		r_vs = r_vs + 1;
		if (!(h == 0 && v == 600)) fail("vs rises off line 600");
	end
	if (!s_vs && p_vs && !s_fs) fail("vs falls off frame_start");
	p_de = s_de;
	p_hs = s_hs;
	p_vs = s_vs;
	n_dot = n_dot + 1;
	if (s_de) n_de = n_de + 1;
	if (s_hs) n_hs = n_hs + 1;
	if (s_vs) n_vs = n_vs + 1;
	if (s_ls) n_ls = n_ls + 1;
	if (s_le) n_le = n_le + 1;
	if (s_fe) n_fe = n_fe + 1;
	// glyphs: every dot of de, and column 74 (h 468..473, inside hs) on the raw pix
	if (frame >= 2) begin
		g = ref_pix(h, v, cur_on(frame));
		if (s_dot === 1'b1) begin
			n_dut = n_dut + 1;
			if (!(v >= 98 && v < 100 && h >= 90 && h < 96)) n_dut_nc = n_dut_nc + 1;
		end
		if (e_de) begin
			n_glyph = n_glyph + 1;
			if (g) n_lit = n_lit + 1;
			if (s_dot !== g) fail("glyph dot");
		end else if (v < 600 && h < 474) begin
			n_glyph = n_glyph + 1;
			if (pix !== g) fail("column 74 (pix inside hs)");
		end
		if (v >= 60 && v < 80 && h >= 72 && h < 78) begin
			n_spot = n_spot + 1;
			row = spot_r(v);
			if (s_dot !== row[77 - h]) fail("R at row 3, column 8");
		end
		// the cursor underline: column 11 of row 4 (h 90..95), scan row 9 (v 98, 99): lit in
		// the on phase of the blink, dark in the off phase
		if (v >= 98 && v < 100 && h >= 90 && h < 96) begin
			n_cur = n_cur + 1;
			if (s_dot !== cur_on(frame)) fail("cursor at row 4, column 11");
		end
		// reverse video: columns 20..39 of row 10 (h 144..263), scan rows 1..8 (v 202..217)
		if (v >= 202 && v < 218 && h >= 144 && h < 264) begin
			n_rev = n_rev + 1;
			row = font[disp(AK, (h - 24) / 6) * 8 + (v - 200) / 2 - 1];
			if (s_dot !== ~row[5 - (h - 24) % 6]) fail("reverse video at row 10");
		end
	end
end
endtask

//--------- power-up, font, screen --------------
integer i, k, c, fd, b;
reg [8*512-1:0] font_file;

initial begin
	// power-up: the INIT values of the Go netlist (PR07 baseline): 0, except ipos (7F: a
	// set-type flip-flop); exwe_n / exrd_n are 0, so the CRT sees a write and a read edge
	// on the first clk (err is set, nothing of the picture changes). Frames 0 and 1 do not
	// depend on these values for the checks; the glyph checks start at frame 2. The frame
	// counter starts at FRAME0 = 13, so frames 2 and 3 have 15 and 16: the blinking cursor
	// is on in frame 2 and off in frame 3.
	vid.state = 2'd0;
	vid.d_cnt = 3'd0;
	vid.data = 6'd0;
	vid.h_cnt = 11'd0;
	vid.v_cnt = 11'd0;
	crt.init0 = 8'h00; crt.init1 = 8'h00; crt.init2 = 8'h00; crt.init3 = 8'h00;
	crt.enable = 1'b0; crt.inte = 1'b0; crt.dmae = 1'b0;
	crt.dmadelay = 3'd0; crt.dmalen = 2'd0;
	crt.curx = 7'd0; crt.cury = 6'd0;
	crt.chline = 5'd0; crt.attr = 6'd0; crt.exattr = 6'd0;
	crt.iposf = 4'd0; crt.oposf = 4'd0; crt.ipos = 7'h7F; crt.opos = 8'd0;
	crt.ypos = 6'd0; crt.frame = FRAME0;
	crt.lineff = 1'b0; crt.exwe_n = 1'b0; crt.exrd_n = 1'b0;
	crt.exvrtc = 1'b0; crt.exhrtc = 1'b0; crt.err = 1'b0; crt.vspfe = 1'b0;
	crt.pstate = 3'd0; crt.istate = 1'b0;
	crt.drq = 1'b0; crt.irq = 1'b0; crt.ochar = 7'd0;
	for (i = 0; i < 80; i = i + 1) begin
		crt.buf0[i] = 8'h00;
		crt.buf1[i] = 8'h00;
	end
	for (i = 0; i < 16; i = i + 1) begin
		crt.fifo0[i] = 7'h00;
		crt.fifo1[i] = 7'h00;
	end
	dma.channel = 2'd0;
	// the font
	if (!$value$plusargs("font=%s", font_file))
		font_file = "src/roms/FONT.BIN";
	fd = $fopen(font_file, "rb");
	if (fd == 0) begin
		$display("ERROR: cannot open the font %0s", font_file);
		$finish;
	end
	for (i = 0; i < 1024; i = i + 1) begin
		b = $fgetc(fd);
		if (b < 0) begin
			$display("ERROR: the font is shorter than 1024 bytes");
			$finish;
		end
		font[i] = b[7:0];
	end
	$fclose(fd);
	// the screen
	for (i = 0; i < 65536; i = i + 1)
		mem[i] = 8'h00;
	for (k = 0; k < 30; k = k + 1)
		for (c = 0; c < 78; c = c + 1)
			mem[16'h76D0 + k * 78 + c] = mem_byte(k, c);
end

//--------- stimulus: the BIOS sets up the CRT, waits for the end of the screen, sets up the DMA
task crt_wr;
	input a;
	input [7:0] d;
begin
	@(negedge clk); crt_a = a; crt_d = d; crt_we_n = 1'b0;
	@(negedge clk); @(negedge clk); crt_we_n = 1'b1;
	@(negedge clk); @(negedge clk);
end
endtask

task dma_wr;
	input [3:0] a;
	input [7:0] d;
begin
	@(negedge clk); dma_a = a; dma_d = d; dma_we_n = 1'b0;
	@(negedge clk); @(negedge clk); dma_we_n = 1'b1;
	@(negedge clk); @(negedge clk);
end
endtask

initial begin
	repeat (4) @(negedge clk);
	dma_reset = 1'b0;
	// FACF-FADF: reset; 78 characters, 30 rows, underline 9 / 10 lines, line mode 1 /
	// transparent attributes / blinking underline cursor / 8 retrace characters; start
	crt_wr(1'b1, 8'h00);
	crt_wr(1'b0, 8'h4D);
	crt_wr(1'b0, 8'h1D);
	crt_wr(1'b0, 8'h99);
	crt_wr(1'b0, 8'h93);
	crt_wr(1'b1, 8'h27);
	// FAE0-FAE6: wait for the end of the screen (status bit 5, irq)
	wait (crt_irq === 1'b1);
	// FAE7-FAFA: DMA mode 80 (autoload); channel 2: address 76D0, count 4923: 2340 bytes,
	// write-cycle bits as in the BIOS; the CRT takes the byte at dack; mode A4 (autoload,
	// channel 2 enabled)
	dma_wr(4'h8, 8'h80);
	dma_wr(4'h4, 8'hD0);
	dma_wr(4'h4, 8'h76);
	dma_wr(4'h5, 8'h23);
	dma_wr(4'h5, 8'h49);
	dma_wr(4'h8, 8'hA4);
	// the cursor, as the BIOS sets it: load cursor (80h), column, row
	crt_wr(1'b1, 8'h80);
	crt_wr(1'b0, CUR_X);
	crt_wr(1'b0, CUR_Y);
	dma_done = 1'b1;
	$display("font latency %0d clk; DMA programmed at frame %0d, v_cnt %0d", FONT_LATENCY, frame, v_cnt);
end

//--------- checker --------------
always @(posedge clk) if (!done) begin
	n_clk = n_clk + 1;
	if (!first && !prev_ce && vec !== prev_vec)
		fail("an output changed on an edge without pix_ce");
	if (s_ce !== pix_ce)
		fail("ce is not pix_ce");
	if (s_ce === 1'b1) begin
		// the Karabas configuration: clk 40 MHz without a clock enable
		if (!first && gap != 3)
			fail("the pix_ce period is not 3 clk");
		gap = 0;
		if (h == 0 && v == 0) begin
			if (frame >= 0)
				frame_done;
			frame = frame + 1;
			if (frame == FRAMES)
				finish_run;
			if (frame == 2 && !dma_done)
				fail("the DMA is not programmed before frame 2");
			fs_clk = n_clk;
			n_dot = 0; n_de = 0; n_hs = 0; n_vs = 0; n_ls = 0; n_le = 0; n_fe = 0;
			r_de = 0; r_hs = 0; r_vs = 0;
			n_glyph = 0; n_lit = 0; n_spot = 0; n_cur = 0; n_rev = 0; n_dut = 0; n_dut_nc = 0;
		end
		if (!done) begin
			check_dot;
			if (h == 515) begin
				h = 0;
				v = (v == 619) ? 0 : v + 1;
			end else
				h = h + 1;
		end
	end
	prev_vec = vec;
	prev_ce = s_ce;
	gap = gap + 1;
	first = 1'b0;
	if (!done && n_clk > (FRAMES + 1) * FRAME_CLK) begin
		fail("timeout");
		finish_run;
	end
end

endmodule

`default_nettype wire
