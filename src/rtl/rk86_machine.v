// The Radio-86RK machine without board dependencies: its interface, as agreed in
// docs/contract.md. The body comes with the extraction of the machine from the board
// tops; until then the module is in no build.
`default_nettype none

module rk86_machine(
	input         clk,
	input         reset,     // composed by the board
	// timebase from the video (rk_video today): character clock enable, CRT sync inputs
	input         cce,
	input         hrtc,
	input         vrtc,
	// CPU side of the memory bus
	output [15:0] cpu_a,
	output  [7:0] cpu_do,
	output        cpu_rd,
	output        cpu_wr_n,
	output        rom,       // read from the ROM area: E000-FFFF, or 0000-7FFF while startup
	output        startup,
	// DMA side of the memory bus (video)
	output [15:0] vid_a,
	output        vid_rd,
	// read data of the memory, to the CPU and to the CRT
	input   [7:0] mem_di,
	// keyboard: rows (PPI port A), columns (port B), special keys (PC7..PC5), tape (PC4)
	output  [7:0] ppa_pa,
	input   [7:0] kbd_cols,
	input   [2:0] kbd_shift,
	input         tape_in,
	// sound and tape sources
	output        pc0,
	output        inte,
	// native video: the CRT outputs
	output  [3:0] line,
	output  [6:0] ochar,
	output        lten,
	output        vsp,
	output        rvv,
	output        hilight,
	output  [1:0] lattr,
	output  [1:0] gattr,
	output        irq,
	// window A000-BFFF for a board device (the SD card on the Karabas boards)
	output        ext_we_n,
	input   [7:0] ext_di
);

endmodule

`default_nettype wire
