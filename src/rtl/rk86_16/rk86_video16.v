// The video path of the Radio-86RK board up to the composite mixer (spec D13; Радио 1986 No. 5 Fig. 3,
// Kiselev 1.4 sheet 4): the font ROM D12 / U11 addressed by CC0-CC6 and LC0-LC2 of the 8275, selected off
// by VSP (dark dots); the shift register D15 / U13 (К155ИР13 / 74198) clocked by ИЕ4 QA, loading D0-D5 at
// the QA↑ with ИЕ4 count LOAD_STATE and shifting Q5 first; the К155ТМ2 D13.1 / U17A re-timing LTEN with
// the load strobe and clearing the shift register (the whole character line lit); RVV XORed at the
// output (U16D, Kiselev 1.4 only, D10). pix = 1 is a lit dot. HRTC and VRTC do not pass here.
// New for the 16 MHz machine (karabas-go-core-rk86, rk86_16/); modified BSD license, see ../../LICENSE.TXT.
`default_nettype none
module rk86_video16 #(parameter [3:0] LOAD_STATE = 4'd10) (
    input  wire       clk,
    input  wire       dot_ce,
    input  wire [3:0] cnt12,
    input  wire [6:0] cc,
    input  wire [3:0] lc,
    input  wire       vsp,
    input  wire       lten,
    input  wire       rvv,
    output wire [9:0] font_addr,
    input  wire [7:0] font_data,
    output wire       pix
);
assign font_addr = {cc, lc[2:0]};
reg [5:0] sh = 6'd0;
reg lt = 1'b0;
wire load = dot_ce && cnt12 == LOAD_STATE;
always @(posedge clk)
    if (load) begin
        sh <= vsp ? 6'd0 : font_data[5:0];
        lt <= lten;
    end else if (dot_ce) sh <= {sh[4:0], 1'b0};
assign pix = (lt | sh[5]) ^ rvv;
endmodule
`default_nettype wire
