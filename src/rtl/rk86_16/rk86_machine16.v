// The Radio-86RK machine with the original 16 MHz timing (rk86_16/README.md; spec of the Pocket core
// 0.8.0): the 8224 + ИЕ4 clocks, the 8080 (Vslav's model), the 8257 on both Φ2 edges, the 8275 on the
// ИЕ4 character clock, the keyboard 8255, the board's video path, and the glue of the Радио 1986 board:
// the devices decode the system address (the DMA's while the 8257's AEN is high); ЧТЕНИЕ = DBIN XOR
// MEMW; the 8275 WR = CPU WR AND the 8257 IOR; the memory write strobe is the CPU's WR; during start-up
// (RESET to the first read with A15 = 1) the monitor answers every address, RAM and every device off.
`default_nettype none
module rk86_machine16 #(parameter [3:0] LOAD_STATE = 4'd10) (
    input  wire        clk,
    input  wire        ce16,          // one 16 MHz period
    input  wire        reset,         // to the 8224 RESIN; held at least 16 Φ (144 ce16) by the board
    output wire [15:0] cpu_a,         // the CPU's address (also while the DMA owns the bus)
    output wire [15:0] bus_a,
    output wire  [7:0] cpu_do,
    output wire        mem_rd,        // ЧТЕНИЕ, active high
    output wire        cpu_wr_n,
    output reg         rom,           // the monitor selected: E000-FFFF, or every address while startup
    output reg         startup = 1'b1,
    output wire        aen,
    input  wire  [7:0] mem_di,        // the memory at bus_a
    output wire  [7:0] ppa_pa,
    input  wire  [7:0] kbd_cols,
    input  wire  [2:0] kbd_shift,
    input  wire        tape_in,
    output wire        pc0,
    output wire        inte,
    output wire  [9:0] font_addr,
    input  wire  [7:0] font_data,
    output wire        pix_ce,
    output wire        pix,
    output wire        hrtc,
    output wire        vrtc,
    output wire        ext_we_n,      // window A000-BFFF
    output wire        ext_rd_n,
    input  wire  [7:0] ext_di
);
//---------------- 8224 and ИЕ4
wire f1, f2, f2_fall, sys_reset, ready, cpu_sync, dot_ce, cclk_fall;
wire [3:0] cnt12;
rk86_clocks16 clocks(.clk(clk), .ce16(ce16), .resin_n(~reset), .rdyin(1'b1), .sync(cpu_sync),
    .f1(f1), .f2(f2), .f2_fall(f2_fall), .phi1(), .phi2(), .reset(sys_reset), .ready(ready), .ststb_n(),
    .ie4(), .cnt12(cnt12), .dot_ce(dot_ce), .cclk_fall(cclk_fall), .cclk_rise());
//---------------- 8080
wire [15:0] dma_a;
wire [7:0] crt_o, ppa_o;
reg  [7:0] cpu_i;
wire cpu_dbin, hold, hlda;
k580vm80a cpu(.pin_clk(clk), .pin_f1(f1), .pin_f2(f2), .pin_reset(sys_reset),
    .pin_a(cpu_a), .pin_dout(cpu_do), .pin_din(cpu_i), .pin_aena(), .pin_dena(),
    .pin_hold(hold), .pin_hlda(hlda), .pin_ready(ready), .pin_wait(), .pin_int(1'b0),
    .pin_inte(inte), .pin_sync(cpu_sync), .pin_dbin(cpu_dbin), .pin_wr_n(cpu_wr_n));
//---------------- the address decoder on the system address; off during start-up (GLUE-11: D13.2 disables D11)
wire dec_en = !startup;
wire sel_ppa = dec_en && bus_a[15:13] == 3'b100;
wire sel_ext = dec_en && bus_a[15:13] == 3'b101;
wire sel_crt = dec_en && bus_a[15:13] == 3'b110;
wire sel_top = dec_en && bus_a[15:13] == 3'b111;      // writes: the 8257; reads: the monitor
wire memw_n, ior_n;
wire rd_line_n = cpu_dbin ^ memw_n;          // ЧТЕНИЕ (active low) = DBIN XOR MEMW (D5.1 / U16A)
assign mem_rd = !rd_line_n;
//---------------- 8257
wire [3:0] dack_n;
wire crt_drq;
k580vt57 dma(.clk(clk), .th_up(f2), .th_dn(f2_fall), .reset(sys_reset),
    .cs_n(~sel_top), .ior_n_i(1'b1), .iow_n_i(cpu_wr_n), .a_i(bus_a[3:0]), .d_i(cpu_do), .d_o(),
    .drq({1'b0, crt_drq, 2'b00}), .hlda(hlda), .ready(ready), .hrq(hold), .dack_n(dack_n), .a_o(dma_a),
    .aen(aen), .adstb(), .memr_n(), .memw_n(memw_n), .ior_n_o(ior_n), .iow_n_o(), .tc(), .mark());
assign bus_a = aen ? dma_a : cpu_a;
//---------------- 8275
wire [6:0] cc;
wire [3:0] lc;
wire vsp, lten, rvv;
k580vg75 crt(.clk(clk), .cclk(cclk_fall), .cs_n(~sel_crt), .rd_n(rd_line_n), .wr_n(cpu_wr_n & ior_n), .a0(bus_a[0]),
    .d_i(aen ? mem_di : cpu_do), .d_o(crt_o), .drq(crt_drq), .dack_n(dack_n[2]), .irq(), .lpen(1'b0),
    .hrtc(hrtc), .vrtc(vrtc), .cc(cc), .lc(lc), .la(), .vsp(vsp), .lten(lten), .rvv(rvv), .hglt(), .gpa());
//---------------- the keyboard 8255 (8000-9FFF): PA rows out, PB columns in, PC7-PC5 shift keys, PC4 tape in
wire [7:0] pa_o, pb_o, pc_o, pc_oe;
wire pa_oe, pb_oe;
k580vv55 ppa(.clk(clk), .reset(sys_reset), .cs_n(~sel_ppa), .rd_n(rd_line_n), .wr_n(cpu_wr_n), .a(bus_a[1:0]),
    .d_i(cpu_do), .d_o(ppa_o), .pa_i(8'hFF), .pa_o(pa_o), .pa_oe(pa_oe), .pb_i(kbd_cols), .pb_o(pb_o), .pb_oe(pb_oe),
    .pc_i({kbd_shift, tape_in, 4'hF}), .pc_o(pc_o), .pc_oe(pc_oe));
assign ppa_pa = pa_oe ? pa_o : 8'hFF;
assign pc0 = pc_oe[0] ? pc_o[0] : 1'b1;
//---------------- the window and the CPU's data input
assign ext_we_n = ~sel_ext | cpu_wr_n;
assign ext_rd_n = ~sel_ext | rd_line_n;
always @(*)
    if (startup) cpu_i = mem_di;                     // the monitor at every address (rom)
    else
        casex (cpu_a[15:13])
            3'b0xx:  cpu_i = mem_di;
            3'b100:  cpu_i = ppa_o;
            3'b101:  cpu_i = ext_di;
            3'b110:  cpu_i = crt_o;
            default: cpu_i = mem_di;
        endcase
always @(*) rom = !aen && (startup || cpu_a[15:13] == 3'b111);
// GLUE-12: set by RESET, ended by the first read with A15 = 1 (DBIN AND A15, Kiselev 1.4 U17B / U20A)
always @(posedge clk) startup <= sys_reset | (startup & ~(cpu_dbin & cpu_a[15]));
//---------------- the video path
rk86_video16 #(.LOAD_STATE(LOAD_STATE)) video(.clk(clk), .dot_ce(dot_ce), .cnt12(cnt12), .cc(cc), .lc(lc),
    .vsp(vsp), .lten(lten), .rvv(rvv), .font_addr(font_addr), .font_data(font_data), .pix(pix));
assign pix_ce = dot_ce;
endmodule
`default_nettype wire
