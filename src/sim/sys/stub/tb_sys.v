`timescale 1ns / 1ps
// Stub TB for the Task 1 deliverable (elaboration + a 2 ms run): the 50 MHz board clock, the MCU
// link idle, an SRAM model preloaded with BIOSSD at 0x10000 (roms/BIOSSD.hex from gen_sim.py).
// Only top-level pins are observed (no hierarchical DUT paths). At RUN_NS it raises
// sim_ctl.xcheck (the module-local X-checkers report registers still X), prints the counts
// and finishes. fuse -d BOARD_GO | BOARD_MINIG.
module tb_sys;
parameter RUN_NS = 2000000;
reg clk = 1'b0;
always #10 clk = ~clk;
wire [20:0] ma;
wire [15:0] md;
wire [1:0] mwr_n, mrd_n;
integer nhs = 0, nvs = 0, nlit = 0, nwr = 0;
`ifdef BOARD_GO
wire [3:0] mcu_io;
pullup (mcu_io[1]);   // burst cs_n
wire [7:0] r, g, b;
wire hs, vs;
radio86rk dut(
	.CLK_50MHZ(clk),
	.MCU_CS_N(1'b1), .MCU_SCK(1'b0), .MCU_IO(mcu_io),
	.SD_DO(1'b1), .SD_DET_N(1'b1), .TAPE_IN(1'b0),
	.VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hs), .VGA_VS(vs),
	.MA(ma), .MD(md), .MWR_N(mwr_n), .MRD_N(mrd_n)
);
always @(posedge hs) nhs = nhs + 1;
always @(posedge vs) nvs = nvs + 1;
always @(posedge clk) if (r !== 8'h00 || g !== 8'h00 || b !== 8'h00) nlit = nlit + 1;
`elsif BOARD_MINIG
wire [5:0] mcu_io;
pullup (mcu_io[0]);   // burst cs_n
wire [3:0] tmds_p, tmds_n;
radio86rk_minig dut(
	.CLK_50MHZ(clk),
	.MCU_CS_N(1'b1), .MCU_SCK(1'b0), .MCU_IO(mcu_io),
	.SD_DO(1'b1), .SD_DET_N(1'b1), .TAPE_IN(1'b0), .ADC_DOUT(1'b0),
	.TMDS_P(tmds_p), .TMDS_N(tmds_n),
	.MA(ma), .MD(md), .MWR_N(mwr_n), .MRD_N(mrd_n)
);
always @(posedge tmds_p[3]) nhs = nhs + 1;    // TMDS clock lane edges
always @(posedge tmds_p[0]) nvs = nvs + 1;    // blue lane edges
`else
initial begin $display("tb_sys: define BOARD_GO or BOARD_MINIG"); $finish; end
`endif

reg [7:0] sram [0:131071];
integer i;
initial begin
	for (i = 0; i < 131072; i = i + 1) sram[i] = 8'h00;
	$readmemh("roms/BIOSSD.hex", sram, 17'h10000);
end
assign md[7:0] = (mwr_n[0] && !mrd_n[0]) ? sram[ma[16:0]] : 8'hzz;
always @(*) if (!mwr_n[0]) sram[ma[16:0]] = md[7:0];
always @(negedge mwr_n[0]) nwr = nwr + 1;

initial begin
	#(RUN_NS);
	sim_ctl.xcheck = 1'b1;
	#1;
	$display("TB_SYS t=%0t edges_a=%0d edges_b=%0d lit=%0d sram_wr=%0d ma=%h mwr=%b mrd=%b xtotal=%0d (verilog %0d, vhdl %0d)",
		$time, nhs, nvs, nlit, nwr, ma, mwr_n, mrd_n, sim_ctl.xtotal, sim_ctl.xcount, sim_ctl.vxcount);
	$finish;
end
endmodule
