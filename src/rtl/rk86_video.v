// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// The native Radio-86RK video without board dependencies (docs/contract.md): the
// timebase of the CRT (cce, hrtc, vrtc) and the dot shift register of the glyph row.
// The code is the one of rk_video.v (Dmitry Tselikov, Andy Karpov), moved without
// changes. The font ROM is outside, on font_addr / font_data (latency 1 clk); rk_video.v
// adds the font core, the framebuffer and the VGA output of the Karabas boards.
//
// Design File: rk86_video.v
//
`default_nettype none

module rk86_video(
	input  wire        clk,
	// from the CRT (rk86_machine)
	input  wire  [3:0] line,
	input  wire  [6:0] ichar,
	input  wire        vsp,
	input  wire        lten,
	input  wire        rvv,
	// timebase to the CRT: character clock enable, sync inputs (active low)
	output wire        cce,
	output wire        hrtc,
	output wire        vrtc,
	// font ROM of the board: font_data is the glyph row of font_addr one clk later
	output wire  [9:0] font_addr,
	input  wire  [7:0] font_data,
	// native picture: one dot per 3 clk
	output wire        pix_ce,    // high 1 clk of 3: pix, h_cnt, v_cnt step at its clk edge
	output wire        pix,       // the dot, 1 = lit
	output reg  [10:0] h_cnt,     // dot of the line, 0..515
	output reg  [10:0] v_cnt      // line of the frame, 0..619
);

// The names of rk_video, so that the code below is the moved code.
wire hr_wg75;
wire vr_wg75;
wire[7:0] fdata = font_data;

// rk related
reg[1:0] state;
reg[2:0] d_cnt;
reg[5:0] data;

assign hr_wg75 = h_cnt >= 10'd468 && h_cnt < 10'd516 ? 1'b0 : 1'b1; // wg75 hsync 
assign vr_wg75 = v_cnt >= 10'd600 && v_cnt < 10'd620 ? 1'b0 : 1'b1; // wg75 vsync 
assign cce = d_cnt==3'b000 && state == 2'b01; // wg75 chip enable signal 

assign font_addr = {ichar[6:0],line[2:0]};

always @(posedge clk)
begin

	// 3x divider to get 16MHz clock from 48MHz
	casex (state)
	2'b00: state <= 2'b01;
	2'b01: state <= 2'b10;
	2'b1x: state <= 2'b00;
	endcase

	if (state == 2'b00)
	begin
		if (d_cnt==3'b101) 
			data <= lten ? 6'h3F : vsp ? 6'b0 : fdata[5:0]^{6{rvv}};
		else
			data <= {data[4:0],1'b0};

		if (h_cnt+1'b1 == 10'd516) // 516 - end of line
		begin
			h_cnt <= 0; 
			d_cnt <= 0;
			if (v_cnt+1'b1 == 10'd620 ) // 310 - end of frame
			begin
				v_cnt <= 0;
			end
			else begin 
				v_cnt <= v_cnt+1'b1;
			end
		end 
		else 
		begin
			h_cnt <= h_cnt+1'b1;
			if (d_cnt+1'b1 == 3'b110) // end of char
				d_cnt <= 0;
			else
				d_cnt <= d_cnt+1'b1;
		end
	end
end

//--------- outputs --------------
assign hrtc   = hr_wg75;
assign vrtc   = vr_wg75;
assign pix_ce = state == 2'b00;
assign pix    = data[5];

endmodule

`default_nettype wire
