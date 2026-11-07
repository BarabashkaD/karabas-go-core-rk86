// The memory of the machine testbench (src/sim/machine/tb_rk86_machine.v). A platform checks
// its own memory by giving run_machine_sim.py --mem <file> with a module tb_rk86_mem of the
// same ports, parameter SYNC (1: the memory under test, 0: the Karabas model of the REF
// build) and an array bios [0:2047] written by the testbench (docs/integration.md section 12).
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
