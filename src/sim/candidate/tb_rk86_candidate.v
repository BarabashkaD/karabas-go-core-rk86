// Smoke testbench of the build candidate src/rk86_candidate.v (docs/integration.md, The build
// candidate), for iverilog; src/sim/candidate/run_candidate_sim.py builds and runs it. It loads
// the stock BIOS and the font through the loader port of the candidate, releases the reset and
// runs FRAMES native frames with the clock enable of the candidate (160 of 297 clk). It passes
// when every CPU step that reads the RAM or the ROM gets on mem_di the byte that the memory
// of the candidate (ram, rom_mem) holds at that address (the promise of cpu_ready), the CPU
// reaches the keyboard loop of the BIOS (a read of FE63), CPU steps waited for the slow ROM
// (coverage), and the last frame of the dot stream has lit dots. Two more checks (no CPU step
// without cpu_ready, none while vid_rd) are sanity checks: they hold by construction of
// cpu_ready and of the CPU clock enable of rk86_machine.
// Plusargs: +bios=<BIOS.BIN> +font=<FONT.BIN>.
`default_nettype none

module tb_rk86_candidate;

parameter FRAMES = 8;
parameter SHOW = 10;                  // data errors printed in full

reg clk = 1'b0;
always #1 clk = ~clk;

reg reset_n = 1'b0;
reg loading = 1'b1;
reg load_we = 1'b0;
reg [1:0] load_space = 2'd0;
reg [14:0] load_a = 15'd0;
reg [7:0] load_d = 8'd0;
wire [7:0] kbd_rows;
wire ext_we_n, pc0, inte, de, dot, hs, vs, frame_start, frame_end;

rk86_candidate dut(.clk(clk), .reset_n(reset_n), .loading(loading), .load_we(load_we),
	.load_space(load_space), .load_a(load_a), .load_d(load_d),
	.kbd_rows(kbd_rows), .kbd_cols(8'hFF), .kbd_shift(3'b111), .tape_in(1'b0),
	.ext_we_n(ext_we_n), .ext_di(8'hFF), .pc0(pc0), .inte(inte),
	.de(de), .dot(dot), .hs(hs), .vs(vs), .frame_start(frame_start), .frame_end(frame_end));

//--------- power-up: the INIT values of the netlist (0; ipos 7F), as tb_rk86_machine.v ------
`define POWER_UP(M, V) \
	V.state = 2'd0; V.d_cnt = 3'd0; V.data = 6'd0; V.h_cnt = 11'd0; V.v_cnt = 11'd0; \
	M.CPU.B = 8'h00; M.CPU.C = 8'h00; M.CPU.D = 8'h00; M.CPU.E = 8'h00; M.CPU.H = 8'h00; \
	M.CPU.L = 8'h00; M.CPU.A = 8'h00; M.CPU.SP = 16'h0000; M.CPU.W = 8'h00; M.CPU.Z = 8'h00; \
	M.CPU.IR = 8'h00; M.CPU.call = 1'b0; M.CPU.read_r = 1'b0; M.CPU.read_rp = 1'b0; \
	M.CPU.xthl = 1'b0; M.CPU.xchg = 1'b0; M.CPU.sphl = 1'b0; M.CPU.daa = 1'b0; M.CPU.T5 = 1'b0; \
	for (i = 0; i < 4; i = i + 1) begin M.dma.chaddr[i] = 16'h0000; M.dma.chtcnt[i] = 16'h0000; end \
	M.dma.channel = 2'd0; \
	M.crt.init0 = 8'h00; M.crt.init1 = 8'h00; M.crt.init2 = 8'h00; M.crt.init3 = 8'h00; \
	M.crt.enable = 1'b0; M.crt.inte = 1'b0; M.crt.dmae = 1'b0; M.crt.dmadelay = 3'd0; M.crt.dmalen = 2'd0; \
	M.crt.curx = 7'd0; M.crt.cury = 6'd0; M.crt.chline = 5'd0; M.crt.attr = 6'd0; M.crt.exattr = 6'd0; \
	M.crt.iposf = 4'd0; M.crt.oposf = 4'd0; M.crt.ipos = 7'h7F; M.crt.opos = 8'd0; M.crt.ypos = 6'd0; \
	M.crt.frame = 5'd0; M.crt.lineff = 1'b0; M.crt.exwe_n = 1'b0; M.crt.exrd_n = 1'b0; \
	M.crt.exvrtc = 1'b0; M.crt.exhrtc = 1'b0; M.crt.err = 1'b0; M.crt.vspfe = 1'b0; \
	M.crt.pstate = 3'd0; M.crt.istate = 1'b0; M.crt.drq = 1'b0; M.crt.irq = 1'b0; M.crt.ochar = 7'd0; \
	for (i = 0; i < 80; i = i + 1) begin M.crt.buf0[i] = 8'h00; M.crt.buf1[i] = 8'h00; end \
	for (i = 0; i < 16; i = i + 1) begin M.crt.fifo0[i] = 7'h00; M.crt.fifo1[i] = 7'h00; end

integer i, fd, b, errors = 0;
integer frame = -1, lit = 0, kbd_reads = 0, kbd_frame = -1, waits = 0, steps = 0;
integer reads = 0, bad_reads = 0, bad_steps = 0;
reg [7:0] expect_d;
reg [8*512-1:0] bios_file, font_file;
reg [7:0] image [0:3071];             // BIOS.BIN (2048 bytes), then FONT.BIN (1024 bytes)

task load_file;
	input [8*512-1:0] name;
	input integer base, count;
begin
	fd = $fopen(name, "rb");
	if (fd == 0) begin $display("ERROR: cannot open %0s", name); $finish; end
	for (i = 0; i < count; i = i + 1) begin
		b = $fgetc(fd);
		if (b < 0) begin $display("ERROR: %0s is shorter than %0d bytes", name, count); $finish; end
		image[base + i] = b[7:0];
	end
	$fclose(fd);
end
endtask

initial begin
	// the CPU interrupt input of rk86_machine has no driver; XST ties it to 0 (Xst:653)
	force dut.machine.cpu_int = 1'b0;
	`POWER_UP(dut.machine, dut.video)
	dut.machine.dma_we_q = 1'b0; dut.machine.crt_we_q = 1'b0; dut.machine.crt_rd_q = 1'b0;
	for (i = 0; i < 32768; i = i + 1) dut.ram[i] = 8'h00;     // block RAM INIT 0
	if (!$value$plusargs("bios=%s", bios_file)) bios_file = "src/roms/BIOS.BIN";
	if (!$value$plusargs("font=%s", font_file)) font_file = "src/roms/FONT.BIN";
	load_file(bios_file, 0, 2048);
	load_file(font_file, 2048, 1024);
	// the loader port: loading is high from the start; the writes begin when the candidate has
	// synchronized it (load_s), one byte per clk, the machine in reset
	wait (dut.load_s === 1'b1);
	for (i = 0; i < 3072; i = i + 1) begin
		@(negedge clk);
		load_we = 1'b1;
		load_space = i < 2048 ? 2'd1 : 2'd2;
		load_a = i < 2048 ? i : i - 2048;
		load_d = image[i];
	end
	@(negedge clk);
	load_we = 1'b0;
	loading = 1'b0;
	reset_n = 1'b1;
	$display("FRAMES %0d, ce %0d of %0d clk", FRAMES, dut.CE_NUM, dut.CE_DEN);
end

// rules and counts on every clk edge (values before the edge)
always @(posedge clk) if (!loading) begin
	if (dut.machine.CPU.ce) begin
		steps = steps + 1;
		// the data check: a CPU step that reads the RAM (0000-7FFF, not in the ROM) or the ROM
		// (rom: E000-FFFF, 0000-7FFF while startup) gets the byte of the memory at cpu_a
		if (dut.cpu_rd && (!dut.cpu_a[15] || dut.cpu_a[15:13] == 3'b111)) begin
			expect_d = dut.rom ? dut.rom_mem[dut.cpu_a[10:0]] : dut.ram[dut.cpu_a[14:0]];
			reads = reads + 1;
			if (dut.mem_di !== expect_d) begin
				errors = errors + 1;
				bad_reads = bad_reads + 1;
				if (bad_reads <= SHOW)
					$display("ERROR: CPU read data differs from the memory: %h at %h, the memory holds %h (frame %0d)",
						dut.mem_di, dut.cpu_a, expect_d, frame);
			end
		end
		// sanity checks, true by construction (cpu_ready includes !vid_rd; the CPU clock
		// enable of rk86_machine includes cpu_ready): not evidence on their own
		if (!dut.cpu_ready || dut.vid_rd) begin
			errors = errors + 1;
			bad_steps = bad_steps + 1;
			if (bad_steps <= SHOW)
				$display("ERROR: sanity: CPU step with cpu_ready %b, vid_rd %b at %h (frame %0d)",
					dut.cpu_ready, dut.vid_rd, dut.cpu_a, frame);
		end
		if (dut.cpu_a == 16'hFE63 && dut.cpu_rd) begin
			if (kbd_reads == 0) kbd_frame = frame;
			kbd_reads = kbd_reads + 1;
		end
	end
	if (dut.ce && dut.machine.cpu_ce2 && !dut.cpu_ready) waits = waits + 1;
	if (dut.s_ce) begin
		if (dut.s_fs) begin
			if (frame >= 0) $display("frame %0d: lit dots %0d", frame, lit);
			frame = frame + 1;
			if (frame == FRAMES) begin
				$display("CPU steps %0d, ce cycles with a waiting CPU step %0d, reads of FE63 %0d (the first in frame %0d)", steps, waits, kbd_reads, kbd_frame);
				$display("CPU reads of the RAM and the ROM checked %0d, with wrong data %0d", reads, bad_reads);
				if (bad_reads > SHOW) $display("ERROR: CPU read data differs from the memory: %0d more reads", bad_reads - SHOW);
				if (bad_steps > SHOW) $display("ERROR: sanity: %0d more CPU steps without cpu_ready or while vid_rd", bad_steps - SHOW);
				if (reads == 0) begin errors = errors + 1; $display("ERROR: coverage: no CPU read of the RAM or the ROM"); end
				if (kbd_reads == 0) begin errors = errors + 1; $display("ERROR: the CPU did not reach the keyboard loop (FE63)"); end
				if (waits == 0) begin errors = errors + 1; $display("ERROR: coverage: no CPU step waited for cpu_ready"); end
				if (lit == 0) begin errors = errors + 1; $display("ERROR: no lit dot in the last frame"); end
				if (errors == 0) $display("RESULT: PASS");
				else $display("RESULT: FAIL (%0d errors)", errors);
				$finish;
			end
			lit = 0;
		end
		if (dut.s_dot) lit = lit + 1;
	end
end

endmodule

`default_nettype wire
