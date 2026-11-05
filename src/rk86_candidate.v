// The build candidate of the board-neutral modules (docs/integration.md, The build candidate):
// rk86_machine, rk86_video and rk86_video_stream connected as another platform would connect
// them, with a fractional clock enable and a synchronous memory with a slow ROM that makes the
// CPU wait (cpu_ready). It is not a board design: the ISE synthesis and implementation on the
// XC6SLX25 (make -C src candidate) map the logic of ce and cpu_ready, with neither of them
// constant, under a PERIOD constraint on clk (the result: docs/verification.md); there is no
// bitstream, and only the clk pin is placed. src/sim/candidate runs it with the stock BIOS.
`default_nettype none

module rk86_candidate(
	// clk: T8, the oscillator pin of the boards (50 MHz there); the candidate constrains it at
	// 25 ns to model the 40 MHz machine clock (rk86_candidate.ucf)
	input  wire        clk,
	input  wire        reset_n,      // asynchronous to clk
	// the loader: loading may be asynchronous to clk, it is synchronized by two registers
	// (load_s). While load_s is high the machine is in reset and the memory takes load_we,
	// load_space, load_a and load_d, which are synchronous to clk: the loader writes from the
	// third clk edge after it raises loading. load_space 0 = RAM 0000-7FFF, 1 = ROM (2 KB),
	// 2 = font (1 KB)
	input  wire        loading,
	input  wire        load_we,
	input  wire  [1:0] load_space,
	input  wire [14:0] load_a,
	input  wire  [7:0] load_d,
	// keyboard, tape, window A000-BFFF
	output wire  [7:0] kbd_rows,
	input  wire  [7:0] kbd_cols,
	input  wire  [2:0] kbd_shift,
	input  wire        tape_in,
	output wire        ext_we_n,
	input  wire  [7:0] ext_di,
	// sound and tape sources
	output wire        pc0,
	output wire        inte,
	// the native dot stream, registered on its dot strobe
	output reg         de,
	output reg         dot,
	output reg         hs,
	output reg         vs,
	output reg         frame_start,
	output reg         frame_end
);

// the clock enable: CE_NUM of CE_DEN clk, spread evenly (e.g. 74.25 MHz x 160/297 = 40 MHz on
// average; here clk is 40 MHz, so the machine runs slower than native), from a register
parameter CE_NUM = 160;
parameter CE_DEN = 297;
reg [9:0] cadence = 10'd0;
wire [10:0] cadence_sum = {1'b0, cadence} + CE_NUM;
wire ce_next = cadence_sum >= CE_DEN;
reg ce = 1'b0;
always @(posedge clk) begin
	cadence <= ce_next ? cadence_sum - CE_DEN : cadence_sum[9:0];
	ce <= ce_next;
end

// the reset: the pin or the loader (both synchronized by two registers), then held for 15 more
// ce cycles (docs/integration.md: at least one ce cycle). The synchronizers are marked for the
// tools: asynchronous inputs (ASYNC_REG) and kept as flip-flops, not packed into a shift
// register LUT (SHREG_EXTRACT).
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
reg [1:0] rst_sync = 2'b00;
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
reg [1:0] load_sync = 2'b00;
reg [3:0] rst_cnt = 4'd0;
wire load_s = load_sync[1];
always @(posedge clk) begin
	rst_sync <= {rst_sync[0], reset_n};
	load_sync <= {load_sync[0], loading};
	if (!rst_sync[1] || load_s)
		rst_cnt <= 4'd0;
	else if (ce && rst_cnt != 4'hF)
		rst_cnt <= rst_cnt + 4'd1;
end
wire reset = rst_cnt != 4'hF;

//--------- the machine --------------
wire [15:0] cpu_a, vid_a;
wire [7:0] cpu_do, mem_di;
wire cpu_rd, cpu_wr_n, rom, startup, vid_rd, cpu_ready;
wire cce, hrtc, vrtc, lten, vsp, rvv, hilight, irq;
wire [3:0] line;
wire [6:0] ochar;
wire [1:0] lattr, gattr;

rk86_machine machine(.clk(clk), .ce(ce), .reset(reset), .cpu_ready(cpu_ready),
	.cce(cce), .hrtc(hrtc), .vrtc(vrtc),
	.cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_rd(cpu_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup),
	.vid_a(vid_a), .vid_rd(vid_rd), .mem_di(mem_di),
	.ppa_pa(kbd_rows), .kbd_cols(kbd_cols), .kbd_shift(kbd_shift), .tape_in(tape_in),
	.pc0(pc0), .inte(inte),
	.line(line), .ochar(ochar), .lten(lten), .vsp(vsp), .rvv(rvv), .hilight(hilight),
	.lattr(lattr), .gattr(gattr), .irq(irq), .ext_we_n(ext_we_n), .ext_di(ext_di));

//--------- the memory: block RAM, read latency 1 clk --------------
// RAM: a CPU read/write port (or the loader) and a DMA read port; ROM and font: one port
// each, written by the loader. cpu_ready: the CPU port holds the data of the current address
// ({rom, cpu_a} as the tag) and the DMA does not read (docs/contract.md, cpu_ready).
reg [7:0] ram [0:32767];
reg [7:0] rom_mem [0:2047];
reg [7:0] font_mem [0:1023];
reg [7:0] ram_q, vid_q, rom_q, font_q;
reg [16:0] cpu_tag = 17'h1FFFF;
// the ROM is a slow source (as a ROM behind an arbiter or loaded from elsewhere): its data is
// there ROM_WAIT clk after the address changes, 8'hFF before; the CPU waits for it
parameter ROM_WAIT = 127;
reg [6:0] rom_busy = 7'd0;

wire [14:0] ram_a = load_s ? load_a : cpu_a[14:0];
wire ram_we = load_s ? load_we && load_space == 2'd0 : !cpu_wr_n && !cpu_a[15];
wire [7:0] ram_d = load_s ? load_d : cpu_do;
wire [10:0] rom_a = load_s ? load_a[10:0] : cpu_a[10:0];
wire rom_we = load_s && load_we && load_space == 2'd1;
wire [9:0] font_addr;
wire [9:0] font_a = load_s ? load_a[9:0] : font_addr;
wire font_we = load_s && load_we && load_space == 2'd2;

always @(posedge clk) begin
	ram_q <= ram[ram_a];
	if (ram_we) ram[ram_a] <= ram_d;
end
always @(posedge clk)
	vid_q <= ram[vid_a[14:0]];
always @(posedge clk) begin
	rom_q <= rom_mem[rom_a];
	if (rom_we) rom_mem[rom_a] <= load_d;
end
always @(posedge clk) begin
	font_q <= font_mem[font_a];
	if (font_we) font_mem[font_a] <= load_d;
end
always @(posedge clk) begin
	cpu_tag <= {rom, cpu_a};
	if (cpu_tag != {rom, cpu_a})
		rom_busy <= ROM_WAIT;
	else if (rom_busy != 7'd0)
		rom_busy <= rom_busy - 7'd1;
end

wire cpu_hit = cpu_tag == {rom, cpu_a} && (!cpu_tag[16] || rom_busy == 7'd0);
assign mem_di = vid_rd ? vid_q : !cpu_tag[16] ? ram_q : rom_busy == 7'd0 ? rom_q : 8'hFF;
assign cpu_ready = cpu_hit && !vid_rd;

//--------- the native video and its stream --------------
wire pix_ce, pix;
wire [10:0] h_cnt, v_cnt;
rk86_video video(.clk(clk), .ce(ce), .line(line), .ichar(ochar), .vsp(vsp), .lten(lten), .rvv(rvv),
	.cce(cce), .hrtc(hrtc), .vrtc(vrtc), .font_addr(font_addr), .font_data(font_q),
	.pix_ce(pix_ce), .pix(pix), .h_cnt(h_cnt), .v_cnt(v_cnt));

wire s_ce, s_de, s_dot, s_hs, s_vs, s_ls, s_fs, s_le, s_fe;
rk86_video_stream stream(.pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc), .h_cnt(h_cnt), .v_cnt(v_cnt),
	.ce(s_ce), .de(s_de), .dot(s_dot), .hs(s_hs), .vs(s_vs),
	.line_start(s_ls), .frame_start(s_fs), .line_end(s_le), .frame_end(s_fe));

always @(posedge clk)
	if (s_ce) begin
		de <= s_de; dot <= s_dot; hs <= s_hs; vs <= s_vs;
		frame_start <= s_fs; frame_end <= s_fe;
	end

endmodule

`default_nettype wire
