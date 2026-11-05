// Karabas Go board around the unchanged top radio86rk (included in tb_sys, fuse -d BOARD_GO).
// Defines for the common TB code: the board clock and the DUT, refclk (the reference clock:
// every TB check samples on its falling edge), the SRAM pins, the MCU link pins, the video pins,
// the observed vector obs[OBS_W-1:0] and the counted pins cnt_sig[NCNT-1:0].
// Only top-level pins: no hierarchical paths into the DUT (amendment A7).

localparam [7:0] HW_ID = 8'd1;              // CMD_HW_SETUP (0, HW_ID): 1 = Go (firmware protocol.md)
localparam integer LINK_HALF_PS = 31250;    // classic link SCK 16 MHz
localparam integer BURST_HALF_PS = 31250;   // bursts: BURST_MAX_MHZ = 0 on the Go (16 MHz)
localparam [7:0] BURST_MAX_MHZ = 8'd0;      // expected max_mhz of the CMD_CAPS answer (radio86rk.v keeps the mcu.vhd default 0)
// VGA raster of hvsync_generator.v: CounterX counts 0..count_dots (1056) and CounterY 0..count_lines
// (628) inclusive, so a line is 1057 clocks and a frame 629 lines (plan F21 says 1056 x 628)
localparam integer H_TOTAL = 1057;
localparam integer V_TOTAL = 629;

reg CLK_50MHZ = 1'b0;
always #10 CLK_50MHZ = ~CLK_50MHZ;

wire UART_RX, UART_TX, UART_CTS, ESP_RESET_N, ESP_BOOT_N;
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MWR_N, MRD_N;
wire [1:0] SDR_BA, SDR_DQM;
wire [12:0] SDR_A;
wire SDR_CLK, SDR_WE_N, SDR_CAS_N, SDR_RAS_N;
wire [15:0] SDR_DQ;
wire SD_CS_N, SD_CLK, SD_DI;
wire [7:0] VGA_R, VGA_G, VGA_B;
wire VGA_HS, VGA_VS, V_CLK;
wire FT_SPI_CS_N, FT_SPI_SCK, FT_SPI_MOSI, FT_OE_N;
wire [2:0] WA;
wire [1:0] WCS_N;
wire WRD_N, WWR_N, WRESET_N;
wire [15:0] WD;
wire [1:0] FDC_DRIVE;
wire FDC_MOTOR, FDC_DIR, FDC_STEP, FDC_WDATA, FDC_WGATE, FDC_SIDE_N;
wire TAPE_OUT, BEEPER;
wire DAC_LRCK, DAC_DAT, DAC_BCK, DAC_MUTE;
wire MCU_CS_N, MCU_SCK, MCU_MOSI, MCU_MISO;
wire [3:0] MCU_IO;
wire MIDI_TX, MIDI_CLK, MIDI_RESET_N;
wire FLASH_CS_N, FLASH_DI, FLASH_SCK, FLASH_WP_N, FLASH_HOLD_N;

radio86rk dut(
	.CLK_50MHZ(CLK_50MHZ),
	.UART_RX(UART_RX), .UART_TX(UART_TX), .UART_CTS(UART_CTS), .ESP_RESET_N(ESP_RESET_N), .ESP_BOOT_N(ESP_BOOT_N),
	.MA(MA), .MD(MD), .MWR_N(MWR_N), .MRD_N(MRD_N),
	.SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_CLK(SDR_CLK), .SDR_DQM(SDR_DQM), .SDR_WE_N(SDR_WE_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_RAS_N(SDR_RAS_N), .SDR_DQ(SDR_DQ),
	.SD_CS_N(SD_CS_N), .SD_CLK(SD_CLK), .SD_DI(SD_DI), .SD_DO(1'b1), .SD_DET_N(1'b1),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .V_CLK(V_CLK),
	.FT_SPI_CS_N(FT_SPI_CS_N), .FT_SPI_SCK(FT_SPI_SCK), .FT_SPI_MISO(1'b1), .FT_SPI_MOSI(FT_SPI_MOSI),
	.FT_INT_N(1'b1), .FT_CLK(1'b0), .FT_OE_N(FT_OE_N),
	.WA(WA), .WCS_N(WCS_N), .WRD_N(WRD_N), .WWR_N(WWR_N), .WRESET_N(WRESET_N), .WD(WD),
	.FDC_INDEX(1'b1), .FDC_DRIVE(FDC_DRIVE), .FDC_MOTOR(FDC_MOTOR), .FDC_DIR(FDC_DIR), .FDC_STEP(FDC_STEP),
	.FDC_WDATA(FDC_WDATA), .FDC_WGATE(FDC_WGATE), .FDC_TR00(1'b1), .FDC_WPRT(1'b1), .FDC_RDATA(1'b1),
	.FDC_SIDE_N(FDC_SIDE_N),
	.TAPE_OUT(TAPE_OUT), .TAPE_IN(1'b0), .BEEPER(BEEPER),
	.DAC_LRCK(DAC_LRCK), .DAC_DAT(DAC_DAT), .DAC_BCK(DAC_BCK), .DAC_MUTE(DAC_MUTE),
	.MCU_CS_N(MCU_CS_N), .MCU_SCK(MCU_SCK), .MCU_MOSI(MCU_MOSI), .MCU_MISO(MCU_MISO), .MCU_IO(MCU_IO),
	.MIDI_TX(MIDI_TX), .MIDI_CLK(MIDI_CLK), .MIDI_RESET_N(MIDI_RESET_N),
	.FLASH_CS_N(FLASH_CS_N), .FLASH_DO(1'b1), .FLASH_DI(FLASH_DI), .FLASH_SCK(FLASH_SCK),
	.FLASH_WP_N(FLASH_WP_N), .FLASH_HOLD_N(FLASH_HOLD_N)
);

// reference clock: the pixel clock on the pin V_CLK (ODDR2 of clk50)
wire refclk = V_CLK;

// SRAM (byte lane 0 only: MWR_N[1] / MRD_N[1] are tied high in the top)
wire [20:0] sram_a = MA;
wire sram_wr_n = MWR_N[0];
wire sram_rd_n = MRD_N[0];
sram_model sram(.refclk(refclk), .cyc(cyc), .ma(sram_a), .md(MD[7:0]), .mwr_n(sram_wr_n), .mrd_n(sram_rd_n));

// MCU link: classic chip select MCU_CS_N, burst chip select MCU_IO[1] (pull-up in pins.ucf),
// burst ready MCU_IO[0] (radio86rk.v: MCU_IO[0] = ready, MCU_IO[3:1] = z)
wire link_cs_n, link_sck, link_mosi, link_bcs_n;
assign MCU_CS_N = link_cs_n;
assign MCU_SCK = link_sck;
assign MCU_MOSI = link_mosi;
assign MCU_IO[1] = link_bcs_n;
pullup (MCU_IO[1]);
wire link_miso = MCU_MISO;
wire link_bready = MCU_IO[0];
mcu_link #(.HALF_PS(LINK_HALF_PS), .BURST_HALF_PS(BURST_HALF_PS)) link(.refclk(refclk),
	.cs_n(link_cs_n), .sck(link_sck), .mosi(link_mosi), .bcs_n(link_bcs_n), .miso(link_miso), .bready(link_bready));

// video
wire vid_hs = VGA_HS;
wire vid_vs = VGA_VS;
wire [23:0] vid_rgb = {VGA_R, VGA_G, VGA_B};

// observed vector (L0, amendment A8): every output and inout pin of the top except the free-running
// clocks V_CLK (the reference clock) and MIDI_CLK (counted below). MCU_MISO only while MCU_CS_N = 0
// (otherwise it depends on unconnected mcu inputs, 'U' in RTL). Undriven inouts are Z.
localparam integer OBS_W = 167;
wire [OBS_W-1:0] obs = {
	MA, MD, MWR_N, MRD_N,                                                     // 41
	VGA_R, VGA_G, VGA_B, VGA_HS, VGA_VS,                                      // 26
	BEEPER, TAPE_OUT, DAC_DAT, DAC_BCK, DAC_LRCK, DAC_MUTE,                   // 6
	SD_CS_N, SD_CLK, SD_DI,                                                   // 3
	(MCU_CS_N ? 1'b0 : MCU_MISO), MCU_MOSI, MCU_IO,                           // 6
	UART_RX, UART_TX, UART_CTS, ESP_RESET_N, ESP_BOOT_N,                      // 5
	SDR_BA, SDR_A, SDR_CLK, SDR_DQM, SDR_WE_N, SDR_CAS_N, SDR_RAS_N, SDR_DQ,  // 37
	FT_SPI_CS_N, FT_SPI_SCK, FT_SPI_MOSI, FT_OE_N,                            // 4
	WA, WCS_N, WRD_N, WWR_N, WRESET_N, WD,                                    // 24
	FDC_DRIVE, FDC_MOTOR, FDC_DIR, FDC_STEP, FDC_WDATA, FDC_WGATE, FDC_SIDE_N, // 8
	MIDI_TX, MIDI_RESET_N,                                                    // 2
	FLASH_CS_N, FLASH_DI, FLASH_SCK, FLASH_WP_N, FLASH_HOLD_N                 // 5
};
// counted pins (rising edges per trace window): MIDI_CLK (clk12 through ODDR2; its rising edges
// fall on rising edges of clk50, never on the sampling edge) and DAC_MUTE (amendment A8)
localparam integer NCNT = 2;
wire [NCNT-1:0] cnt_sig = {MIDI_CLK, DAC_MUTE};
