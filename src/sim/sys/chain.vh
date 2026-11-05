// The chained scenario of tb_sys (included in the module): the prologue (the core start sequence of
// the firmware) and the chains selected by +CHAIN=<name>:
//   smoke   prologue + SMOKE_MS (+SMOKE_MS=<ms>, default 5) ms: no X on the observed pins after the
//           ROM load, no RACE, the CPU reads the ROM (0x10800..0x10FFF) after the loader drops, the VGA
//           line period, no SRAM write with X after the ROM load, no access above 128K.

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

task link_frame(input [7:0] c, input [7:0] a, input [7:0] d);
	link.frame(c, a, d, rc, ra, rd);
endtask

// ROM data through bursts of up to 512 bytes (CMD_ROMDATA, burst type 07)
task romload(input integer which, input [31:0] addr, input integer len);
	integer off, n, i;
	begin
		for (off = 0; off < len; off = off + 512) begin
			n = (len - off > 512) ? 512 : len - off;
			for (i = 0; i < n; i = i + 1)
				link.bbuf[i] = which ? rom_bios[off + i] : rom_biossd[off + i];
			link.burst(8'h07, addr + off, n);
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

// the core start sequence of the firmware (karabas-go-firmware docs/protocol.md, section 3: do_configure)
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
		// (OSD font and build ids: not sent; the OSD stays closed, the build ids have no target in mcu.vhd)
		mark_event("romload");
		s = "";
		if ($value$plusargs("ROMLOAD=%s", s) && s == "preload")
			$display("ROMLOAD=preload: no ROM transfer (sram_model holds the ROMs)");
		else begin
			link_frame(8'h08, 8'h00, 8'h01);       // CMD_ROMLOADER on
			romload(0, 32'h00010000, 4096);        // roms/BIOSSD.BIN at 65536 (core.json)
			romload(1, 32'h00011000, 2048);        // roms/BIOS.BIN at 69632
			link_frame(8'h08, 8'h00, 8'h00);       // CMD_ROMLOADER off: the CPU leaves reset
		end
		rom_done_cyc = cyc;
		rom_phase = 1'b1;
		xchk_en = 1'b1;
		sram.chk = 1'b1;
		mark_event("rom_loaded");
		switch(8'h04, 8'h00);                      // Text color: 0
		switch(8'h05, 8'h01);                      // Sound: on
		switch(8'h06, 8'h00);                      // ROM: 0 (BIOSSD)
		switch(8'h0A, 8'h00);                      // Autorun: off
		switch(8'h0C, 8'h00);                      // Reset trigger: 0
		kbd(8'h00, 8'h00);                         // keyboard cleared

		link_frame(8'hFE, 8'h00, 8'h00);           // CMD_INIT_DONE
		mark_event("init_done");
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
		ok = 1;
		if (nerr) ok = 0;
		if (trace.nxobs) begin ok = 0; $display("SMOKE FAIL: %0d samples with X on the observed pins", trace.nxobs); end
		if (link.nrace) begin ok = 0; $display("SMOKE FAIL: %0d RACE", link.nrace); end
		if (sram.nxwr_chk) begin ok = 0; $display("SMOKE FAIL: %0d SRAM writes with X after the ROM load", sram.nxwr_chk); end
		if (sram.nhigh) begin ok = 0; $display("SMOKE FAIL: %0d SRAM accesses above 128K", sram.nhigh); end
		if (!first_rd_seen || first_rd_a !== 21'h10800) begin
			ok = 0;
			$display("SMOKE FAIL: first SRAM read after the ROM load at %h (seen %0d), expected 10800", first_rd_a,
				first_rd_seen);
		end
		if (nrom == 0) begin ok = 0; $display("SMOKE FAIL: no read in 10800..10FFF after the ROM load"); end
		if (frames.nlines == 0 || frames.nbad_h || frames.nbad_v) begin
			ok = 0;
			$display("SMOKE FAIL: VGA lines checked %0d, wrong lines %0d, wrong frames %0d", frames.nlines,
				frames.nbad_h, frames.nbad_v);
		end
		$display("SMOKE caps {F7, %h, %h}; ROM loaded at cycle %0d; first read %h at cycle %0d; BIOS window read cycles %0d",
			caps, caps_mhz, rom_done_cyc, first_rd_a, first_rd_cyc, nrom);
		$display("SMOKE SRAM writes %0d (changing %0d), X writes %0d (after the ROM load %0d); VGA lines %0d of %0d clocks; frames %0d",
			sram.nwr, sram.nchg, sram.nxwr, sram.nxwr_chk, frames.nlines, H_TOTAL, frames.nframes);
		$display("SMOKE link frames %0d, bursts %0d, RACE %0d; X samples on the pins %0d; registers X %0d (A5, informative)",
			link.nframes, link.nbursts, link.nrace, trace.nxobs, nx);
		$display("RESULT smoke %0s", ok ? "PASS" : "FAIL");
	end
endtask

initial begin : chain
	integer nx;
	fev = $fopen("simout/events.txt", "w");
	$readmemh("roms/BIOSSD.hex", rom_biossd);
	$readmemh("roms/BIOS.hex", rom_bios);
	chain_name = "smoke";
	if ($value$plusargs("CHAIN=%s", chain_name)) ;
	prologue;
	xcheck_regs("prologue_end", nx);
	if (chain_name == "smoke")
		chain_smoke;
	else begin
		$display("RESULT %0s FAIL: unknown chain", chain_name);
	end
	trace.finish;
	frames.finish;
	sram.flush;
	$fflush(fev);
	$display("TB_CYCLES %0d", cyc);
	$finish;
end
