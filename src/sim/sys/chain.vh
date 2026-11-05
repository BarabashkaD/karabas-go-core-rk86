// The chained scenario of tb_sys (included in the module): the prologue (the core start sequence of
// the firmware), the idle link of the firmware after it, and the chains selected by +CHAIN=<name>:
//   smoke   prologue + SMOKE_MS (+SMOKE_MS=<ms>, default 5) ms: no X on the observed pins after the
//           ROM load, no RACE, the CPU reads the ROM (0x10800..0x10FFF) after the loader drops, the VGA
//           line period, no SRAM write with X after the ROM load, no access above 128K, the ROMs in the SRAM
//           equal to the ROM files.
//   basic   the works scenario (plan Task 4): the smoke criteria over the whole run, and
//           CP1 prompt  the monitor writes "-->" one row below its banner "radio-86rk" (event prompt;
//                       timeout 400 ms after init_done, then simout/ram_timeout.hex and FAIL)
//           CP2         snap("prompt"): simout/snaps.txt (the frame) and simout/ram_prompt.hex (RAM 0..7FFF)
//           CP3         field attributes poked into the screen rows 28-29 (no bus cycle), snap("attr"),
//                       simout/ram_attr.hex
//           CP4         keys: D (HID 07, echo 44h), left Shift + 1 (HID 02 / 1E, echo 21h; another code is
//                       a FAIL, amendment A10), each echoed in the cell after the prompt (timeout 300 ms),
//                       released, 10 ms pause; snap("keys"), simout/ram_keys.hex; then snap("keys2") of the
//                       frame after the next change of the picture (the other cursor phase), ram_keys2.hex
//           The RAM 0000-7FFF at every event: simout/ev_<n>_<name>.hex (L1 of tools/compare_runs.py).
//           The pictures and the screen text are checked on the host (tools/run_host_checks.py: render.py,
//           screen.py golden text); their verdict is a part of the run verdict.
// +STOP_AT=<cycle> ends any chain there (detail runs of the L0 comparison).
// Idle link after CMD_INIT_DONE (karabas-go-firmware docs/protocol.md section 2, link_poll(); RTC section 6):
// a CMD_NOP frame when the link was idle for +NOP_US=<us> (default 100; 0 = off; the period of the
// firmware main loop is not known, an assumption), the RTC time registers every 500 ms (the phase of that
// timer of the firmware is arbitrary: the first send 250 ms after init_done).

reg [7:0] rom_biossd [0:4095];
reg [7:0] rom_bios [0:2047];
reg [8*16-1:0] chain_name;
reg caps_ok = 1'b0;
reg [7:0] caps = 8'h00, caps_mhz = 8'h00;
reg [7:0] rc, ra, rd;

// CPU reads after the ROM load (rom_phase): the first read and the read cycles in the BIOS window
reg rom_phase = 1'b0, first_rd_seen = 1'b0;
reg [20:0] first_rd_a = 21'd0;
reg [63:0] first_rd_cyc = 64'd0, rom_done_cyc = 64'd0;
integer nrom = 0;
always @(negedge refclk)
	if (rom_phase && sram_rd_n === 1'b0 && sram_wr_n === 1'b1) begin
		if (!first_rd_seen) begin
			first_rd_seen = 1'b1;
			first_rd_a = sram_a;
			first_rd_cyc = cyc;
		end
		if (sram_a >= 21'h10800 && sram_a <= 21'h10FFF) nrom = nrom + 1;
	end

// ---- the link: one transaction at a time (the chain and the idle poller share it)
reg link_busy = 1'b0, poll_en = 1'b0;
reg [63:0] link_last = 64'd0, rtc_last = 64'd0;
integer nop_cyc = 4000, nnop = 0, nreply = 0, nrtc_time = 0;
reg [7:0] pc_, pa_, pd_;

task link_frame(input [7:0] c, input [7:0] a, input [7:0] d);
	begin
		wait (!link_busy);
		link_busy = 1'b1;
		link.frame(c, a, d, rc, ra, rd);
		link_last = cyc;
		link_busy = 1'b0;
	end
endtask

// ROM data through bursts of up to 512 bytes (CMD_ROMDATA, burst type 07)
task romload(input integer which, input [31:0] addr, input integer len);
	integer off, n, i;
	begin
		for (off = 0; off < len; off = off + 512) begin
			n = (len - off > 512) ? 512 : len - off;
			for (i = 0; i < n; i = i + 1)
				link.bbuf[i] = which ? rom_bios[off + i] : rom_biossd[off + i];
			wait (!link_busy);
			link_busy = 1'b1;
			link.burst(8'h07, addr + off, n);
			link_last = cyc;
			link_busy = 1'b0;
		end
	end
endtask

// switches: CMD_SWITCHES (index, value)
task switch(input [7:0] idx, input [7:0] val);
	link_frame(8'h05, idx, val);
endtask

// keyboard: one HID boot report, CMD_USB_KBD 0 = modifiers, 1 = the key code, 2..6 = 0
task kbd(input [7:0] mods, input [7:0] code);
	integer i;
	begin
		link_frame(8'h01, 8'h00, mods);
		link_frame(8'h01, 8'h01, code);
		for (i = 2; i <= 6; i = i + 1)
			link_frame(8'h01, i, 8'h00);
	end
endtask

// RTC (CMD_RTC register, value) as the firmware sends it for an MC146818A (rtc_mode absent in core.json:
// 0) with an erased EEPROM bank (FFh: register A reads 26h, B 02h = 24 h, BCD), lib/rtc/rtc.c send_time() /
// rtc_send_all(); the time is fixed: 2026-11-05 12:00:00, day of week 5 (BCD)
task rtc_time;
	begin
		link_frame(8'hFA, 8'h00, 8'h00);   // seconds
		link_frame(8'hFA, 8'h02, 8'h00);   // minutes
		link_frame(8'hFA, 8'h04, 8'h12);   // hours
		link_frame(8'hFA, 8'h06, 8'h05);   // day of week
		link_frame(8'hFA, 8'h07, 8'h05);   // day
		link_frame(8'hFA, 8'h08, 8'h11);   // month
		link_frame(8'hFA, 8'h09, 8'h26);   // year
	end
endtask
task rtc_all;
	integer r;
	reg [7:0] v;
	begin
		rtc_time;
		for (r = 0; r <= 255; r = r + 1) begin
			case (r)
			1, 3, 5: v = 8'h00;               // alarms 0 (BCD)
			8'h0A: v = 8'h26;                 // register A, UIP cleared
			8'h0B: v = 8'h02;                 // register B: 24 h, BCD, SET cleared
			8'h0C: v = 8'h00;
			8'h0D: v = 8'h80;
			default: v = 8'hFF;               // the EEPROM bank (also over the time registers, as the firmware)
			endcase
			link_frame(8'hFA, r, v);
		end
	end
endtask

// the idle link of the firmware main loop after CMD_INIT_DONE
always @(negedge refclk)
	if (poll_en && !link_busy) begin
		if (cyc - rtc_last >= 64'd20000000) begin       // 500 ms
			rtc_last = cyc;
			rtc_time;
			nrtc_time = nrtc_time + 1;
		end else if (nop_cyc > 0 && cyc - link_last >= nop_cyc) begin
			link_busy = 1'b1;
			link.frame(8'hFF, 8'h00, 8'h00, pc_, pa_, pd_);
			link_last = cyc;
			link_busy = 1'b0;
			nnop = nnop + 1;
			if (pc_ !== 8'hFF && pc_ !== 8'h00) begin
				nreply = nreply + 1;
				if (nreply <= 20) $display("LINK reply frame {%h, %h, %h} to a NOP at cycle %0d", pc_, pa_, pd_, cyc);
			end
		end
	end

// the SRAM holds both ROMs after the load (TB paths only: sram_model memory and the ROM images of the TB)
integer nrom_bad = 0;
task rom_compare;
	integer i;
	begin
		nrom_bad = 0;
		for (i = 0; i < 4096; i = i + 1)
			if (sram.mem[17'h10000 + i] !== rom_biossd[i]) begin
				nrom_bad = nrom_bad + 1;
				if (nrom_bad <= 10) $display("ERROR ROM in SRAM: %05h = %h, BIOSSD.BIN[%03h] = %h", 17'h10000 + i[16:0],
					sram.mem[17'h10000 + i], i[11:0], rom_biossd[i]);
			end
		for (i = 0; i < 2048; i = i + 1)
			if (sram.mem[17'h11000 + i] !== rom_bios[i]) begin
				nrom_bad = nrom_bad + 1;
				if (nrom_bad <= 10) $display("ERROR ROM in SRAM: %05h = %h, BIOS.BIN[%03h] = %h", 17'h11000 + i[16:0],
					sram.mem[17'h11000 + i], i[11:0], rom_bios[i]);
			end
		if (nrom_bad) nerr = nerr + 1;
		$display("ROM compare: SRAM 10000..117FF against BIOSSD.BIN + BIOS.BIN: %0d bytes differ", nrom_bad);
	end
endtask

// the core start sequence of the firmware, in the order of its code (karabas-go-firmware
// src/fpga/core_loader.c configure() and read_core()): CMD_CAPS query, CMD_INIT_START, CMD_HW_SETUP 0 / 1,
// [OSD font], read_core(): rtc_send_all(), core_send_all() (the switches in the order of the OSD items),
// rtc_send_all() again, [send_build_ids()], read_roms(): CMD_ROMLOADER 1, the ROM bursts, CMD_ROMLOADER 0;
// the keyboard cleared (CMD_USB_KBD 0..6 = 0); CMD_INIT_DONE. docs/protocol.md section 3 puts the switches
// and the RTC after the ROMs: the documentation and the code disagree; the TB follows the code.
// Not sent: the OSD font (the OSD stays closed) and the build ids (CMD_HW_SETUP 10h-1Fh: no target in
// mcu.vhd, which keeps only addresses 0 and 1).
task prologue;
	reg [8*8-1:0] s;
	begin
		repeat (1000) @(negedge refclk);          // the mcu has no reset (plan F18)
		mark_event("caps_query");
		link.caps_query(caps_ok, caps, caps_mhz);
		if (!caps_ok) begin
			$display("ERROR no CMD_CAPS answer");
			nerr = nerr + 1;
		end else if (caps[0] !== 1'b1 || caps_mhz !== BURST_MAX_MHZ) begin
			$display("ERROR CMD_CAPS answer caps %h max_mhz %h, expected bit 0 = 1 and max_mhz %h", caps, caps_mhz,
				BURST_MAX_MHZ);
			nerr = nerr + 1;
		end
		link_frame(8'hFD, 8'h00, 8'h00);           // CMD_INIT_START
		link_frame(8'hF9, 8'h00, HW_ID);           // CMD_HW_SETUP board
		link_frame(8'hF9, 8'h01, 8'h00);           // CMD_HW_SETUP dvi_only
		mark_event("read_core");
		rtc_all;                                   // rtc_send_all()
		switch(8'h04, 8'h00);                      // core_send_all(): Text color 0
		switch(8'h05, 8'h01);                      // Sound: on
		switch(8'h06, 8'h00);                      // ROM: 0 (BIOSSD)
		switch(8'h0A, 8'h00);                      // Autorun: off
		switch(8'h0C, 8'h00);                      // Reset trigger: 0
		rtc_all;                                   // rtc_send_all() again
		mark_event("romload");
		s = "";
		if ($value$plusargs("ROMLOAD=%s", s) && s == "preload")
			$display("ROMLOAD=preload: no ROM transfer (sram_model holds the ROMs)");
		else begin
			link_frame(8'h08, 8'h00, 8'h01);       // CMD_ROMLOADER on
			romload(0, 32'h00010000, 4096);        // roms/BIOSSD.BIN at 65536 (core.json)
			romload(1, 32'h00011000, 2048);        // roms/BIOS.BIN at 69632
		end
		// the checks after the ROM load are armed at the start of the CMD_ROMLOADER off frame: the loader
		// (and the CPU reset) drops during that frame, and its first read must be the reset vector
		rom_phase = 1'b1;
		xchk_en = 1'b1;
		sram.chk = 1'b1;
		if (!(s == "preload"))
			link_frame(8'h08, 8'h00, 8'h00);       // CMD_ROMLOADER off: the CPU leaves reset
		rom_done_cyc = cyc;
		mark_event("rom_loaded");
		rom_compare;
		kbd(8'h00, 8'h00);                         // keyboard cleared: modifiers + 6 key codes

		link_frame(8'hFE, 8'h00, 8'h00);           // CMD_INIT_DONE
		mark_event("init_done");
		// the main loop of the firmware from here on: NOP polling and the RTC time
		if ($value$plusargs("NOP_US=%d", nop_cyc)) nop_cyc = nop_cyc * 40;
		else nop_cyc = 100 * 40;
		rtc_last = cyc - 64'd10000000;           // the first time registers 250 ms after init_done
		poll_en = 1'b1;
	end
endtask

// the smoke criteria (the pins, the link, the SRAM, the ROM, the VGA raster); returns 1 if they hold
task smoke_checks(input [8*16-1:0] tag, output integer ok);
	begin
		ok = 1;
		if (nerr) begin ok = 0; $display("%0s FAIL: %0d errors (CAPS, ROM compare, chain)", tag, nerr); end
		if (trace.nxobs) begin ok = 0; $display("%0s FAIL: %0d samples with X on the observed pins", tag, trace.nxobs); end
		if (link.nrace) begin ok = 0; $display("%0s FAIL: %0d RACE", tag, link.nrace); end
		if (sram.nxwr_chk) begin ok = 0; $display("%0s FAIL: %0d SRAM writes with X after the ROM load", tag, sram.nxwr_chk); end
		if (sram.nhigh) begin ok = 0; $display("%0s FAIL: %0d SRAM accesses above 128K", tag, sram.nhigh); end
		if (!first_rd_seen || first_rd_a !== 21'h10800) begin
			ok = 0;
			$display("%0s FAIL: first SRAM read after the ROM load at %h (seen %0d), expected 10800", tag, first_rd_a,
				first_rd_seen);
		end
		if (nrom == 0) begin ok = 0; $display("%0s FAIL: no read in 10800..10FFF after the ROM load", tag); end
		if (frames.nlines == 0 || frames.nbad_h || frames.nbad_v) begin
			ok = 0;
			$display("%0s FAIL: VGA lines checked %0d, wrong lines %0d, wrong frames %0d", tag, frames.nlines,
				frames.nbad_h, frames.nbad_v);
		end
		$display("%0s caps {F7, %h, %h}; ROM loaded at cycle %0d; first read %h at cycle %0d; BIOS window read cycles %0d",
			tag, caps, caps_mhz, rom_done_cyc, first_rd_a, first_rd_cyc, nrom);
		$display("%0s SRAM writes %0d (changing %0d), X writes %0d (after the ROM load %0d); VGA lines %0d of %0d clocks; frames %0d",
			tag, sram.nwr, sram.nchg, sram.nxwr, sram.nxwr_chk, frames.nlines, H_TOTAL, frames.nframes);
		$display("%0s link frames %0d, bursts %0d, RACE %0d, NOP polls %0d, RTC time sends %0d, reply frames %0d; X samples on the pins %0d",
			tag, link.nframes, link.nbursts, link.nrace, nnop, nrtc_time, nreply, trace.nxobs);
	end
endtask

task chain_smoke;
	integer ms, nx, ok;
	begin
		ms = 5;
		if ($value$plusargs("SMOKE_MS=%d", ms)) ;
		repeat (ms * 40000) @(negedge refclk);
		mark_event("smoke_end");
		xcheck_regs("smoke_end", nx);
		smoke_checks("SMOKE", ok);
		$display("SMOKE registers X %0d (A5, informative)", nx);
		$display("RESULT smoke %0s", ok ? "PASS" : "FAIL");
	end
endtask

// ---- the works scenario (basic)
localparam [16:0] SB_LO = 17'h076D0;     // the screen buffer [76D0, 7FF4): 78 x 30 (BIOS: DMA 76D0, 2340 bytes)
localparam [16:0] SB_HI = 17'h07FF3;
localparam integer SB_W = 78;
localparam [8*10-1:0] BANNER = "radio-86rk";   // BIOS FF5A: 1F "radio-86rk", FF66: 0D 0A "-->"
localparam [11:0] BANNER_OFS = 12'hF5B;          // FF5B in the loaded ROM (BIOSSD.BIN, ROM switch 0)

reg cp1_armed = 1'b0, prompt_found = 1'b0;
reg [16:0] prompt_a = 17'd0;
reg [63:0] prompt_cyc = 64'd0;
integer nscr = 0;                         // changing writes into the screen buffer and the cursor (7600-7603)
reg echo_armed = 1'b0, echo_seen = 1'b0;
reg [16:0] echo_a = 17'd0;
reg [7:0] echo_d = 8'd0;

// the banner of the loaded ROM (the monitor prints these 10 bytes; a seeded ROM change shows up here)
function banner_above(input [16:0] a);   // a: the address of the first '-'
	integer i;
	reg ok;
	begin
		ok = (a >= SB_LO + SB_W);
		for (i = 0; i < 10; i = i + 1)
			if (sram.mem[a - SB_W + i] !== rom_biossd[BANNER_OFS + i]) ok = 1'b0;
		banner_above = ok;
	end
endfunction
// the loaded ROM must hold the stock banner (an error, the chain goes on)
task banner_check;
	integer i, nb;
	begin
		nb = 0;
		for (i = 0; i < 10; i = i + 1)
			if (rom_biossd[BANNER_OFS + i] !== BANNER[8*(9-i) +: 8]) nb = nb + 1;
		if (nb) begin
			$display("ERROR the banner of the loaded ROM at FF5B differs from \"radio-86rk\" in %0d bytes", nb);
			nerr = nerr + 1;
		end
	end
endtask

always @(sram.wr_ev) begin
	if (sram.wr_changed && ((sram.wr_a >= SB_LO && sram.wr_a <= SB_HI) ||
		(sram.wr_a >= 17'h07600 && sram.wr_a <= 17'h07603)))
		nscr = nscr + 1;
	// CP1: "-->" with "radio-86rk" in the row above, starting in the same column
	if (cp1_armed && !prompt_found && sram.wr_d == 8'h3E && sram.wr_a >= SB_LO + 2 && sram.wr_a <= SB_HI &&
		sram.mem[sram.wr_a - 1] === 8'h2D && sram.mem[sram.wr_a - 2] === 8'h2D && banner_above(sram.wr_a - 2)) begin
		prompt_found = 1'b1;
		prompt_a = sram.wr_a;
		prompt_cyc = cyc;
	end
	if (echo_armed && !echo_seen && sram.wr_a == echo_a) begin
		echo_seen = 1'b1;
		echo_d = sram.wr_d;
	end
end

// the RAM 0000-7FFF (one byte per line)
task dump_ram(input [8*40-1:0] fname);
	sram.dump(fname, 0, 32767);
endtask

// a picture: the screen settles (5 ms), snap, dump; nothing in the screen buffer or the cursor may change
task picture(input [8*32-1:0] ev, input [8*32-1:0] name, input [8*40-1:0] fname);
	integer n0;
	begin
		repeat (200000) @(negedge refclk);
		n0 = nscr;
		mark_event(ev);
		frames.snap(name);
		dump_ram(fname);
		if (nscr != n0) begin
			$display("ERROR picture %0s: %0d changing writes into the screen buffer or the cursor during the snap", name,
				nscr - n0);
			nerr = nerr + 1;
		end
	end
endtask

// a second picture of the same screen in the other cursor phase (bounded: 450 ms, more than 2 x 192 ms)
task resnap(input [8*32-1:0] ev, input [8*32-1:0] name, input [8*40-1:0] fname);
	integer n0, f0;
	reg [63:0] h0, t0;
	begin
		h0 = frames.snap_hash;
		t0 = cyc;
		n0 = nscr;
		f0 = frames.nframes;
		wait ((frames.nframes != f0 && frames.last_hash != h0) || cyc >= t0 + 64'd18000000);
		if (frames.last_hash == h0) begin
			$display("ERROR picture %0s: no frame with another hash within 450 ms after the snap", name);
			nerr = nerr + 1;
		end else begin
			$display("PICTURE %0s: frame %0d has another hash than the last snap, %0d cycles after it", name,
				frames.nframes - 1, cyc - t0);
			mark_event(ev);
			frames.snap_d(name, 64'd1);
			dump_ram(fname);
		end
		if (nscr != n0) begin
			$display("ERROR picture %0s: %0d changing writes into the screen buffer or the cursor before the snap", name,
				nscr - n0);
			nerr = nerr + 1;
		end
	end
endtask

// CP3: the field attributes (transparent mode of the BIOS setup, fillattr = 0): a code 80h-BFh takes a
// column and shows the byte after it (read into the CRT fifo); every row ends with the end-of-row code F1h
// at byte 77, so that each row still takes 78 bytes of the DMA count (2340 bytes, autoload) and the picture
// does not move (k580wg75.v:143-153, 162-168; k580wt57.v autoload); each field is reset (80h) before the
// row end, so no attribute carries into the next row. Rows 28 and 29 only, below the text area of the
// monitor (rows 3-27); 11 codes in the frame (the CRT fifo has 16 places). tools/screen.py holds the same
// bytes as its golden text.
// +CP3_EOR=0 (debugging): no end-of-row code (byte 77 is a space), so each code takes one more byte
reg cp3_eor = 1'b1;
initial begin : cp3_opt
	integer v;
	if ($value$plusargs("CP3_EOR=%d", v)) cp3_eor = (v != 0);
end
task poke_row(input integer row, input integer n, input [8*78-1:0] b);
	integer i;
	reg [16:0] a;
	begin
		// length guard: n must be the byte count of the concatenation (nothing above it, its first byte not 0)
		if ((b >> (8 * n)) !== 0 || b[8*(n-1) +: 8] === 8'h00) fatal("poke_row: n is not the length of the row bytes");
		a = SB_LO + row * SB_W;
		for (i = 0; i < 78; i = i + 1)
			sram.poke(a + i, (i < n) ? b[8*(n-1-i) +: 8] : ((i == 77 && cp3_eor) ? 8'hF1 : 8'h20));
	end
endtask
task cp3_poke;
	begin
		// row 28: normal text, inverse (90h), reset (80h), underline (A0h), reset, blink (82h), reset
		poke_row(28, 54, {"  NORMAL ", 8'h90, "INVERSE FIELD", 8'h80, " ", 8'hA0, "UNDERLINE", 8'h80, " ",
			8'h82, "BLINK FIELD", 8'h80, " END"});
		// row 29: the pseudographics 00h-1Fh, inverse pseudographics (90h), reset, inverse + underline (B0h),
		// underline + blink (A2h), reset
		poke_row(29, 69, {"  ", 64'h0001020304050607, 64'h08090A0B0C0D0E0F, 64'h1011121314151617,
			64'h18191A1B1C1D1E1F, " ", 8'h90, 64'h0102030405060708, 8'h80, " ", 8'hB0, "REV+UND", 8'hA2, "UND+BLINK",
			8'h80, " END"});
	end
endtask

// CP4: a key, its echo in the cell echo_a (the next cell after the prompt and the earlier echoes)
integer nkeys_bad = 0;
task type_key(input [7:0] mods, input [7:0] code, input [7:0] expect, input [8*32-1:0] name);
	reg [63:0] t0;
	begin
		echo_seen = 1'b0;
		echo_armed = 1'b1;
		t0 = cyc;
		mark_event(name);
		kbd(mods, code);
		wait (echo_seen || cyc >= t0 + 64'd12000000);    // 300 ms
		echo_armed = 1'b0;
		if (!echo_seen) begin
			$display("ERROR key %0s: no write to %h within 300 ms", name, echo_a);
			nkeys_bad = nkeys_bad + 1;
			nerr = nerr + 1;
		end else begin
			$display("KEY %0s: %h written to %h after %0d cycles (%0d us)", name, echo_d, echo_a, cyc - t0,
				(cyc - t0) / 40);
			$fwrite(fev, "%0d echo %h at %h after %0d cycles\n", cyc, echo_d, echo_a, cyc - t0);
			if (echo_d !== expect) begin
				$display("ERROR key %0s: echo %h, expected %h", name, echo_d, expect);
				nkeys_bad = nkeys_bad + 1;
				nerr = nerr + 1;
			end
		end
		kbd(8'h00, 8'h00);                                 // released
		repeat (400000) @(negedge refclk);                 // 10 ms
		echo_a = echo_a + 1;
	end
endtask

task chain_basic;
	integer nx, ok, i;
	reg [63:0] t0;
	begin
		banner_check;
		// CP1
		cp1_armed = 1'b1;
		t0 = cyc;
		wait (prompt_found || cyc >= t0 + 64'd16000000);   // 400 ms
		if (!prompt_found) begin
			$display("ERROR CP1: no prompt within 400 ms after init_done");
			nerr = nerr + 1;
			dump_ram("simout/ram_timeout.hex");
		end else begin
			mark_event("prompt");
			$display("CP1 prompt: 3E written to %h at cycle %0d (%0d ms after the start); row %0d column %0d", prompt_a,
				prompt_cyc, prompt_cyc / 40000, (prompt_a - 2 - SB_LO) / SB_W, (prompt_a - 2 - SB_LO) % SB_W);
			// CP2
			picture("snap_prompt", "prompt", "simout/ram_prompt.hex");
			// CP3
			cp3_poke;
			mark_event("attr_poked");
			picture("snap_attr", "attr", "simout/ram_attr.hex");
			// CP4
			echo_a = prompt_a + 1;
			type_key(8'h00, 8'h07, 8'h44, "key_D");
			type_key(8'h02, 8'h1E, 8'h21, "key_shift_1");
			picture("snap_keys", "keys", "simout/ram_keys.hex");
			// the cursor blinks with frame[3] of the CRT (8 CRT frames on, 8 off): snap "keys" may show it off.
			// Wait for the first frame whose hash differs from the snapped one (the cursor phase changed; the
			// blink fields change only together with it), then snap the next frame that starts after that:
			// one of "keys" / "keys2" shows the cursor on at its new position (tools/render.py checks it)
			resnap("snap_keys2", "keys2", "simout/ram_keys2.hex");
		end
		mark_event("basic_end");
		xcheck_regs("basic_end", nx);
		smoke_checks("BASIC", ok);
		if (!prompt_found) ok = 0;
		$display("BASIC prompt at cycle %0d; keys with a wrong or missing echo %0d; registers X %0d (A5, informative)",
			prompt_cyc, nkeys_bad, nx);
		$display("RESULT basic %0s", ok ? "PASS" : "FAIL");
	end
endtask

// time limit of the chain (+MAX_MS=<ms>; default: smoke SMOKE_MS + 20 ms, other chains 1000 ms)
initial begin : chain_limit
	integer ms_lim, sms;
	reg [8*16-1:0] c;
	c = "smoke";
	if ($value$plusargs("CHAIN=%s", c)) ;
	sms = 5;
	if ($value$plusargs("SMOKE_MS=%d", sms)) ;
	ms_lim = (c == "smoke") ? sms + 20 : 1000;
	if ($value$plusargs("MAX_MS=%d", ms_lim)) ;
	#(ms_lim * 1000000.0);
	fatal("chain time limit (+MAX_MS) reached");
end

// +STOP_AT=<cycle>: end the run at that cycle (detail runs of compare_runs.py with +TRACE_FROM / +TRACE_TO):
// the outputs are flushed and the RESULT line says STOPPED, so the run has no PASS verdict
initial begin : stop_at
	reg [63:0] sa;
	reg [8*16-1:0] c;
	if ($value$plusargs("STOP_AT=%d", sa)) begin
		c = "smoke";
		if ($value$plusargs("CHAIN=%s", c)) ;
		wait (cyc >= sa);
		trace.finish;
		frames.finish;
		sram.flush;
		$fflush(fev);
		$display("TB_CYCLES %0d", cyc);
		$display("RESULT %0s STOPPED at +STOP_AT=%0d", c, sa);
		$finish;
	end
end

initial begin : chain
	integer nx;
	fev = $fopen("simout/events.txt", "w");
	$readmemh("roms/BIOSSD.hex", rom_biossd);
	$readmemh("roms/BIOS.hex", rom_bios);
	chain_name = "smoke";
	if ($value$plusargs("CHAIN=%s", chain_name)) ;
	ev_dump = (chain_name == "basic");
	prologue;
	xcheck_regs("prologue_end", nx);
	if (chain_name == "smoke")
		chain_smoke;
	else if (chain_name == "basic")
		chain_basic;
	else begin
		$display("RESULT %0s FAIL: unknown chain", chain_name);
	end
	poll_en = 1'b0;
	trace.finish;
	frames.finish;
	sram.flush;
	$fflush(fev);
	$display("TB_CYCLES %0d", cyc);
	$finish;
end
