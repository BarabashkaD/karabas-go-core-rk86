// The native dot stream of rk86_video for a platform without the Karabas framebuffer
// (docs/contract.md, section rk86_video_stream): the dot strobe, the visible area (data
// enable), the dot, the sync windows and the line and frame starts and ends, at the native
// dot rate. Combinational: no state, no clock. The inputs are the ports of rk86_video with
// the same names; all of them except pix_ce itself change only on the clk edge where
// pix_ce is high, so the outputs change on that edge too and hold until the next such
// edge. Sample every output on the clk edge where ce is high.
// No board top instantiates this module; the Karabas builds do not contain it.
`default_nettype none

module rk86_video_stream(
	// from rk86_video
	input  wire        pix_ce,
	input  wire        pix,
	input  wire        hrtc,         // active low: h_cnt 468..515
	input  wire        vrtc,         // active low: v_cnt 600..619
	input  wire [10:0] h_cnt,
	input  wire [10:0] v_cnt,
	// the stream
	output wire        ce,           // dot strobe (1 clk of 3 at clk 40 MHz without a clock enable)
	output wire        de,           // visible area: h_cnt 0..467 and v_cnt 0..599
	output wire        dot,          // the dot, 1 = lit; 0 outside de
	output wire        hs,           // horizontal sync, active high: h_cnt 468..515
	output wire        vs,           // vertical sync, active high: v_cnt 600..619
	output wire        line_start,   // first dot of a line (every line): h_cnt == 0
	output wire        frame_start,  // first dot of a frame, also the first dot of de
	output wire        line_end,     // last dot of de in a line: h_cnt == 467, v_cnt 0..599
	output wire        frame_end     // last dot of de in a frame: h_cnt == 467, v_cnt == 599
);

assign ce = pix_ce;
assign de = hrtc & vrtc;
assign dot = pix & de;
assign hs = ~hrtc;
assign vs = ~vrtc;
assign line_start = h_cnt == 11'd0;
assign frame_start = line_start && v_cnt == 11'd0;
assign line_end = de && h_cnt == 11'd467;
assign frame_end = line_end && v_cnt == 11'd599;

endmodule

`default_nettype wire
