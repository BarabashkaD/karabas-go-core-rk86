//// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of Radio-86RK home computer
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
// 
// Design File: radio86rk.v
//
// Top level design file.
// -------------------------------------------------------------------- 
// Ported to "Aeon Lite" by Dmitriy Schapotschkin aka ILoveSpeccy
// http://www.speccyland.net '2015
//
// Ported to "ZX UNO" by Andy Karpov 
// https://github.com/andykarpov/rk86-zxuno '2018
//
// Ported to "Karabas GO" by Oleh Chastukhin
// https://github.com/Caasper911/karabas-go-core-rk86 '2024

module radio86rk(
   //---------------------------
   input wire CLK_50MHZ,

	//---------------------------
	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,
	
   //---------------------------
   output wire [20:0] MA,
   inout wire [15:0] MD,
   output wire [1:0] MWR_N,
   output wire [1:0] MRD_N,

   //---------------------------
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

   //---------------------------
   output wire SD_CS_N,
   output wire SD_CLK,
   inout wire SD_DI,
   input wire SD_DO,
	input wire SD_DET_N,

   //---------------------------
   output wire [7:0] VGA_R,
   output wire [7:0] VGA_G,
   output wire [7:0] VGA_B,
   output wire VGA_HS,
   output wire VGA_VS,
	output wire V_CLK,
	
	//---------------------------
	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	//---------------------------
	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,
	
	//---------------------------
	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

   //---------------------------	
	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,
	
	//---------------------------
	output wire DAC_LRCK,
   output wire DAC_DAT,
   output wire DAC_BCK,
   output wire DAC_MUTE,
	
	//---------------------------
	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	inout wire [3:0] MCU_IO, // [0] burst ready (N9), [1] burst cs_n (M11)
	
	//---------------------------
	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,
	
	//---------------------------
	output wire FLASH_CS_N,
	input wire  FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N	
);

assign BEEPER = (ppa1_c[0]^inte)&sound;
assign TAPE_OUT = ppa1_c[0];
assign DAC_MUTE = 1'b1;
assign ESP_RESET_N = 1'b1;
assign ESP_BOOT_N = 1'b1;
assign UART_CTS = 1'b0;
assign WA = 16'b0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign SDR_BA = 2'b00;
assign SDR_A = 13'b0;
assign SDR_CLK = 1'b0;
assign SDR_DQM = 2'b00;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_SIDE_N = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;

assign FDC_STEP = 1'b0;
assign FDC_DIR = 1'b0;
assign FT_SPI_CS_N = 1'b1;
assign FT_SPI_MOSI = 1'b0;
assign FT_SPI_SCK = 1'b0;
assign FT_OE_N = 1'b1;

assign MWR_N[1] = 1'b1;
assign MRD_N[1] = 1'b1;

assign MIDI_TX = 1'b1;
//assign MIDI_CLK = 1'b0;
assign MIDI_RESET_N = 1'b1;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;


wire [7:0] hid_kb_status;
wire [7:0] hid_kb_dat0;
wire [7:0] hid_kb_dat1;
wire [7:0] hid_kb_dat2;
wire [7:0] hid_kb_dat3;
wire [7:0] hid_kb_dat4;
wire [7:0] hid_kb_dat5;

reg startup;

wire hdla;
wire cpurst;
wire videomode;
wire sound;
wire[1:0] rom_sel; 

wire[7:0] ppa1_o;
wire[7:0] ppa1_a;
wire[7:0] ppa1_b;
wire[7:0] ppa1_c;

wire [7:0] video_r;
wire [7:0] video_g;
wire [7:0] video_b;

//---------- PLL ------------
pll pll (
  .CLK_IN1(CLK_50MHZ),
  .CLK_OUT1(clk50),
  .CLK_OUT2(clk25),
  .CLK_OUT3(clk12),
  .LOCKED(locked)
);

assign areset = ~locked;

ODDR2 ODDR2_inst (
	.Q(V_CLK),
	.C0(clk50),
	.C1(~clk50),
	.CE(1'b1),
	.D0(1'b1),
	.D1(1'b0),
	.R(1'b0),
	.S(1'b0)
);

ODDR2 ODDR2_inst1 (  //clock for midi to avoid random noises 
	.Q(MIDI_CLK),
	.C0(clk12),
	.C1(~clk12),
	.CE(1'b1),
	.D0(1'b1),
	.D1(1'b0),
	.R(1'b0),
	.S(1'b0)
);

//---------- MCU ------------
wire [15:0] softsw_command;
wire [15:0] osd_command;

reg fileloader_reset;
reg fileloader_wr;

reg[31:0] fileloader_addr, loader_ram_a;
reg[7:0]  fileloader_data, loader_ram_do;

wire[20:0] load_a;
wire[7:0]  load_d;
wire		  load_wr;
wire 		  loading;

wire[12:0] joy_l;
wire[12:0] joy_r;
wire joy_rst;
wire osd_act;

// burst transfers from the mcu (karabas-go-firmware docs/burst_protocol.md)
wire mcu_burst_ready;
assign MCU_IO[0] = mcu_burst_ready;
assign MCU_IO[3:1] = 3'bzzz;

mcu mcu(
	.CLK(clk50),
	.N_RESET(~areset),
	
	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SCK(MCU_SCK),
	.MCU_SS(MCU_CS_N),
	// burst transfers: firmware IO0 (GPIO14) = MCU_IO[1] (M11), IO1 (GPIO2) = MCU_IO[0] (N9)
	.MCU_BURST_CS_N(MCU_IO[1]),
	.MCU_BURST_READY(mcu_burst_ready),

	.KB_STATUS(hid_kb_status),
	.KB_DAT0(hid_kb_dat0),
	.KB_DAT1(hid_kb_dat1),
	.KB_DAT2(hid_kb_dat2),
	.KB_DAT3(hid_kb_dat3),
	.KB_DAT4(hid_kb_dat4),
	.KB_DAT5(hid_kb_dat5),
	 
	.JOY_L(joy_l),
	.JOY_R(joy_r),
	 
	.ROMLOADER_ACTIVE(loader_act),
	.ROMLOAD_ADDR(loader_ram_a),
	.ROMLOAD_DATA(loader_ram_do),
	.ROMLOAD_WR(loader_ram_wr),
	
	.FILELOAD_RESET(fileloader_reset),
	.FILELOAD_ADDR(fileloader_addr),
	.FILELOAD_DATA(fileloader_data),
	.FILELOAD_WR(fileloader_wr),
	.SOFTSW_COMMAND(softsw_command),	
	.OSD_COMMAND(osd_command)
);

//---------- Keyboard parser ------------
wire[7:0] kbd_o;
wire[2:0] kbd_shift;

wire loaded_done;

karabas_keyboard keyboard(
	.clk(clk50),
	.areset(areset),
	.osd_act(osd_act),
	.hid_kb_status(hid_kb_status),
	.hid_kb_dat0(hid_kb_dat0),
	.hid_kb_dat1(hid_kb_dat1),
	.hid_kb_dat2(hid_kb_dat2),
	.hid_kb_dat3(hid_kb_dat3),
	.hid_kb_dat4(hid_kb_dat4),
	.hid_kb_dat5(hid_kb_dat5),
	.joy_l(joy_l),
	.joy_r(joy_r),
	.ppa_pa(ppa1_a),
	.loading(loading),
	.loaded_done(loaded_done),
	.enable_autorun(enable_autorun),
	.kbd_cols(kbd_o),
	.kbd_shift(kbd_shift),
	.joy_rst(joy_rst)
);

//---------- Soft switches ------------

soft_switches soft_switches(
	.CLK(clk50),
	
	.SOFTSW_COMMAND(softsw_command),
	.VMODE(videomode),
	.SOUND(sound),
	.RESET(cpurst),
	.ROM_SEL(rom_sel),
	.AUTORUN(enable_autorun)
);

//--------- RESET --------------
reg[3:0] reset_cnt;
reg reset_n;
wire reset = ~reset_n | loading;

always @(posedge clk50) begin
   if (!(cpurst | joy_rst) && reset_cnt==4'd14)
      reset_n <= 1'b1;
   else begin
      reset_n <= 1'b0;
      reset_cnt <= reset_cnt+4'd1;
   end
end

//--------- MEM --------------
wire[7:0] mem_o = MD[7:0];

assign MD[7:0]  = MWR_N[0] ? 8'bZZZZZZZZ : (loading ? load_d : cpu_o);

assign MA = loading ? load_a : 
				(vid_rd ? {6'b000000,vid_addr[14:0]} : (rom ? rom_a :{6'b000000,addrbus[14:0]}));

assign MWR_N[0] = loading ? (~load_wr) : (vid_rd ? 1'b1 : cpu_wr_n|addrbus[15]);
assign MRD_N[0] = loading ? 1'b1:(vid_rd ? 1'b0 : (~cpu_rd));

//--------- BIOS SELECT --------------
reg[20:0] rom_a;

always @(*) begin
	if (rom_sel==2'b00)
		rom_a <= {9'b0000100,rom_sel,addrbus[11]|startup,addrbus[10:0]};
	else
		rom_a <= {9'b0000100,rom_sel,1'b0,addrbus[10:0]};
end

//--------- LOADER -----------------
loader loader(.reset((cpurst | joy_rst)),.clk50(clk50),.loader_act(loader_act),.loader_ram_a(loader_ram_a),
				  .loader_ram_do(loader_ram_do),.loader_ram_wr(loader_ram_wr),
				  .fileloader_reset(fileloader_reset),.fileloader_addr(fileloader_addr),
				  .fileloader_data(fileloader_data),.fileloader_wr(fileloader_wr),
				  .sram_a(load_a),.sram_wr(load_wr),.sram_d(load_d),.loading(loading),.done(loaded_done)
				  );
				  
//--------- CPU ---------------------
wire[15:0] addrbus;
wire[7:0] cpu_o;
wire cpu_sync;
wire cpu_rd;
wire cpu_wr_n;
wire cpu_int;
wire cpu_inta_n;
wire inte;
reg[7:0] cpu_i;

reg rom;

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

//--------- VIDEO --------------
wire[7:0] crt_o;
wire[3:0] vid_line;
wire[6:0] vid_char;
wire[15:0] vid_addr;
wire[3:0] dma_dack;
wire[7:0] dma_o;
wire[7:0] vid_do;
wire[1:0] vid_lattr;
wire[1:0] vid_gattr;
wire vid_cce,vid_drq,vid_irq;
wire vid_lten,vid_vsp,vid_rvv,vid_hilight;
wire dma_owe_n,dma_ord_n,dma_oiowe_n,dma_oiord_n;

wire vid_rd = ~dma_oiord_n;

k580wt57 dma(.clk(clk50), .ce(vid_cce), .reset(reset),
   .iaddr(addrbus[3:0]), .idata(cpu_o), .drq({1'b0,vid_drq,2'b00}), .iwe_n(dma_we_n), .ird_n(1'b1),
   .hlda(hlda), .hrq(hlda), .dack(dma_dack), .odata(dma_o), .oaddr(vid_addr),
   .owe_n(dma_owe_n), .ord_n(dma_ord_n), .oiowe_n(dma_oiowe_n), .oiord_n(dma_oiord_n) );

wire vid_vr, vid_hr;

k580wg75 crt(.clk(clk50), .ce(vid_cce),
   .iaddr(addrbus[0]), .idata(cpu_o), .iwe_n(crt_we_n), .ird_n(crt_rd_n),
   .vrtc(vid_vr), .hrtc(vid_hr), .dack(dma_dack[2]), .ichar(mem_o), .drq(vid_drq), .irq(vid_irq),
   .odata(crt_o), .line(vid_line), .ochar(vid_char), .lten(vid_lten), .vsp(vid_vsp),
   .rvv(vid_rvv), .hilight(vid_hilight), .lattr(vid_lattr), .gattr(vid_gattr) );

wire vid_pix;
	
rk_video vid(
	.clk(clk50), 
	.hr(VGA_HS), 
	.vr(VGA_VS), 
   .hr_wg75(vid_hr), 
	.vr_wg75(vid_vr),
	.cce(vid_cce),
	.pixel(vid_pix),
   .blank(), 
	.line(vid_line), 
	.ichar(vid_char),
   .vsp(vid_vsp), 
	.lten(vid_lten), 
	.rvv(vid_rvv)
);

assign video_r = vid_pix ? (videomode ? 8'b00100000 : 8'b10000000 ) : 8'b00000000;
assign video_g = vid_pix ? (videomode ? 8'b10000000 : 8'b10000000 ) : 8'b00000000;
assign video_b = vid_pix ? (videomode ? 8'b00100000 : 8'b10000000 ) : 8'b00000000;

//--------- SYS PPA --------------
k580ww55 ppa1(.clk(clk50), .reset(reset), .addr(addrbus[1:0]), .we_n(ppa1_we_n),
   .idata(cpu_o), .odata(ppa1_o), .ipa(ppa1_a), .opa(ppa1_a),
   .ipb(kbd_o), .opb(ppa1_b), .ipc({kbd_shift,TAPE_IN,ppa1_c[3:0]}), .opc(ppa1_c));

reg sdcs;
reg sdclk;
reg sdcmd;
reg[6:0] sddata;
wire[7:0] sd_o = {sddata, SD_DO};

assign SD_CS_N = ~sdcs;
assign SD_DI = sdcmd;
assign SD_CLK = sdclk;

always @(posedge clk50 or posedge reset) begin
   if (reset) begin
      sdcs <= 1'b0;
      sdclk <= 1'b0;
      sdcmd <= 1'h1;
   end else begin
      if (addrbus[0]==1'b0 && ~ppa2_we_n) sdcs <= cpu_o[0];
      if (addrbus[0]==1'b1 && ~ppa2_we_n) begin
         if (sdclk) sddata <= {sddata[5:0],SD_DO};
         sdcmd <= cpu_o[7];
         sdclk <= 1'b0;
      end
      if (cpu_rd) sdclk <= 1'b1;
   end
end

//--------- OSD --------------

overlay overlay(
	.CLK(clk50),
	.CLK_VGA(clk50),
	.RGB_I({video_r[7:0], video_g[7:0], video_b[7:0]}),
	.RGB_O({VGA_R, VGA_G, VGA_B}),
	.HSYNC_I(VGA_HS),
	.VSYNC_I(VGA_VS),
	.OSD_ACT(osd_act),
	.OSD_COMMAND(osd_command)
);

//---------- DAC ------------

PCM5102 PCM5102(
	.clk(clk50),
	.reset(reset),
	.left ({6'b0, inte&sound, 9'b0}),
	.right({6'b0, inte&sound, 9'b0}),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_LRCK)
);

endmodule
