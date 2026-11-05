// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of Radio-86RK video output
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
// Modified by: Andy Karpov <andy.karpov@gmail.com> for WXEDA board
// The Karabas part: the font core, the framebuffer and the VGA output around
// rk86_video (rk86_video.v, the native video without board dependencies).
// 
// Design File: rk_video.v
//

module rk_video(
	input clk,
	output hr,
	output vr,
	output hr_wg75,
	output vr_wg75,
	output cce,
	output pixel,
	input[3:0] line,
	input[6:0] ichar,
	input vsp,
	input lten,
	input rvv,
	output[10:0] counter_x,
	output[10:0] counter_y,
	output blank
);

// rk related
reg[10:0] v_cnt2;
reg[1:0] v_cnt_line;

// native video (rk86_video.v): the timebase of the CRT, the dot shift register
wire[10:0] h_cnt;
wire[10:0] v_cnt;
wire pix_ce;
wire native_pix;
wire[9:0] font_addr;
wire[7:0] font_data;

rk86_video native(
	.clk(clk),
	.line(line),
	.ichar(ichar),
	.vsp(vsp),
	.lten(lten),
	.rvv(rvv),
	.cce(cce),
	.hrtc(hr_wg75),
	.vrtc(vr_wg75),
	.font_addr(font_addr),
	.font_data(font_data),
	.pix_ce(pix_ce),
	.pix(native_pix),
	.h_cnt(h_cnt),
	.v_cnt(v_cnt)
);

// framebuffer 408x300 (384x250 + gaps)
reg[17:0] address_in;
reg[17:0] address_out;
reg data_in;
wire data_out;

rambuffer framebuf(
	.clka(clk),
	.wea(1'b1),
	.addra(address_in),
	.dina(data_in),
	.douta(),
	
	.clkb(clk),
	.web(1'b0),
	.addrb(address_out),
	.dinb(),
	.doutb(data_out)
);

assign counter_x = CounterX;
assign counter_y = CounterY;

font from(.addra(font_addr), .clka(clk), .douta(font_data));

always @(posedge clk)
begin

	if (pix_ce)
	begin
		// write visible data to framebuffer
		if (h_cnt >= 60 && h_cnt < 468 && v_cnt2 >= 0 && v_cnt2 < 300 && v_cnt_line == 2'b00)
		begin
			address_in <= h_cnt - 60 + (10'd408*(v_cnt2 - 0));
			data_in <= native_pix;
			//data_in <= 1'b1; // test white screen
		end

		if (h_cnt+1'b1 == 10'd516) // 516 - end of line
		begin
			if (v_cnt+1'b1 == 10'd620 ) // 310 - end of frame
			begin
				v_cnt2 <= 0;
			end
			else begin 
				casex (v_cnt_line)
					2'b00: v_cnt_line <= 2'b01;
					2'b01: v_cnt_line <= 2'b00;
					2'b1x: v_cnt_line <= 2'b00;
				endcase
				if (v_cnt_line == 2'b00)
					v_cnt2 <= v_cnt2+1'b1;
			end
		end 
	end
end

// vga sync generator

wire[10:0] CounterX;
wire[10:0] CounterY;
wire inDisplay;

hvsync_generator vgasync(
	.clk(clk),
	.vga_h_sync(hr),
	.vga_v_sync(vr),
	.vga_blank(blank),
	.inDisplayArea(inDisplay),
	.CounterX(CounterX),
	.CounterY(CounterY)
);

// vga signal generator

reg[1:0] pixel_state;
reg[1:0] line_state;
reg[10:0] pixel_cnt;
reg[10:0] line_cnt;

assign pixel = data_out && inDisplay;

always @(posedge clk)
begin

	if (CounterX >= 0 && CounterX < 816 && CounterY >= 0 && CounterY < 600) // doubledot visible area
	begin

		casex (pixel_state)
		2'b00: pixel_state <= 2'b01;
		2'b01: pixel_state <= 2'b00;
		endcase

		address_out <= pixel_cnt + (line_cnt*408);
		
		if (pixel_state == 2'b01)
			pixel_cnt <= pixel_cnt + 1;

		if (CounterX+1 == 816) 
		begin
			pixel_cnt <= 0;
			casex (line_state)
			2'b00: line_state <= 2'b01;
			2'b01: line_state <= 2'b00;
			endcase
			if (line_state == 2'b01)
				line_cnt <= line_cnt + 1;
		end
						
		if (CounterY+1 == 600)
		begin
			line_cnt <= 0;
			pixel_cnt <= 0;
			line_state <= 0;
		end
	end
end

endmodule
