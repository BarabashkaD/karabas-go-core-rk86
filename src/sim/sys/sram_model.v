`timescale 1ns / 1ps
// Asynchronous SRAM, 128K x 8 (the byte lane 0 of the board SRAM; MA[20:17] must stay 0).
// Read: combinational while MRD_N = 0 and MWR_N = 1. Write: on the falling edge of the reference
// clock while MWR_N = 0 (mid-cycle: address and data have settled; glitches of a real asynchronous
// SRAM are not modelled). Write log simout/sram_wr.txt: one line per transaction (MWR_N falls, or
// MA / MD change while MWR_N stays low): "<cycle> <addr hex> <data hex> <changed 0/1>", changed = the
// value differed from the memory before the write.
// Plusargs: +RAM_INIT=00|ff|rand (default 00; rand: $random with a fixed seed), +ROMLOAD=preload
// (BIOSSD.BIN at 0x10000, BIOS.BIN at 0x11000 from roms/*.hex, for debugging), +SRAM_LOG=0 (no log).
//   dump(file, from, to)   one byte per line, hex
//   poke(addr, data)       write without a bus cycle
// Counters for the TB: nwr (transactions), nchg (changing ones), nhigh (access above 128K),
// nxwr / nxwr_chk (a write strobe, address or data with X / Z; _chk: while chk = 1).
// Event wr_ev with wr_a / wr_d / wr_changed: every write transaction (the lines of the log).
module sram_model(
	input refclk,
	input [63:0] cyc,
	input [20:0] ma,
	inout [7:0] md,
	input mwr_n,
	input mrd_n
);
reg [7:0] mem [0:131071];
reg chk = 1'b0;          // set by the TB after the ROM load
integer nwr = 0, nchg = 0, nhigh = 0, nxwr = 0, nxwr_chk = 0;
integer flog = 0, i, seed;
reg log_en = 1'b1;
reg [8*8-1:0] s;
reg prev_low = 1'b0;
reg [20:0] pa;
reg [7:0] pd;
reg changed;
// the last write transaction (one per log line, also without the log): wr_ev fires after the
// memory holds the new value
event wr_ev;
reg [16:0] wr_a = 17'd0;
reg [7:0] wr_d = 8'd0;
reg wr_changed = 1'b0;

assign md = (!mrd_n && mwr_n) ? mem[ma[16:0]] : 8'hzz;    // X on a strobe gives X on md

initial begin
	s = "00";
	if ($value$plusargs("RAM_INIT=%s", s)) ;
	seed = 1;
	for (i = 0; i < 131072; i = i + 1)
		mem[i] = (s == "ff") ? 8'hFF : (s == "rand") ? $random(seed) : 8'h00;
	if ($value$plusargs("ROMLOAD=%s", s) && s == "preload") begin
		$readmemh("roms/BIOSSD.hex", mem, 17'h10000, 17'h10FFF);
		$readmemh("roms/BIOS.hex", mem, 17'h11000, 17'h117FF);
		$display("SRAM preloaded: BIOSSD at 10000, BIOS at 11000");
	end
	if ($value$plusargs("SRAM_LOG=%s", s) && s == "0") log_en = 1'b0;
	if (log_en) flog = $fopen("simout/sram_wr.txt", "w");
end

always @(negedge refclk) begin
	if (mwr_n === 1'b0) begin
		if (^ma === 1'bx || ^md === 1'bx) begin
			nxwr = nxwr + 1;
			if (chk) nxwr_chk = nxwr_chk + 1;
			if (nxwr <= 10 || (chk && nxwr_chk <= 10))
				$display("SRAM write with X/Z: cycle %0d ma=%h md=%h (t=%0t)", cyc, ma, md, $time);
		end else begin
			if (ma[20:17] != 4'd0) begin
				nhigh = nhigh + 1;
				if (nhigh <= 10) $display("SRAM write above 128K: cycle %0d ma=%h (t=%0t)", cyc, ma, $time);
			end
			if (!prev_low || ma !== pa || md !== pd) begin
				changed = mem[ma[16:0]] !== md;
				nwr = nwr + 1;
				if (changed) nchg = nchg + 1;
				if (log_en) $fwrite(flog, "%0d %05h %02h %0d\n", cyc, ma[16:0], md, changed);
				mem[ma[16:0]] = md;
				wr_a = ma[16:0];
				wr_d = md;
				wr_changed = changed;
				-> wr_ev;
			end
			mem[ma[16:0]] = md;
		end
		prev_low = 1'b1;
		pa = ma;
		pd = md;
	end else begin
		if (mwr_n !== 1'b1) begin
			nxwr = nxwr + 1;
			if (chk) nxwr_chk = nxwr_chk + 1;
			if (nxwr <= 10 || (chk && nxwr_chk <= 10))
				$display("SRAM MWR_N = %b: cycle %0d (t=%0t)", mwr_n, cyc, $time);
		end
		prev_low = 1'b0;
	end
	if (mrd_n === 1'b0 && mwr_n === 1'b1 && ma[20:17] != 4'd0) begin
		nhigh = nhigh + 1;
		if (nhigh <= 10) $display("SRAM read above 128K: cycle %0d ma=%h (t=%0t)", cyc, ma, $time);
	end
end

task dump(input [8*64-1:0] fname, input integer from, input integer to);
	integer f, k;
	begin
		f = $fopen(fname, "w");
		for (k = from; k <= to; k = k + 1) $fwrite(f, "%02h\n", mem[k]);
		$fclose(f);
	end
endtask

task poke(input [16:0] addr, input [7:0] data);
	mem[addr] = data;
endtask

task flush;
	if (log_en) $fflush(flog);
endtask
endmodule
