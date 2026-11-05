// The Radio-86RK machine without board dependencies: CPU, DMA, CRT, PPI, the address
// decoding and the CPU clock enable (docs/contract.md). The code is the one of the board
// tops, moved without changes; the board top composes the reset and owns the memory, the
// video output and the device of the window A000-BFFF.
`default_nettype none

module rk86_machine(
	input  wire        clk,
	input  wire        reset,     // composed by the board
	// timebase from the video (rk_video today): character clock enable, CRT sync inputs
	input  wire        cce,
	input  wire        hrtc,
	input  wire        vrtc,
	// CPU side of the memory bus
	output wire [15:0] cpu_a,
	output wire  [7:0] cpu_do,
	output wire        cpu_rd,
	output wire        cpu_wr_n,
	output reg         rom,       // read from the ROM area: E000-FFFF, or 0000-7FFF while startup
	output reg         startup,
	// DMA side of the memory bus (video)
	output wire [15:0] vid_a,
	output wire        vid_rd,
	// read data of the memory, to the CPU and to the CRT
	input  wire  [7:0] mem_di,
	// keyboard: rows (PPI port A), columns (port B), special keys (PC7..PC5), tape (PC4)
	output wire  [7:0] ppa_pa,
	input  wire  [7:0] kbd_cols,
	input  wire  [2:0] kbd_shift,
	input  wire        tape_in,
	// sound and tape sources
	output wire        pc0,
	output wire        inte,
	// native video: the CRT outputs
	output wire  [3:0] line,
	output wire  [6:0] ochar,
	output wire        lten,
	output wire        vsp,
	output wire        rvv,
	output wire        hilight,
	output wire  [1:0] lattr,
	output wire  [1:0] gattr,
	output wire        irq,
	// window A000-BFFF for a board device (the SD card on the Karabas boards)
	output wire        ext_we_n,
	input  wire  [7:0] ext_di
);

// The names of the board tops, so that the code below is the moved code.
wire clk50 = clk;
wire[7:0] mem_o = mem_di;
wire vid_cce = cce;
wire vid_hr = hrtc;
wire vid_vr = vrtc;
wire[7:0] kbd_o = kbd_cols;
wire TAPE_IN = tape_in;
wire[7:0] sd_o = ext_di;

//--------- CPU ---------------------
wire[15:0] addrbus;
wire[7:0] cpu_o;
wire cpu_sync;
wire cpu_int;
wire cpu_inta_n;
reg[7:0] cpu_i;
wire hlda;
wire hdla;
wire[7:0] crt_o;
wire[7:0] ppa1_o;

always @(*)
   casex (addrbus[15:13])
      3'b0xx: cpu_i = mem_o;
      3'b100: cpu_i = ppa1_o;
      3'b101: cpu_i = sd_o;
      3'b110: cpu_i = crt_o;
      3'b111: cpu_i = mem_o;
   endcase
	
always @(*)
   casex (addrbus[15:13])
      3'b0xx:  rom = startup ? 1'b1: 1'b0;
      3'b111:  rom = 1'b1;
		default: rom = 1'b0;
   endcase

wire ppa1_we_n = addrbus[15:13]!=3'b100|cpu_wr_n;
wire ppa2_we_n = addrbus[15:13]!=3'b101|cpu_wr_n;
wire crt_we_n  = addrbus[15:13]!=3'b110|cpu_wr_n;
wire crt_rd_n  = addrbus[15:13]!=3'b110|~cpu_rd;
wire dma_we_n  = addrbus[15:13]!=3'b111|cpu_wr_n;

reg[4:0] cpu_cnt;
reg cpu_ce2;
reg[10:0] hldareg;
wire cpu_ce = cpu_ce2;

always @(posedge clk50) begin
	if(reset) begin cpu_cnt<=0; cpu_ce2<=0; hldareg<=11'd0; end
	else
   if((hldareg[10:9] == 2'b01) && ((cpu_rd == 1) || (cpu_wr_n == 0))) begin cpu_cnt <= 0; cpu_ce2 <= 1; end
	else
	if(cpu_cnt < 27) begin cpu_cnt <= cpu_cnt + 5'd1; cpu_ce2 <= 0; end
	else begin cpu_cnt <= 0; cpu_ce2 <= ~hlda; end
	hldareg <= {hldareg[9:0],hlda};
	startup <= reset|(startup&~addrbus[15]);
end

k580wm80a CPU(.clk(clk50), .ce(cpu_ce), .reset(reset),
   .idata(cpu_i), .addr(addrbus), .sync(cpu_sync), .rd(cpu_rd), .wr_n(cpu_wr_n),
   .intr(cpu_int), .inta_n(cpu_inta_n), .odata(cpu_o), .inte_o(inte));

//--------- VIDEO (DMA, CRT) --------------
wire[3:0] vid_line;
wire[6:0] vid_char;
wire[15:0] vid_addr;
wire[3:0] dma_dack;
wire[7:0] dma_o;
wire[7:0] vid_do;
wire[1:0] vid_lattr;
wire[1:0] vid_gattr;
wire vid_drq,vid_irq;
wire vid_lten,vid_vsp,vid_rvv,vid_hilight;
wire dma_owe_n,dma_ord_n,dma_oiowe_n,dma_oiord_n;

assign vid_rd = ~dma_oiord_n;

k580wt57 dma(.clk(clk50), .ce(vid_cce), .reset(reset),
   .iaddr(addrbus[3:0]), .idata(cpu_o), .drq({1'b0,vid_drq,2'b00}), .iwe_n(dma_we_n), .ird_n(1'b1),
   .hlda(hlda), .hrq(hlda), .dack(dma_dack), .odata(dma_o), .oaddr(vid_addr),
   .owe_n(dma_owe_n), .ord_n(dma_ord_n), .oiowe_n(dma_oiowe_n), .oiord_n(dma_oiord_n) );

k580wg75 crt(.clk(clk50), .ce(vid_cce),
   .iaddr(addrbus[0]), .idata(cpu_o), .iwe_n(crt_we_n), .ird_n(crt_rd_n),
   .vrtc(vid_vr), .hrtc(vid_hr), .dack(dma_dack[2]), .ichar(mem_o), .drq(vid_drq), .irq(vid_irq),
   .odata(crt_o), .line(vid_line), .ochar(vid_char), .lten(vid_lten), .vsp(vid_vsp),
   .rvv(vid_rvv), .hilight(vid_hilight), .lattr(vid_lattr), .gattr(vid_gattr) );

//--------- SYS PPA --------------
wire[7:0] ppa1_a;
wire[7:0] ppa1_b;
wire[7:0] ppa1_c;

k580ww55 ppa1(.clk(clk50), .reset(reset), .addr(addrbus[1:0]), .we_n(ppa1_we_n),
   .idata(cpu_o), .odata(ppa1_o), .ipa(ppa1_a), .opa(ppa1_a),
   .ipb(kbd_o), .opb(ppa1_b), .ipc({kbd_shift,TAPE_IN,ppa1_c[3:0]}), .opc(ppa1_c));

//--------- outputs --------------
assign cpu_a    = addrbus;
assign cpu_do   = cpu_o;
assign vid_a    = vid_addr;
assign ppa_pa   = ppa1_a;
assign pc0      = ppa1_c[0];
assign line     = vid_line;
assign ochar    = vid_char;
assign lten     = vid_lten;
assign vsp      = vid_vsp;
assign rvv      = vid_rvv;
assign hilight  = vid_hilight;
assign lattr    = vid_lattr;
assign gattr    = vid_gattr;
assign irq      = vid_irq;
assign ext_we_n = ppa2_we_n;

endmodule

`default_nettype wire
