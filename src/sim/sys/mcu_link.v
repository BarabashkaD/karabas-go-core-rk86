`timescale 1ns / 1ps
// The MCU (RP2040) side of the link (karabas-go-firmware docs/protocol.md, docs/burst_protocol.md):
// classic 3-byte frames on cs_n, bursts on bcs_n, SPI mode 0, MSB first.
// Every transaction starts 1.234 ns after a falling edge of the reference clock; all later edges are
// multiples of 6.25 ns after it (half periods 31.25 / 15.625 ns, waits of 50 / 100 / 500 / 1000 ns), so
// they keep >= 1.2 ns from the edges of a 40 MHz clock. The RACE monitor reports any edge of SCK, MOSI or
// a chip select closer than 1 ns to an edge of the reference clock.
//   frame(cmd, addr, data, rc, ra, rd)   classic frame; rc/ra/rd: the bytes shifted out by the FPGA
//   burst(type, addr, n)                 burst write of bbuf[0..n-1] (waits for bready = 1 first)
//   caps_query(ok, caps, max_mhz)        CMD_CAPS {F7, 00, 01}, then up to 16 NOP frames for the answer
//                                        {F7, caps, max_mhz}; repeated up to 4 times
module mcu_link #(
	parameter integer HALF_PS = 31250,        // classic SCK half period
	parameter integer BURST_HALF_PS = 31250   // burst SCK half period
) (
	input refclk,
	output reg cs_n = 1'b1,
	output reg sck = 1'b0,
	output reg mosi = 1'b0,
	output reg bcs_n = 1'b1,
	input miso,
	input bready
);
reg [7:0] bbuf [0:511];
integer nframes = 0, nbursts = 0, nrace = 0;

reg armed = 1'b0;        // RACE monitor on from the first transaction (not on the initial values)

task align;
	begin
		@(negedge refclk);
		armed = 1'b1;
		#1.234;
	end
endtask

task spi_byte(input [7:0] tx, input integer half_ps, output [7:0] rx);
	integer i;
	reg [7:0] r;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			mosi = tx[i];
			#(half_ps / 1000.0);
			sck = 1'b1;
			r[i] = miso;
			#(half_ps / 1000.0);
			sck = 1'b0;
		end
		rx = r;
	end
endtask

task frame(input [7:0] c, input [7:0] a, input [7:0] d, output [7:0] rc, output [7:0] ra, output [7:0] rd);
	begin
		align;
		cs_n = 1'b0;
		#100;
		spi_byte(c, HALF_PS, rc);
		spi_byte(a, HALF_PS, ra);
		spi_byte(d, HALF_PS, rd);
		#50;
		cs_n = 1'b1;
		#500;
		nframes = nframes + 1;
	end
endtask

task burst(input [7:0] btype, input [31:0] addr, input integer n);
	integer i;
	reg [7:0] dummy;
	begin
		if (bready !== 1'b1) wait (bready === 1'b1);
		align;
		bcs_n = 1'b0;
		#100;
		spi_byte(btype, BURST_HALF_PS, dummy);
		spi_byte(addr[31:24], BURST_HALF_PS, dummy);
		spi_byte(addr[23:16], BURST_HALF_PS, dummy);
		spi_byte(addr[15:8], BURST_HALF_PS, dummy);
		spi_byte(addr[7:0], BURST_HALF_PS, dummy);
		for (i = 0; i < n; i = i + 1)
			spi_byte(bbuf[i], BURST_HALF_PS, dummy);
		bcs_n = 1'b1;    // right after the last byte, as the firmware
		#1000;
		nbursts = nbursts + 1;
	end
endtask

task caps_query(output ok, output [7:0] caps, output [7:0] max_mhz);
	integer round, i;
	reg [7:0] rc, ra, rd;
	begin
		ok = 1'b0;
		caps = 8'h00;
		max_mhz = 8'h00;
		for (round = 0; round < 4 && !ok; round = round + 1) begin
			frame(8'hF7, 8'h00, 8'h01, rc, ra, rd);
			for (i = 1; i <= 16 && !ok; i = i + 1) begin
				frame(8'hFF, 8'h00, 8'h00, rc, ra, rd);
				if (rc === 8'hF7) begin
					ok = 1'b1;
					caps = ra;
					max_mhz = rd;
					$display("LINK caps answer {F7, %h, %h} after query %0d, poll %0d (t=%0t)", ra, rd, round + 1, i, $time);
				end
			end
		end
	end
endtask

// RACE monitor
realtime t_ref = -100.0, t_sig = -100.0;
always @(refclk) begin
	t_ref = $realtime;
	if (armed && t_ref - t_sig < 1.0) begin
		nrace = nrace + 1;
		if (nrace <= 20) $display("RACE reference clock edge %0.3f ns after a link edge (t=%0t)", t_ref - t_sig, $time);
	end
end
always @(sck or mosi or cs_n or bcs_n) begin
	t_sig = $realtime;
	if (armed && t_sig - t_ref < 1.0) begin
		nrace = nrace + 1;
		if (nrace <= 20) $display("RACE link edge %0.3f ns after a reference clock edge (t=%0t)", t_sig - t_ref, $time);
	end
end
endmodule
