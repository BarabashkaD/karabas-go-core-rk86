// Self-checking testbench of the clock enable (ce) and the CPU memory ready (cpu_ready) of
// rk86_machine and rk86_video (docs/contract.md, sections rk86_machine and rk86_video), for
// iverilog; src/sim/machine/run_machine_sim.py builds and runs it and compares the traces.
// The machine runs the stock BIOS (BIOS.BIN) from power-up to its keyboard loop, with no key
// pressed. The testbench writes two traces:
//   bus.txt    one line per CPU bus transaction: ce cycle, status byte, address, data, R/W
//   video.txt  one line per video line: frame, line, ce cycle at its end, hashes of the
//              timebase, of the dots of rk86_video_stream and of the DMA schedule, lit dots,
//              DMA read cycles
// and checks on the fly: no state of the machine or of the video changes on a clk edge with
// ce = 0; the DMA, CRT and PPI take writes, cce comes and the CPU steps only on ce cycles;
// the CPU steps only with cpu_ready and never while vid_rd; every wait ends with a CPU step;
// without the stall generator no CPU step waits; with it there are realign steps after a wait
// (with STALL 2, a step 1 ce cycle after a waited step).
// With REF defined (+ the sources of rk86_machine_ref / rk86_video_ref) the same machine is
// compared every clk with the code before the clock enable.
// Parameters: CE_MODE 0 = ce always 1, 1 = 160 of 297 clk (e.g. 74.25 MHz x 160/297 = 40 MHz
// on average), 2 = pseudo-random, about 1 of 2;
// STALL 1 = random stalls of the CPU port of the memory, 2 = the same and a pending step held
// to the realign edge after hlda (directed: a step 1 ce cycle after a waited step); SYNC_MEM 1 = synchronous memory
// (read latency 1 clk, cpu_ready from an address tag), 0 = the Karabas memory (combinational,
// one port, the DMA before the CPU, cpu_ready = 1); FRAMES; SEED.
// Plusargs: +bios=<BIOS.BIN> +font=<FONT.BIN> +out=<directory for bus.txt / video.txt>.
`default_nettype none

module tb_rk86_mem(
	input  wire        clk,
	input  wire [15:0] cpu_a,
	input  wire  [7:0] cpu_do,
	input  wire        cpu_wr_n,
	input  wire        rom,
	input  wire [15:0] vid_a,
	input  wire        vid_rd,
	input  wire        slow,      // the stall generator: the CPU port has no data now
	input  wire  [7:0] junk,      // what the CPU port shows without data
	output wire  [7:0] mem_di,
	output wire        cpu_ready
);
parameter SYNC = 1;
reg [7:0] ram [0:32767];
reg [7:0] bios [0:2047];          // BIOS.BIN: E000-FFFF, and 0000-7FFF while startup (rom)
generate
	if (SYNC) begin : g_sync
		// one synchronous CPU read/write port and one synchronous DMA read port, read
		// latency 1 clk; cpu_ready when the CPU port holds the data of the current address
		reg [7:0] cpu_q, vid_q;
		reg [16:0] cpu_tag = 17'h1FFFF;
		always @(posedge clk) begin
			cpu_q <= rom ? bios[cpu_a[10:0]] : ram[cpu_a[14:0]];
			cpu_tag <= {rom, cpu_a};
			vid_q <= ram[vid_a[14:0]];
			if (!cpu_wr_n && !cpu_a[15])
				ram[cpu_a[14:0]] <= cpu_do;
		end
		wire cpu_ok = cpu_tag == {rom, cpu_a} && !slow;
		// one mem_di: the CRT takes it only while vid_rd, the CPU only with cpu_ready
		assign mem_di = vid_rd ? vid_q : cpu_ok ? cpu_q : junk;
		assign cpu_ready = cpu_ok && !vid_rd;
	end else begin : g_comb
		// the Karabas boards (src/radio86rk.v, MEM): one combinational port, the DMA first
		always @(posedge clk)
			if (!vid_rd && !cpu_wr_n && !cpu_a[15])
				ram[cpu_a[14:0]] <= cpu_do;
		assign mem_di = vid_rd ? ram[vid_a[14:0]] : rom ? bios[cpu_a[10:0]] : ram[cpu_a[14:0]];
		assign cpu_ready = 1'b1;
	end
endgenerate
endmodule

module tb_rk86_machine;

parameter CE_MODE = 0;
parameter STALL = 0;
parameter SYNC_MEM = 1;
parameter FRAMES = 12;
parameter SEED = 1;
parameter FREEZE_FRAMES = 3;        // first frames with the check that no state changes on a clk edge with ce = 0 (slow); the last frame too
localparam P = 32'h01000193;         // FNV prime: line hashes

reg clk = 1'b0;
always #1 clk = ~clk;

//--------- clock enable and stall generators --------------
reg [8:0] cadence = 9'd0;
wire [9:0] cadence_sum = {1'b0, cadence} + 10'd160;
reg [31:0] lfsr_ce = 32'h1234_5678 ^ SEED;
reg [31:0] lfsr_st = 32'h8765_4321 ^ SEED;
wire ce = CE_MODE == 0 ? 1'b1 : CE_MODE == 1 ? cadence_sum >= 10'd297 : lfsr_ce[0];
reg [5:0] stall_left = 6'd0;
always @(posedge clk) begin
	cadence <= cadence_sum >= 10'd297 ? cadence_sum - 10'd297 : cadence_sum[8:0];
	lfsr_ce <= {lfsr_ce[30:0], lfsr_ce[31] ^ lfsr_ce[21] ^ lfsr_ce[1] ^ lfsr_ce[0]};
	lfsr_st <= {lfsr_st[30:0], lfsr_st[31] ^ lfsr_st[21] ^ lfsr_st[1] ^ lfsr_st[0]};
	// a stall of 1..32 clk starts with probability 1/8 on a clk without a stall
	if (stall_left != 6'd0)
		stall_left <= stall_left - 6'd1;
	else if (STALL && lfsr_st[2:0] == 3'd0)
		stall_left <= {1'b0, lfsr_st[8:4]} + 6'd1;
end

//--------- reset: high for the first 32 ce cycles --------------
reg reset = 1'b1;
integer n_ce = 0;                    // ce cycles before this clk edge (counted in the checker below)
integer n_clk = 0;

//--------- under test --------------
wire [15:0] cpu_a, vid_a;
wire [7:0] cpu_do, mem_di, ppa_pa;
wire cpu_rd, cpu_wr_n, rom, startup, vid_rd, cpu_ready, pc0, inte, hil, irq, ext_we_n;
wire cce, hrtc, vrtc, lten, vsp, rvv;
wire [3:0] line;
wire [6:0] ochar;
wire [1:0] lattr, gattr;

rk86_machine dut(.clk(clk), .ce(ce), .reset(reset), .cpu_ready(cpu_ready),
	.cce(cce), .hrtc(hrtc), .vrtc(vrtc),
	.cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_rd(cpu_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup),
	.vid_a(vid_a), .vid_rd(vid_rd), .mem_di(mem_di),
	.ppa_pa(ppa_pa), .kbd_cols(8'hFF), .kbd_shift(3'b111), .tape_in(1'b0), .pc0(pc0), .inte(inte),
	.line(line), .ochar(ochar), .lten(lten), .vsp(vsp), .rvv(rvv), .hilight(hil),
	.lattr(lattr), .gattr(gattr), .irq(irq), .ext_we_n(ext_we_n), .ext_di(8'hFF));

// STALL 2 (directed): besides the random stalls, a pending step is held from the rise of hlda
// (in hldareg) to the realign edge and released exactly there, so the CPU takes the waited
// step on the realign edge and the realign step follows 1 ce cycle later
wire realign_edge = dut.hldareg[10:9] == 2'b01 && (cpu_rd || !cpu_wr_n);
wire realign_near = dut.hldareg[10:9] == 2'b00 && dut.hldareg[8:0] != 9'd0;
wire slow = STALL == 2 ? !realign_edge && (realign_near || stall_left != 6'd0) : stall_left != 6'd0;

tb_rk86_mem #(.SYNC(SYNC_MEM)) mem(.clk(clk), .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n),
	.rom(rom), .vid_a(vid_a), .vid_rd(vid_rd), .slow(slow), .junk(lfsr_st[15:8]),
	.mem_di(mem_di), .cpu_ready(cpu_ready));

reg [7:0] font [0:1023];
wire [9:0] font_addr;
reg [7:0] font_data;
always @(posedge clk) font_data <= font[font_addr];     // the font core: latency 1 clk

wire pix_ce, pix;
wire [10:0] h_cnt, v_cnt;
rk86_video vid(.clk(clk), .ce(ce), .line(line), .ichar(ochar), .vsp(vsp), .lten(lten), .rvv(rvv),
	.cce(cce), .hrtc(hrtc), .vrtc(vrtc), .font_addr(font_addr), .font_data(font_data),
	.pix_ce(pix_ce), .pix(pix), .h_cnt(h_cnt), .v_cnt(v_cnt));

wire s_ce, s_de, s_dot, s_hs, s_vs, s_ls, s_fs, s_le, s_fe;
rk86_video_stream st(.pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc), .h_cnt(h_cnt), .v_cnt(v_cnt),
	.ce(s_ce), .de(s_de), .dot(s_dot), .hs(s_hs), .vs(s_vs),
	.line_start(s_ls), .frame_start(s_fs), .line_end(s_le), .frame_end(s_fe));

`ifdef REF
//--------- the code before the clock enable, ce = 1, with its own Karabas memory --------------
wire [15:0] r_cpu_a, r_vid_a;
wire [7:0] r_cpu_do, r_mem_di, r_ppa_pa;
wire r_cpu_rd, r_cpu_wr_n, r_rom, r_startup, r_vid_rd, r_cpu_ready, r_pc0, r_inte, r_hil, r_irq, r_ext_we_n;
wire r_cce, r_hrtc, r_vrtc, r_lten, r_vsp, r_rvv;
wire [3:0] r_line;
wire [6:0] r_ochar;
wire [1:0] r_lattr, r_gattr;
rk86_machine_ref rdut(.clk(clk), .reset(reset), .cce(r_cce), .hrtc(r_hrtc), .vrtc(r_vrtc),
	.cpu_a(r_cpu_a), .cpu_do(r_cpu_do), .cpu_rd(r_cpu_rd), .cpu_wr_n(r_cpu_wr_n), .rom(r_rom), .startup(r_startup),
	.vid_a(r_vid_a), .vid_rd(r_vid_rd), .mem_di(r_mem_di),
	.ppa_pa(r_ppa_pa), .kbd_cols(8'hFF), .kbd_shift(3'b111), .tape_in(1'b0), .pc0(r_pc0), .inte(r_inte),
	.line(r_line), .ochar(r_ochar), .lten(r_lten), .vsp(r_vsp), .rvv(r_rvv), .hilight(r_hil),
	.lattr(r_lattr), .gattr(r_gattr), .irq(r_irq), .ext_we_n(r_ext_we_n), .ext_di(8'hFF));
tb_rk86_mem #(.SYNC(0)) rmem(.clk(clk), .cpu_a(r_cpu_a), .cpu_do(r_cpu_do), .cpu_wr_n(r_cpu_wr_n),
	.rom(r_rom), .vid_a(r_vid_a), .vid_rd(r_vid_rd), .slow(1'b0), .junk(8'h00),
	.mem_di(r_mem_di), .cpu_ready(r_cpu_ready));
reg [7:0] r_font_data;
wire [9:0] r_font_addr;
always @(posedge clk) r_font_data <= font[r_font_addr];
wire r_pix_ce, r_pix;
wire [10:0] r_h_cnt, r_v_cnt;
rk86_video_ref rvid(.clk(clk), .line(r_line), .ichar(r_ochar), .vsp(r_vsp), .lten(r_lten), .rvv(r_rvv),
	.cce(r_cce), .hrtc(r_hrtc), .vrtc(r_vrtc), .font_addr(r_font_addr), .font_data(r_font_data),
	.pix_ce(r_pix_ce), .pix(r_pix), .h_cnt(r_h_cnt), .v_cnt(r_v_cnt));
wire [255:0] o_new = {cpu_a, cpu_do, cpu_rd, cpu_wr_n, rom, startup, vid_a, vid_rd, ppa_pa, pc0, inte,
	line, ochar, lten, vsp, rvv, hil, lattr, gattr, irq, ext_we_n,
	cce, hrtc, vrtc, font_addr, pix_ce, pix, h_cnt, v_cnt};
wire [255:0] o_ref = {r_cpu_a, r_cpu_do, r_cpu_rd, r_cpu_wr_n, r_rom, r_startup, r_vid_a, r_vid_rd, r_ppa_pa, r_pc0, r_inte,
	r_line, r_ochar, r_lten, r_vsp, r_rvv, r_hil, r_lattr, r_gattr, r_irq, r_ext_we_n,
	r_cce, r_hrtc, r_vrtc, r_font_addr, r_pix_ce, r_pix, r_h_cnt, r_v_cnt};
`endif

//--------- power-up: the INIT values of the netlist (0; ipos 7F), as the video testbench ------
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

integer i, fd, b, fbus, fvid;
reg [8*512-1:0] bios_file, font_file, out_dir;

initial begin
	// the CPU interrupt input of rk86_machine has no driver; XST ties it to 0 (Xst:653)
	force dut.cpu_int = 1'b0;
`ifdef REF
	force rdut.cpu_int = 1'b0;
`endif
	`POWER_UP(dut, vid)
	dut.dma_we_q = 1'b0; dut.crt_we_q = 1'b0; dut.crt_rd_q = 1'b0;   // the hold registers (INIT 0)
`ifdef REF
	`POWER_UP(rdut, rvid)
`endif
	if (!$value$plusargs("bios=%s", bios_file)) bios_file = "src/roms/BIOS.BIN";
	if (!$value$plusargs("font=%s", font_file)) font_file = "src/roms/FONT.BIN";
	if (!$value$plusargs("out=%s", out_dir)) out_dir = ".";
	fd = $fopen(bios_file, "rb");
	if (fd == 0) begin $display("ERROR: cannot open the BIOS %0s", bios_file); $finish; end
	for (i = 0; i < 2048; i = i + 1) begin
		b = $fgetc(fd);
		if (b < 0) begin $display("ERROR: the BIOS is shorter than 2048 bytes"); $finish; end
		mem.bios[i] = b[7:0];
`ifdef REF
		rmem.bios[i] = b[7:0];
`endif
	end
	$fclose(fd);
	fd = $fopen(font_file, "rb");
	if (fd == 0) begin $display("ERROR: cannot open the font %0s", font_file); $finish; end
	for (i = 0; i < 1024; i = i + 1) begin
		b = $fgetc(fd);
		if (b < 0) begin $display("ERROR: the font is shorter than 1024 bytes"); $finish; end
		font[i] = b[7:0];
	end
	$fclose(fd);
	for (i = 0; i < 32768; i = i + 1) begin
		mem.ram[i] = 8'h00;
`ifdef REF
		rmem.ram[i] = 8'h00;
`endif
	end
	fbus = $fopen({out_dir, "/bus.txt"}, "w");
	fvid = $fopen({out_dir, "/video.txt"}, "w");
	if (fbus == 0 || fvid == 0) begin $display("ERROR: cannot write to %0s", out_dir); $finish; end
	$display("CE_MODE %0d STALL %0d SYNC_MEM %0d FRAMES %0d SEED %0d%0s", CE_MODE, STALL, SYNC_MEM, FRAMES, SEED,
`ifdef REF
		", reference compare"
`else
		""
`endif
	);
end

// the CRT row buffers and fifos as one vector (continuous assignments: no cost per edge)
wire [1503:0] crt_bufs;
genvar gk;
generate
	for (gk = 0; gk < 80; gk = gk + 1) begin : g_buf
		assign crt_bufs[gk * 16 +: 16] = {dut.crt.buf0[gk], dut.crt.buf1[gk]};
	end
	for (gk = 0; gk < 16; gk = gk + 1) begin : g_fifo
		assign crt_bufs[1280 + gk * 14 +: 14] = {dut.crt.fifo0[gk], dut.crt.fifo1[gk]};
	end
endgenerate

// the state of the machine and of the video: every register, the CRT row buffers included
`define STATE_VEC {crt_bufs, dut.cpu_cnt, dut.cpu_ce2, dut.hldareg, dut.startup, dut.dma_we_q, dut.crt_we_q, dut.crt_rd_q, \
		dut.CPU.M1, dut.CPU.M2, dut.CPU.M3, dut.CPU.M4, dut.CPU.M5, dut.CPU.M6, dut.CPU.M7, dut.CPU.M8, \
		dut.CPU.M9, dut.CPU.M10, dut.CPU.M11, dut.CPU.M12, dut.CPU.M13, dut.CPU.M14, dut.CPU.M15, \
		dut.CPU.M16, dut.CPU.M17, dut.CPU.T5, dut.CPU.state, dut.CPU.PC, dut.CPU.SP, \
		dut.CPU.B, dut.CPU.C, dut.CPU.D, dut.CPU.E, dut.CPU.H, dut.CPU.L, dut.CPU.A, \
		dut.CPU.W, dut.CPU.Z, dut.CPU.IR, dut.CPU.FS, dut.CPU.FZ, dut.CPU.FA, dut.CPU.FP, dut.CPU.FC, \
		dut.CPU.rd_, dut.CPU.intproc, dut.CPU.inte, dut.CPU.jmp, dut.CPU.call, dut.CPU.halt, \
		dut.CPU.save_alu, dut.CPU.save_a, dut.CPU.save_r, dut.CPU.save_rp, dut.CPU.read_r, dut.CPU.read_rp, \
		dut.CPU.incdec, dut.CPU.xthl, dut.CPU.xchg, dut.CPU.sphl, dut.CPU.daa, \
		dut.CPU.addr, dut.CPU.sync, dut.CPU.wr_n, dut.CPU.odata, \
		dut.dma.state, dut.dma.channel, dut.dma.mode, dut.dma.chstate, dut.dma.ff, dut.dma.exiwe_n, dut.dma.dack, \
		dut.dma.chaddr[0], dut.dma.chaddr[1], dut.dma.chaddr[2], dut.dma.chaddr[3], \
		dut.dma.chtcnt[0], dut.dma.chtcnt[1], dut.dma.chtcnt[2], dut.dma.chtcnt[3], \
		dut.crt.init0, dut.crt.init1, dut.crt.init2, dut.crt.init3, dut.crt.enable, dut.crt.inte, dut.crt.dmae, \
		dut.crt.dmadelay, dut.crt.dmalen, dut.crt.curx, dut.crt.cury, dut.crt.chline, dut.crt.attr, dut.crt.exattr, \
		dut.crt.iposf, dut.crt.oposf, dut.crt.ipos, dut.crt.opos, dut.crt.ypos, dut.crt.frame, dut.crt.lineff, \
		dut.crt.exwe_n, dut.crt.exrd_n, dut.crt.exvrtc, dut.crt.exhrtc, dut.crt.err, dut.crt.vspfe, \
		dut.crt.pstate, dut.crt.istate, dut.crt.drq, dut.crt.irq, dut.crt.ochar, \
		dut.ppa1.opa, dut.ppa1.opb, dut.ppa1.opc, \
		vid.state, vid.d_cnt, vid.data, vid.h_cnt, vid.v_cnt}

//--------- checks and traces --------------
integer errors = 0;
integer frame = -1, n_tr = 0, n_step = 0, n_frozen = 0, n_wait = 0, n_wait_vid = 0;
integer wait_run = 0, wait_max = 0, n_realign = 0, lit = 0, nrd = 0;
integer n_realign_wait = 0;          // realign steps after a step that waited
integer n_step1_wait = 0;            // CPU steps 1 ce cycle after a step that waited (that step was on a realign edge)
integer since_step = 0;              // ce cycles since the last CPU step
integer gap_min = -1, gap_min_wait = -1;   // fewest ce cycles between two CPU steps: after a step without / with a wait
reg done = 1'b0;
reg [7:0] status = 8'h00;
reg [31:0] h_tb = 32'd0, h_dot = 32'd0, h_dma = 32'd0;
reg sampled = 1'b0;           // s_prev holds the state before this edge, which had ce = 0
reg waiting = 1'b0;           // a pending CPU step met cpu_ready = 0 and has not been taken yet
reg step_waited = 1'b0;       // the CPU step on this edge waited before it
reg prev_waited = 1'b0;       // the last CPU step waited before it
reg from_realign = 1'b0;      // the pending CPU step comes from a realign
reg [4095:0] s_now, s_prev;

task finish_run;
begin
	if (!done) begin
		done = 1'b1;
		$fclose(fbus);
		$fclose(fvid);
		$display("frames %0d, ce cycles %0d, clk %0d, CPU steps %0d, transactions %0d", frame, n_ce, n_clk, n_step, n_tr);
		$display("edges with ce = 0 checked %0d; waits %0d clk (with vid_rd %0d, longest %0d); realigns %0d",
			n_frozen, n_wait, n_wait_vid, wait_max, n_realign);
		$display("realign steps after a wait %0d; steps 1 ce cycle after a wait %0d; fewest ce cycles between CPU steps %0d (after a step that did not wait), %0d (after a step that waited)",
			n_realign_wait, n_step1_wait, gap_min, gap_min_wait);
		if (CE_MODE != 0 && n_frozen == 0) begin errors = errors + 1; $display("ERROR: coverage: no edge with ce = 0"); end
		if (STALL && (n_wait == 0 || n_wait_vid == 0)) begin errors = errors + 1; $display("ERROR: coverage: no wait, or none with vid_rd"); end
		if (STALL && n_realign_wait == 0) begin errors = errors + 1; $display("ERROR: coverage: no realign step after a wait"); end
		if (STALL == 2 && n_step1_wait == 0) begin errors = errors + 1; $display("ERROR: coverage: no step 1 ce cycle after a wait"); end
		if (n_realign == 0) begin errors = errors + 1; $display("ERROR: coverage: no realign of the CPU after hlda"); end
		if (errors == 0)
			$display("RESULT: PASS");
		else
			$display("RESULT: FAIL (%0d errors)", errors);
		$finish;
	end
end
endtask

task fail;
	input [8*80-1:0] what;
begin
	errors = errors + 1;
	if (errors <= 20)
		$display("ERROR: %0s (ce cycle %0d, clk %0d, frame %0d, h %0d, v %0d)", what, n_ce, n_clk, frame, h_cnt, v_cnt);
	if (errors == 20) begin
		$display("stopping after 20 errors");
		finish_run;
	end
end
endtask

always @(posedge clk) if (!done) begin
	if (ce && n_ce == 31)
		reset <= 1'b0;                 // released on the edge of ce cycle 31
	// rules on every clk edge (values before the edge)
	if (!ce) begin
		if (dut.CPU.ce) fail("CPU step on a clk with ce = 0");
		if (dut.dma.ce || dut.crt.ce) fail("DMA or CRT enable on a clk with ce = 0");
		if (cce) fail("cce of rk86_video on a clk with ce = 0");
		if (!reset && dut.dma.iwe_n && !dut.dma.exiwe_n) fail("DMA write edge on a clk with ce = 0");
		if (!reset && dut.crt.iwe_n && !dut.crt.exwe_n) fail("CRT write edge on a clk with ce = 0");
		if (!reset && dut.crt.ird_n && !dut.crt.exrd_n) fail("CRT read edge on a clk with ce = 0");
		if (!dut.ppa1.we_n) fail("PPI write on a clk with ce = 0");
	end
	if (dut.CPU.ce && !cpu_ready) fail("CPU step without cpu_ready");
	if (dut.CPU.ce && vid_rd) fail("CPU step while vid_rd");
	// a pending step that waits keeps cpu_ce2 until the CPU takes it
	if (reset)
		waiting = 1'b0;
	else begin
		if (waiting && !dut.cpu_ce2) fail("a wait ended without a CPU step");
		if (ce) waiting = dut.cpu_ce2 && !cpu_ready;
	end
	// steps after a wait: a realign (hldareg[10:9] = 01 with a bus cycle) schedules a step on
	// the next ce cycle, so after a waited step the next one can come 1 ce cycle later (when the
	// waited step is on the realign edge); the gaps are printed for information
	step_waited = wait_run > 0;
	if (dut.CPU.ce) begin
		if (n_step > 0) begin
			if (prev_waited) begin
				if (gap_min_wait < 0 || since_step < gap_min_wait) gap_min_wait = since_step;
				if (since_step == 1) n_step1_wait = n_step1_wait + 1;
				if (from_realign) n_realign_wait = n_realign_wait + 1;
			end else begin
				if (gap_min < 0 || since_step < gap_min) gap_min = since_step;
			end
		end
		from_realign = 1'b0;
		prev_waited = step_waited;
		since_step = 0;
	end
	if (ce) since_step = since_step + 1;
	if (!reset && ce && dut.cpu_ce2 && !cpu_ready) begin
		n_wait = n_wait + 1;
		if (vid_rd) n_wait_vid = n_wait_vid + 1;
		wait_run = wait_run + 1;
		if (wait_run > wait_max) wait_max = wait_run;
		if (!STALL) fail("a CPU step waits without the stall generator");
	end else if (ce)
		wait_run = 0;
	if (!reset && ce && dut.hldareg[10:9] == 2'b01 && (cpu_rd || !cpu_wr_n) && !(dut.cpu_ce2 && !cpu_ready)) begin
		n_realign = n_realign + 1;
		from_realign = 1'b1;
	end
`ifdef REF
	if (o_new !== o_ref) fail("the machine with ce = 1 differs from the code before the clock enable");
`endif
	// the bus trace
	if (dut.CPU.ce) begin
		n_step = n_step + 1;
		if (dut.CPU.sync)
			status = cpu_do;
		if (cpu_rd || !cpu_wr_n) begin
			$fdisplay(fbus, "%0d %02x %04x %02x %s", n_ce, status, cpu_a, cpu_rd ? dut.cpu_i : cpu_do, cpu_rd ? "R" : "W");
			n_tr = n_tr + 1;
		end
	end
	// the video trace, in ce cycles
	if (ce) begin
		h_tb = h_tb * P ^ {28'd0, cce, hrtc, vrtc, pix_ce};
		h_dma = h_dma * P ^ {14'd0, dut.hlda, vid_rd, vid_rd ? vid_a : 16'h0000};
		if (vid_rd) nrd = nrd + 1;
		if (pix_ce) begin
			if (s_fs) begin
				frame = frame + 1;
				if (frame == FRAMES) finish_run;
			end
			if (!done) begin
				h_dot = h_dot * P ^ {2'b00, s_dot, s_de, s_hs, s_vs, s_ls, s_fs, s_le, s_fe, h_cnt, v_cnt};
				if (s_dot) lit = lit + 1;
				if (h_cnt == 11'd515) begin
					$fdisplay(fvid, "%0d %0d %0d %08x %08x %08x %0d %0d", frame, v_cnt, n_ce, h_tb, h_dot, h_dma, lit, nrd);
					h_tb = 32'd0; h_dot = 32'd0; h_dma = 32'd0; lit = 0; nrd = 0;
				end
			end
		end
		n_ce = n_ce + 1;
	end
	// the freeze check: in the first FREEZE_FRAMES frames and in the last one, from the end of reset
	if ((frame < FREEZE_FRAMES || frame == FRAMES - 1) && !ce && !reset) s_prev = `STATE_VEC;
	n_clk = n_clk + 1;
	sampled <= (frame < FREEZE_FRAMES || frame == FRAMES - 1) && !ce && !reset;
	if (!done && n_clk > 4 * (FRAMES + 1) * 959760) begin
		fail("timeout");
		finish_run;
	end
end

// no state of the machine or of the video changes on a clk edge with ce = 0: the state before
// such an edge (sampled at the edge) equals the state after it (at the next negedge)
always @(negedge clk) if (!done && sampled) begin
	n_frozen = n_frozen + 1;
	s_now = `STATE_VEC;
	if (s_now !== s_prev) fail("a state changed on a clk edge with ce = 0");
end
endmodule

`default_nettype wire
