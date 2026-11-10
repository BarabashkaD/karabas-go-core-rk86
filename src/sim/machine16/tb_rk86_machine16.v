// rk86_machine16, the Radio-86RK machine with the original 16 MHz timing. Part 1 (Task 12): the monitor
// boots to its keyboard loop (FE63) and the board glue of the Радио 1986 board (Task 2 GLUE-n) holds at
// every clk. Part 2 (Task 13): the bus timing during the frames (bus_timing, below the frame block): the
// T-state, the raster, the DMA per character and per burst, IR, underrun, the HOLD / WR and AEN / DBIN
// handshake. Task 14 adds to it.
// The glue checks probe the ports of the chip instances (dut.cpu, dut.dma, dut.crt, dut.ppa, dut.clocks,
// dut.video) and the TB memory, never the machine's internal nets: each expectation is made from the
// ports of the driving instances and compared with the port of the driven one (GLUE-1 decoder, GLUE-3
// ЧТЕНИЕ, GLUE-4 / 5 the 8257, GLUE-6 the 8275 WR gate, GLUE-7 / 8 the tied pins, GLUE-9 RESET,
// GLUE-11 / 12 start-up, GLUE-13 the bus during HOLD).
// Frames (spec 7): counted as VRTC rises from the first VRTC rise after the 8275's VE rises (frame 0
// starts there); the run ends FRAMES frames after the start of frame 0. The arming point (spec 8): the
// second VRTC rise after the first clk with the 8257 mode A4h (arm, fa).
// After the frames: RESET is pulsed for 200 ce16 (GLUE-9: it re-arms start-up; the boot checks run until
// start-up ends again at the F836 read); then the end condition alone (GLUE-12): start-up is set by a
// one-clk force and released, so the flip-flop itself holds it through reads with A15 = 0 (A14..A0 set),
// an A15 address without DBIN and a write, and must end at a read with A15 = 1; then a decoder sweep
// forces the CPU address over 0000-FFFF (reads, then writes; start-up off, then on; AEN and the 8257
// strobes forced inactive) and counts the selects of every range, so the decoder edges (7FFF / 8000,
// 9FFF / A000, BFFF / C000, DFFF / E000) are checked whatever the boot does; last, two passes with AEN
// forced high and the 8257 address below 8000 while the CPU address sweeps 0000-FFFF: nothing answers
// (the decoder takes the system address, GLUE-13). The forces are never released: the sweep stays last.
// Plusargs: +bios=<hex, 2048 bytes> +font=<hex, 1024 bytes> ($readmemh; run_machine16_sim.py writes them).
// Compile cpu_power_up.vh (the macro CPU16_ZERO) before this file.
`default_nettype none
`timescale 1ns/1ns
module tb_rk86_machine16;
parameter FRAMES = 12;
localparam integer FRAME16 = 319920;            // ce16 per frame (310 lines of 1032 ce16)
localparam integer VE_LIMIT = 3200000;          // 10 frames
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
integer n16 = 0;
reg reset = 1'b1;
always @(posedge clk)
    if (ce16) begin
        n16 <= n16 + 1;
        if (n16 == 199) reset <= 1'b0;          // high for the first 200 ce16
    end

//---------------- the machine, the memory, the font ROM
wire [15:0] cpu_a, bus_a;
wire  [7:0] cpu_do, mem_di, ppa_pa;
wire        mem_rd, cpu_wr_n, rom, startup, aen, pc0, inte, pix_ce, pix, hrtc, vrtc, ext_we_n, ext_rd_n;
wire  [9:0] font_addr;
reg   [7:0] font_data = 8'h00;
reg   [7:0] kbd_cols = 8'hFF;
reg   [2:0] kbd_shift = 3'b111;
reg         tape_in = 1'b0;
reg   [7:0] ext_di = 8'hFF;
rk86_machine16 dut(.clk(clk), .ce16(ce16), .reset(reset), .cpu_a(cpu_a), .bus_a(bus_a), .cpu_do(cpu_do),
    .mem_rd(mem_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup), .aen(aen), .mem_di(mem_di),
    .ppa_pa(ppa_pa), .kbd_cols(kbd_cols), .kbd_shift(kbd_shift), .tape_in(tape_in), .pc0(pc0), .inte(inte),
    .font_addr(font_addr), .font_data(font_data), .pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc),
    .ext_we_n(ext_we_n), .ext_rd_n(ext_rd_n), .ext_di(ext_di));
tb_rk86_mem16 mem(.clk(clk), .bus_a(bus_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom), .aen(aen),
    .mem_rd(mem_rd), .mem_di(mem_di));
reg [7:0] font [0:1023];
always @(posedge clk) font_data <= font[font_addr];        // latency 1 clk

//---------------- errors
integer errors = 0;
integer phase = 0;     // 0 the boots; 5 the end condition; 1-4, 6-7 the decoder sweep; 9 between
task fail; begin
    errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: machine16: too many errors"); $finish; end
end endtask
task gerr(input [8*72-1:0] what); begin
    $display("ERROR: glue: %0s (ce16 %0d, cpu_a %h, bus_a %h, aen %b, startup %b, phase %0d)",
             what, n16, dut.cpu.pin_a, dut.bus_a, dut.dma.aen, dut.startup, phase);
    fail;
end endtask

//---------------- power-up, the ROMs
reg [8*512-1:0] bios_file, font_file;
initial begin
    `CPU16_ZERO(dut.cpu)
    if (!$value$plusargs("bios=%s", bios_file)) begin $display("FATAL: machine16: no +bios=<hex file>"); $finish; end
    if (!$value$plusargs("font=%s", font_file)) begin $display("FATAL: machine16: no +font=<hex file>"); $finish; end
    $readmemh(bios_file, mem.bios);
    $readmemh(font_file, font);
    if ((^mem.bios[0]) === 1'bx || (^mem.bios[2047]) === 1'bx) begin
        $display("FATAL: machine16: the BIOS %0s is not 2048 bytes", bios_file); $finish; end
    if ((^font[0]) === 1'bx || (^font[1023]) === 1'bx) begin
        $display("FATAL: machine16: the font %0s is not 1024 bytes", font_file); $finish; end
end

//---------------- the expectations, from the ports of the driving instances
wire [15:0] x_bus = dut.dma.aen ? dut.dma.a_o : dut.cpu.pin_a;        // GLUE-10, GLUE-13
wire        x_rd_n = dut.cpu.pin_dbin ^ dut.dma.memw_n;                  // ЧТЕНИЕ (GLUE-3)
wire        x_dec = !dut.startup;                                        // D11 G1 (GLUE-1, GLUE-11)
wire        x_ppa = x_dec && x_bus[15:13] == 3'b100;                     // GLUE-1: Y4 8000-9FFF
wire        x_ext = x_dec && x_bus[15:13] == 3'b101;                     // Y5 A000-BFFF
wire        x_crt = x_dec && x_bus[15:13] == 3'b110;                     // Y6 C000-DFFF
wire        x_top = x_dec && x_bus[15:13] == 3'b111;                     // Y7 E000-FFFF
// the start-up flip-flop (GLUE-9, GLUE-12): set by the 8224 RESET, ended at the clk after the first clk
// with DBIN and A15 both high
reg su_exp = 1'b1;
always @(posedge clk) su_exp <= dut.clocks.reset | (su_exp & ~(dut.cpu.pin_dbin & dut.cpu.pin_a[15]));

//---------------- the sample counts (no vacuous pass); [phase]
integer c_ppa [0:7], c_crt [0:7], c_dma [0:7], c_wer [0:7], c_rdr [0:7], c_rom [0:7], c_n [0:7];
integer c_din_mem [0:7], c_din_ppa [0:7], c_din_ext [0:7], c_din_crt [0:7];
integer c_su = 0, c_su_rd = 0, c_su_low = 0, su_ends = 0, c_dma_a = 0, c_dma_rd = 0, c_dma_wr = 0;
integer c_cpu_crt_wr = 0, c_cpu_crt_rd = 0, c_rom_high = 0, k0;
initial for (k0 = 0; k0 < 8; k0 = k0 + 1) begin
    c_n[k0] = 0; c_ppa[k0] = 0; c_crt[k0] = 0; c_dma[k0] = 0; c_wer[k0] = 0; c_rdr[k0] = 0; c_rom[k0] = 0;
    c_din_mem[k0] = 0; c_din_ppa[k0] = 0; c_din_ext[k0] = 0; c_din_crt[k0] = 0;
end
reg su_q = 1'b1;
reg [7:0] x_din;

//---------------- the glue, at every clk (sampled at the falling edge, between the enables)
always @(negedge clk) begin
    // start-up (GLUE-11, GLUE-12; the controller's ruling): the monitor answers every address, the
    // decoder is off
    if (phase == 0 || phase == 5) begin
        if (dut.startup !== su_exp)
            gerr(!su_exp ? "start-up not ended by the first read with A15 = 1"
                 : dut.clocks.reset ? "start-up not set by RESET" : "start-up ended before the first read with A15 = 1");
    end
    if (phase == 0) begin
        if (su_q && !su_exp) su_ends = su_ends + 1;
        su_q = su_exp;
        if (su_exp && !dut.clocks.reset) begin
            c_su = c_su + 1;
            if (dut.cpu.pin_dbin) begin c_su_rd = c_su_rd + 1; if (!dut.cpu.pin_a[15]) c_su_low = c_su_low + 1; end
        end
        if (!dut.clocks.reset && (^{dut.cpu.pin_a, dut.cpu.pin_dbin, dut.cpu.pin_wr_n, dut.cpu.pin_sync}) === 1'bx)
            gerr("X on the CPU pins");
    end
    if (dut.startup) begin
        if (!dut.ppa.cs_n) gerr("start-up: the 8255 selected");
        if (!dut.crt.cs_n) gerr("start-up: the 8275 selected");
        if (!dut.dma.cs_n) gerr("start-up: the 8257 selected");
        if (!dut.ext_we_n || !dut.ext_rd_n) gerr("start-up: a window strobe low");
        if (!dut.dma.aen && !dut.rom) gerr("start-up: rom low");
    end
    // GLUE-13: no device answers a DMA address; the memory gives RAM (rom low)
    if (dut.dma.aen) begin
        if (dut.dma.a_o < 16'h8000) begin
            if (phase == 0) c_dma_a = c_dma_a + 1;
            if (!dut.ppa.cs_n || !dut.crt.cs_n || !dut.dma.cs_n || !dut.ext_we_n || !dut.ext_rd_n)
                gerr("a device selected by the DMA address");
        end
        if (dut.rom) gerr("rom high while AEN");
        if (!dut.crt.rd_n) c_dma_rd = c_dma_rd + 1;
        if (!dut.crt.wr_n) c_dma_wr = c_dma_wr + 1;
    end
    // the system address and the chips' address inputs (GLUE-1, GLUE-4, GLUE-7, GLUE-10)
    if (dut.bus_a !== x_bus) gerr("bus_a: not the 8257 address while AEN, else the CPU address");
    if (dut.aen !== dut.dma.aen) gerr("aen: not the 8257 AEN");
    if (dut.cpu_a !== dut.cpu.pin_a) gerr("cpu_a: not the CPU address");
    if (dut.ppa.a !== x_bus[1:0]) gerr("8255 A1 A0: not A1 A0");
    if (dut.crt.a0 !== x_bus[0]) gerr("8275 A0: not A0");
    if (dut.dma.a_i !== x_bus[3:0]) gerr("8257 A3-A0: not A3-A0");
    // the decoder (GLUE-1): D11 on the system address, enabled by the start-up flip-flop
    if (dut.ppa.cs_n !== !x_ppa) gerr("8255 CS: not 8000-9FFF");
    if (dut.crt.cs_n !== !x_crt) gerr("8275 CS: not C000-DFFF");
    if (dut.dma.cs_n !== !x_top) gerr("8257 CS: not E000-FFFF");
    if (dut.rom !== (!dut.dma.aen && (dut.startup || x_bus[15:13] == 3'b111)))
        gerr("rom: not E000-FFFF (every address in start-up) without AEN");
    // ЧТЕНИЕ = DBIN XOR MEMW (GLUE-3), to the memory, the 8255 RD and the 8275 RD
    if (dut.crt.rd_n !== x_rd_n) gerr("8275 RD: not DBIN XOR MEMW");
    if (dut.mem_rd !== !dut.crt.rd_n) gerr("mem_rd: not READ");
    if (dut.ppa.rd_n !== dut.crt.rd_n) gerr("8255 RD: not READ");
    // the write strobes: the 8275 WR = CPU WR AND the 8257 IOR (GLUE-6); the 8255 WR, the 8257 IOW and the
    // memory: the CPU WR (GLUE-4, CPU-7); the 8257 IOR input pulled up (GLUE-4)
    if (dut.crt.wr_n !== (dut.cpu.pin_wr_n & dut.dma.ior_n_o)) gerr("8275 WR: not CPU WR AND 8257 IOR");
    if (dut.ppa.wr_n !== dut.cpu.pin_wr_n) gerr("8255 WR: not CPU WR");
    if (dut.dma.iow_n_i !== dut.cpu.pin_wr_n) gerr("8257 IOW: not CPU WR");
    if (dut.cpu_wr_n !== dut.cpu.pin_wr_n) gerr("cpu_wr_n: not CPU WR");
    if (dut.dma.ior_n_i !== 1'b1) gerr("8257 IOR input: not inactive");
    // the window A000-BFFF (Y5)
    if (dut.ext_we_n !== !(x_ext && !dut.cpu.pin_wr_n)) gerr("ext_we_n: not CPU WR in A000-BFFF");
    if (dut.ext_rd_n !== !(x_ext && !x_rd_n)) gerr("ext_rd_n: not READ in A000-BFFF");
    // the data paths: the 8275 takes the memory while AEN (GLUE-13), else the CPU's data
    if (dut.crt.d_i !== (dut.dma.aen ? mem.mem_di : dut.cpu.pin_dout))
        gerr(dut.dma.aen ? "8275 D: not the memory while AEN" : "8275 D: not the CPU data");
    if (dut.ppa.d_i !== dut.cpu.pin_dout) gerr("8255 D: not the CPU data");
    if (dut.dma.d_i !== dut.cpu.pin_dout) gerr("8257 D: not the CPU data");
    if (dut.cpu.pin_dbin) begin                                           // what the CPU reads
        if (dut.startup) x_din = mem.mem_di;
        else case (dut.cpu.pin_a[15:13])
            3'b100:  x_din = dut.ppa.d_o;
            3'b101:  x_din = ext_di;
            3'b110:  x_din = dut.crt.d_o;
            default: x_din = mem.mem_di;
        endcase
        if (dut.cpu.pin_din !== x_din) gerr("CPU D input: not the device at its address");
    end
    // the tied and shared pins (GLUE-5, GLUE-7, GLUE-8, GLUE-9, CPU-3, the 8224)
    if (dut.cpu.pin_hold !== dut.dma.hrq) gerr("8080 HOLD: not 8257 HRQ");
    if (dut.dma.hlda !== dut.cpu.pin_hlda) gerr("8257 HLDA: not 8080 HLDA");
    if (dut.dma.drq !== {1'b0, dut.crt.drq, 2'b00}) gerr("8257 DRQ: not DRQ2 = 8275 DRQ, DRQ0 1 3 low");
    if (dut.crt.dack_n !== dut.dma.dack_n[2]) gerr("8275 DACK: not 8257 DACK2");
    if (dut.cpu.pin_int !== 1'b0) gerr("8080 INT: not low");
    if (dut.crt.lpen !== 1'b0) gerr("8275 LPEN: not low");
    if (dut.clocks.rdyin !== 1'b1) gerr("8224 RDYIN: not high");
    if (dut.cpu.pin_ready !== dut.clocks.ready || dut.dma.ready !== dut.clocks.ready) gerr("READY: not the 8224 READY");
    if (dut.cpu.pin_reset !== dut.clocks.reset || dut.dma.reset !== dut.clocks.reset || dut.ppa.reset !== dut.clocks.reset)
        gerr("RESET: not the 8224 RESET");
    if (dut.clocks.resin_n !== !reset) gerr("8224 RESIN: not the board reset");
    if (dut.clocks.sync !== dut.cpu.pin_sync) gerr("8224 SYNC: not 8080 SYNC");
    if (dut.cpu.pin_f1 !== dut.clocks.f1 || dut.cpu.pin_f2 !== dut.clocks.f2) gerr("8080 F1 F2: not the 8224 phases");
    if (dut.dma.th_up !== dut.clocks.f2 || dut.dma.th_dn !== dut.clocks.f2_fall) gerr("8257 CLK: not 8224 F2");
    if (dut.crt.cclk !== dut.clocks.cclk_fall) gerr("8275 CCLK: not the IE4 QD");
    // the keyboard PPI and the outputs
    if (dut.ppa.pb_i !== kbd_cols || dut.ppa.pc_i[7:4] !== {kbd_shift, tape_in}) gerr("8255 PB PC inputs: not the keyboard");
    if (dut.ppa_pa !== (dut.ppa.pa_oe ? dut.ppa.pa_o : 8'hFF)) gerr("ppa_pa: not 8255 PA");
    if (dut.pc0 !== (dut.ppa.pc_oe[0] ? dut.ppa.pc_o[0] : 1'b1)) gerr("pc0: not 8255 PC0");
    if (dut.inte !== dut.cpu.pin_inte) gerr("inte: not 8080 INTE");
    if (dut.hrtc !== dut.crt.hrtc || dut.vrtc !== dut.crt.vrtc) gerr("hrtc vrtc: not the 8275 pins");
    if (dut.video.dot_ce !== dut.clocks.dot_ce || dut.video.cnt12 !== dut.clocks.cnt12 || dut.pix_ce !== dut.clocks.dot_ce)
        gerr("video clocks: not the IE4");
    if ({dut.video.cc, dut.video.lc, dut.video.vsp, dut.video.lten, dut.video.rvv}
        !== {dut.crt.cc, dut.crt.lc, dut.crt.vsp, dut.crt.lten, dut.crt.rvv}) gerr("video inputs: not the 8275 pins");
    if (dut.font_addr !== dut.video.font_addr || dut.video.font_data !== font_data || dut.pix !== dut.video.pix)
        gerr("font, pix: not the video path");
    // the counts
    if (phase < 8 && phase != 5) begin
        c_n[phase] = c_n[phase] + 1;
        if (!dut.ppa.cs_n) c_ppa[phase] = c_ppa[phase] + 1;
        if (!dut.crt.cs_n) c_crt[phase] = c_crt[phase] + 1;
        if (!dut.dma.cs_n) c_dma[phase] = c_dma[phase] + 1;
        if (!dut.ext_we_n) c_wer[phase] = c_wer[phase] + 1;
        if (!dut.ext_rd_n) c_rdr[phase] = c_rdr[phase] + 1;
        if (dut.rom) c_rom[phase] = c_rom[phase] + 1;
        if (dut.cpu.pin_dbin) begin
            if (!dut.startup && dut.cpu.pin_a[15:13] == 3'b100) c_din_ppa[phase] = c_din_ppa[phase] + 1;
            else if (!dut.startup && dut.cpu.pin_a[15:13] == 3'b101) c_din_ext[phase] = c_din_ext[phase] + 1;
            else if (!dut.startup && dut.cpu.pin_a[15:13] == 3'b110) c_din_crt[phase] = c_din_crt[phase] + 1;
            else c_din_mem[phase] = c_din_mem[phase] + 1;
        end
        if (phase == 0 && !dut.crt.cs_n && !dut.cpu.pin_wr_n) c_cpu_crt_wr = c_cpu_crt_wr + 1;
        if (phase == 0 && !dut.crt.cs_n && dut.cpu.pin_dbin) c_cpu_crt_rd = c_cpu_crt_rd + 1;
        if (phase == 0 && dut.startup && !dut.clocks.reset && dut.rom) c_rom_high = c_rom_high + 1;
    end
end

//---------------- frames, the arming point, the keyboard loop
integer frame = -1, fa = -1, ve_at = -1, a4_at = -1, a4_vr = 0, last_vr = 0, f0_at = 0, fe63 = 0, fe63_frame = -2;
reg done = 1'b0, timeout = 1'b0, ve_seen = 1'b0, a4_seen = 1'b0, arm = 1'b0, dma_err = 1'b0;
reg ve_q = 1'b0, vrtc_q = 1'b0, st_m1 = 1'b0, dbin_q = 1'b0;
always @(negedge clk)
    if (!done) begin
        if (dut.crt.vrtc && !vrtc_q) begin                               // a VRTC rise
            if (ve_seen) begin
                frame = frame + 1;
                last_vr = n16;
                if (frame == 0) begin
                    f0_at = n16;
                    $display("INFO: machine16: VE rose at ce16 %0d; frame 0 starts at ce16 %0d", ve_at, n16);
                end
            end
            if (a4_seen && !arm) begin
                a4_vr = a4_vr + 1;
                if (a4_vr == 2) begin
                    arm = 1'b1; fa = frame;
                    $display("INFO: machine16: 8257 mode A4h at ce16 %0d; armed at the VRTC rise of frame %0d (ce16 %0d)",
                             a4_at, fa, n16);
                end
            end
            if (frame == 4 && !arm && !dma_err) begin
                $display("ERROR: dma never enabled (no 8257 mode A4h two VRTC rises before frame 4)"); fail;
                dma_err = 1'b1;
            end
            if (frame == FRAMES) done = 1'b1;
        end
        vrtc_q = dut.crt.vrtc;
        if (!ve_seen && dut.crt.ve && !ve_q) begin ve_seen = 1'b1; ve_at = n16; last_vr = n16; end
        ve_q = dut.crt.ve;
        if (!a4_seen && dut.dma.mode == 8'hA4) begin a4_seen = 1'b1; a4_at = n16; end
        if (!ve_seen && n16 >= VE_LIMIT) begin
            $display("ERROR: display never enabled (the 8275 VE did not rise in %0d ce16)", VE_LIMIT); fail;
            done = 1'b1; timeout = 1'b1;
        end
        if (ve_seen && n16 - last_vr > 2 * FRAME16) begin
            $display("ERROR: frame %0d never started (no VRTC rise in %0d ce16)", frame + 1, 2 * FRAME16); fail;
            done = 1'b1; timeout = 1'b1;
        end
        // an instruction fetch: the status M1 (D5) latched during SYNC, then DBIN at the address
        if (dut.cpu.pin_sync) st_m1 = dut.cpu.pin_dout[5];
        if (dut.cpu.pin_dbin && !dbin_q && st_m1 && dut.cpu.pin_a == 16'hFE63) begin
            fe63 = fe63 + 1;
            if (fe63 == 1) begin
                fe63_frame = frame;
                $display("INFO: machine16: first fetch at FE63 (the keyboard loop) at ce16 %0d, frame %0d", n16, frame);
            end
        end
        dbin_q = dut.cpu.pin_dbin;
        bus_timing;                     // the bus timing checks of this clk (they see frame, arm, done)
    end

//---------------- bus timing (Task 13; spec 9.1-3): the numbers of the Global Constraints and of the record
// (docs radio86rk-ics.md: the 8257 per transfer, the RK86 case of the 8275 DRQ, the HOLD overhead).
// bus_timing runs in the frame block at every clk while the frames run (never in the late phases); the
// raster and DMA checks run from the arming VRTC rise on, phi from frame 0, the handshake from the end
// of RESET. Time stamps in ce16 (n16): a pin that changes at a ce16 clk is stamped with n16 at the
// negedge after it; an enable (f1, the 8257 theta-down, the 8275 IR set event) is seen at the negedge
// before the clk it acts on and stamped n16 + 1. S1 of a transfer = its ADSTB rise - 4 (ADSTB rises at
// theta-up of S1, [C78] 12-109 TSTL). Rows: the TB counts lines from the VRTC rise, 10 per row; row 0 of
// the TB is the retrace row (it fills display row 0), TB row k fills display row k, TB row 30 (display
// row 29) has no fill. A burst ends at a DRQ-low gap longer than 48 ce16; a DRQ rise after a shorter gap
// continues the burst only when it comes with the WR rise (within 2 clk, the 8275 tWQ re-raise; the
// unit TB's rule), else it is a burst space that is too short.
localparam integer PHI16 = 9;                       // a T-state, f1 to f1
localparam integer LINE16 = 1032, HRTC16 = 96;      // 86 and 8 CCLK
localparam integer LINES = 310, ROW_LINES = 10, ROWS = 31, VRTC16 = 10320;
localparam integer XF_ROW = 78, XF_FRAME = 2340;    // transfers per row fill and per frame
localparam integer BURST = 8;                       // 27h: BB = 11
localparam integer BURSTS = (XF_ROW + BURST - 1) / BURST;            // 10 per row
localparam integer LAST_BURST = XF_ROW - (BURSTS - 1) * BURST;       // the last one 6
localparam integer GAP16 = 48, SPACE_MIN = 73, SPACE_MAX = 84;
localparam integer AEN16 = 40;                      // AEN high per transfer
localparam integer S1_ADSTB = 4, S1_DRQ = 27, S1_HRQ = 31, S1_SI = 45;
localparam integer PER_R = 72, PER_W = 81, PER_MISS_MAX = 126;       // 8 / 9 Phi; 11-14 Phi after a missed SI sample
localparam integer IR16 = 299376;                   // IR set after a VRTC fall
integer clkn = 0;
reg t_on = 1'b0, boot_du = 1'b0;
reg q_hrtc = 1'b0, q_vrtc = 1'b0, q_drq = 1'b0, q_ior = 1'b1, q_dack2 = 1'b1, q_crtwr = 1'b1, q_crtdack = 1'b1;
reg q_aen = 1'b0, q_adstb = 1'b0, q_hrq = 1'b0, q_hlda = 1'b0, q_du = 1'b0, q_ublank = 1'b0, q_thu = 1'b0;
integer f1_at = -1, f1_first = -1, n_phi = 0;
integer hr_at = -1, vr_at = -1, vf_at = -1, fr_lines = 0, row_line = 0, r_idx = 0;
integer n_line = 0, n_hw = 0, n_frames = 0, n_vw = 0, n_rows = 0;
integer fr_xfer = 0, fr_hrq = 0, fr_aen = 0, fr_s4 = 0, fr_h4 = 0, fr_ir = 0, vr_xfer = 0;
integer row_xfer = 0, row_bursts = 0, b_len = 0, last_wr_at = -1, wr_clk = -1000, drq_fall_at = -1;
reg b_open = 1'b0, b_long = 1'b0, s1_first = 1'b0, si_miss = 1'b0, s4_pend = 1'b0, s4_drq = 1'b0;
integer s1_at = -1, aen_at = -1;
integer n_xfer = 0, n_bursts = 0, n_space = 0, n_per = 0, n_irt = 0, n_hlda = 0, n_aenup = 0, n_s4 = 0, n_h4 = 0;
integer margin_min = 0, margin_row = -1;
integer hist [0:PER_MISS_MAX];
integer hist_over = 0;
integer e_kind [0:15];      // errors per check: phi, hrtc, frame, vrtc, transfers, aen per transfer, hold periods,
                            // drq at s4, dma period, burst length, burst space, first row, irq, underrun,
                            // hold in a write, aen during dbin
initial begin
    for (k0 = 0; k0 <= PER_MISS_MAX; k0 = k0 + 1) hist[k0] = 0;
    for (k0 = 0; k0 < 16; k0 = k0 + 1) e_kind[k0] = 0;
end
task tfail(input integer kind); begin e_kind[kind] = e_kind[kind] + 1; fail; end endtask
function integer exp_len(input integer b);          // the transfers of burst b of a row fill
    exp_len = b < BURSTS - 1 ? BURST : b == BURSTS - 1 ? LAST_BURST : 0;
endfunction

task b_new; begin row_bursts = row_bursts + 1; b_open = 1'b1; b_len = 0; b_long = 1'b0; s1_first = 1'b1; end endtask
task b_close;
    integer b;
    begin
        if (b_open) begin
            b = row_bursts - 1;
            n_bursts = n_bursts + 1;
            if (b_len != exp_len(b) && !b_long) begin
                $display("ERROR: burst length: frame %0d row %0d fill: burst %0d has %0d transfers, expected %0d (ce16 %0d)",
                         frame, r_idx, b, b_len, exp_len(b), n16); tfail(9);
            end
            b_open = 1'b0;
        end
    end
endtask
// the end of TB row r_idx (the HRTC rise that starts the next row): its fill, its bursts, the margin
task row_end;
    integer ex, d;
    begin
        b_close;
        ex = r_idx < ROWS - 1 ? XF_ROW : 0;
        if (row_xfer != ex) begin
            $display("ERROR: transfers: frame %0d row %0d: %0d transfers (IOR rises with DACK2), expected %0d (ce16 %0d)",
                     frame, r_idx, row_xfer, ex, n16); tfail(4);
        end
        ex = r_idx < ROWS - 1 ? BURSTS : 0;
        if (row_bursts != ex) begin
            $display("ERROR: burst length: frame %0d row %0d fill: %0d bursts, expected %0d (ce16 %0d)",
                     frame, r_idx, row_bursts, ex, n16); tfail(9);
        end
        if (row_xfer > 0) begin                 // from the last WR rise of the fill to the start of the row it fills
            d = n16 - last_wr_at;
            if (margin_row < 0 || d < margin_min) begin margin_min = d; margin_row = r_idx; end
        end
        n_rows = n_rows + 1;
        row_xfer = 0; row_bursts = 0; b_open = 1'b0; b_len = 0; b_long = 1'b0;
    end
endtask
// the end of a frame (a VRTC rise after the arming one)
task frame_end; begin
    n_frames = n_frames + 1;
    if (fr_lines != LINES || n16 - vr_at != FRAME16) begin
        $display("ERROR: frame: frame %0d: %0d HRTC rises and %0d ce16 between VRTC rises, expected %0d and %0d",
                 frame - 1, fr_lines, n16 - vr_at, LINES, FRAME16); tfail(2);
    end
    if (fr_xfer != XF_FRAME) begin
        $display("ERROR: transfers: frame %0d: %0d transfers, expected %0d", frame - 1, fr_xfer, XF_FRAME); tfail(4); end
    if (fr_hrq != XF_FRAME || fr_h4 != XF_FRAME) begin
        $display("ERROR: hold periods: frame %0d: %0d HRQ rises, %0d transfers with theta-up of S4 checked, expected %0d",
                 frame - 1, fr_hrq, fr_h4, XF_FRAME); tfail(6); end
    if (fr_aen != XF_FRAME) begin
        $display("ERROR: aen per transfer: frame %0d: %0d AEN-high runs, expected %0d", frame - 1, fr_aen, XF_FRAME); tfail(5); end
    if (fr_s4 != XF_FRAME) begin
        $display("ERROR: drq at s4: frame %0d: %0d DRQ samples at S1 + %0d, expected %0d", frame - 1, fr_s4, S1_DRQ, XF_FRAME); tfail(7); end
    if (fr_ir != 1) begin
        $display("ERROR: irq: frame %0d: %0d IR set events, expected 1", frame - 1, fr_ir); tfail(12); end
    fr_lines = 0; fr_xfer = 0; fr_hrq = 0; fr_aen = 0; fr_s4 = 0; fr_h4 = 0; fr_ir = 0; vr_xfer = 0;
end endtask

task bus_timing;
    reg hr_up, hr_dn, vr_up, vr_dn;
    integer d;
    begin
        clkn = clkn + 1;
        //---- phi: a T-state f1 to f1, from frame 0 on
        if (frame >= 0 && dut.cpu.pin_f1) begin
            if (f1_at >= 0) begin
                n_phi = n_phi + 1;
                if (n16 + 1 - f1_at != PHI16) begin
                    $display("ERROR: phi: f1 to f1 %0d ce16, expected %0d (ce16 %0d)", n16 + 1 - f1_at, PHI16, n16 + 1); tfail(0);
                end
            end else f1_first = n16 + 1;
            f1_at = n16 + 1;
        end
        //---- the handshake, every clk after RESET
        if (!dut.clocks.reset) begin
            if (dut.cpu.pin_hlda && !q_hlda) begin
                n_hlda = n_hlda + 1;
                if (!dut.cpu_wr_n) begin
                    $display("ERROR: hold in a write: HLDA rose while the CPU WR is low (ce16 %0d, cpu_a %h)", n16, dut.cpu.pin_a);
                    tfail(14);
                end
            end
            if (dut.dma.aen && !q_aen) begin
                n_aenup = n_aenup + 1;
                if (dut.cpu.pin_dbin) begin
                    $display("ERROR: aen during dbin: AEN rose while the CPU DBIN is high (ce16 %0d, cpu_a %h)", n16, dut.cpu.pin_a);
                    tfail(15);
                end
            end
        end
        if (dut.dma.aen && !q_aen) aen_at = n16;
        //---- the raster
        hr_up = dut.crt.hrtc && !q_hrtc; hr_dn = !dut.crt.hrtc && q_hrtc;
        vr_up = dut.crt.vrtc && !q_vrtc; vr_dn = !dut.crt.vrtc && q_vrtc;
        if (arm && !t_on && vr_up) begin                                     // the arming VRTC rise: TB row 0 starts
            t_on = 1'b1;
            $display("INFO: machine16: underrun at boot %0d (DU before the 8257 was enabled: data sheet behaviour, spec 8)",
                     boot_du);
            if (!hr_up) begin $display("ERROR: vrtc: VRTC rose without an HRTC rise (ce16 %0d)", n16); tfail(3); end
            hr_at = n16; vr_at = n16;
        end else if (t_on) begin
            if (hr_dn) begin
                n_hw = n_hw + 1;
                if (n16 - hr_at != HRTC16) begin
                    $display("ERROR: hrtc: HRTC high %0d ce16, expected %0d (frame %0d row %0d line %0d, ce16 %0d)",
                             n16 - hr_at, HRTC16, frame, r_idx, row_line, n16); tfail(1);
                end
            end
            if (hr_up) begin
                n_line = n_line + 1;
                if (n16 - hr_at != LINE16) begin
                    $display("ERROR: hrtc: line %0d ce16 (HRTC rise to rise), expected %0d (frame %0d row %0d line %0d, ce16 %0d)",
                             n16 - hr_at, LINE16, frame, r_idx, row_line, n16); tfail(1);
                end
                hr_at = n16; fr_lines = fr_lines + 1; row_line = row_line + 1;
                if (row_line == ROW_LINES) begin row_end; row_line = 0; r_idx = r_idx + 1; end
            end
            if (vr_up) begin
                if (!hr_up) begin $display("ERROR: vrtc: VRTC rose without an HRTC rise (ce16 %0d)", n16); tfail(3); end
                frame_end;
                vr_at = n16; row_line = 0; r_idx = 0;
            end
            if (vr_dn) begin
                n_vw = n_vw + 1;
                if (n16 - vr_at != VRTC16) begin
                    $display("ERROR: vrtc: VRTC high %0d ce16, expected %0d (frame %0d)", n16 - vr_at, VRTC16, frame); tfail(3); end
                if (vr_xfer != XF_ROW) begin
                    $display("ERROR: first row: frame %0d: %0d transfers between VRTC rise and fall, expected %0d (the row 0 fill)",
                             frame, vr_xfer, XF_ROW); tfail(11); end
                vf_at = n16;
            end
        end
        //---- underrun (spec 8): before the arming point only recorded; from it the blank never starts
        if (!t_on) begin
            if (dut.crt.du && !q_du) boot_du = 1'b1;
        end else if (dut.crt.ublank && !q_ublank) begin
            $display("ERROR: underrun: the 8275 blanked for an underrun (ublank rose) at ce16 %0d, frame %0d row %0d: stop the work and report (spec 8)",
                     n16, frame, r_idx); tfail(13);
        end
        //---- DMA, from the arming point
        if (t_on) begin
            // the theta-up after S4 (S1 + 31): HRQ low (each character its own HOLD period: the 8275 DRQ is low
            // at S4, so HRQ falls); then the DRQ sampled at S1 + 27
            if (q_thu && s1_at >= 0 && n16 == s1_at + S1_HRQ) begin
                fr_h4 = fr_h4 + 1; n_h4 = n_h4 + 1;
                if (dut.dma.hrq) begin
                    $display("ERROR: hold periods: HRQ high after theta-up of S4 (S1 + %0d): the HOLD period goes on after the character (frame %0d row %0d, ce16 %0d)",
                             S1_HRQ, frame, r_idx, n16); tfail(6);
                end
                if (s4_pend) begin
                    s4_pend = 1'b0;
                    if (s4_drq) begin
                        $display("ERROR: drq at s4: the 8275 DRQ high at the theta-down that starts S4 (S1 + %0d, ce16 %0d), expected low (frame %0d row %0d)",
                                 S1_DRQ, s1_at + S1_DRQ, frame, r_idx); tfail(7);
                    end
                end
            end
            if (dut.dma.th_dn && s1_at >= 0) begin
                if (n16 + 1 == s1_at + S1_DRQ) begin fr_s4 = fr_s4 + 1; n_s4 = n_s4 + 1; s4_pend = 1'b1; s4_drq = dut.crt.drq; end
                if (n16 + 1 == s1_at + S1_SI) si_miss = !dut.crt.drq;
            end
            // S1 (ADSTB rise - 4): the period within a burst
            if (dut.dma.adstb && !q_adstb) begin
                if (s4_pend) begin                  // no theta-up at S1 + 31 came
                    s4_pend = 1'b0;
                    if (s4_drq) begin
                        $display("ERROR: drq at s4: the 8275 DRQ high at the theta-down that starts S4 (S1 + %0d, ce16 %0d), expected low (frame %0d row %0d)",
                                 S1_DRQ, s1_at + S1_DRQ, frame, r_idx); tfail(7);
                    end
                end
                if (s1_first) s1_first = 1'b0;
                else if (s1_at >= 0) begin
                    d = n16 - S1_ADSTB - s1_at;
                    n_per = n_per + 1;
                    if (d >= 0 && d <= PER_MISS_MAX) hist[d] = hist[d] + 1; else hist_over = hist_over + 1;
                    if (d < PER_R || (!si_miss && d != PER_R && d != PER_W) || d > PER_MISS_MAX) begin
                        $display("ERROR: dma period: S1 to S1 %0d ce16 within burst %0d of the frame %0d row %0d fill (DRQ %0s at the SI sample), expected %0d or %0d (%0d..%0d after a missed SI sample) (ce16 %0d)",
                                 d, row_bursts - 1, frame, r_idx, si_miss ? "low" : "high", PER_R, PER_W, PER_R, PER_MISS_MAX, n16);
                        tfail(8);
                    end
                end
                s1_at = n16 - S1_ADSTB; si_miss = 1'b0;
            end
            // DRQ: the bursts and the burst space
            if (!dut.crt.drq && q_drq) drq_fall_at = n16;
            if (dut.crt.drq && !q_drq) begin
                if (!b_open) b_new;                                          // the first burst of the row fill
                else if (n16 - drq_fall_at > GAP16) begin                    // a new burst
                    b_close;
                    n_space = n_space + 1;
                    d = n16 - last_wr_at;
                    if (d < SPACE_MIN || d > SPACE_MAX) begin
                        $display("ERROR: burst space: frame %0d row %0d fill: DRQ %0d ce16 after the last WR rise of burst %0d, expected %0d..%0d (ce16 %0d)",
                                 frame, r_idx, d, row_bursts - 1, SPACE_MIN, SPACE_MAX, n16); tfail(10);
                    end
                    b_new;
                end else begin                                               // the burst goes on
                    if (clkn - wr_clk > 2) begin
                        $display("ERROR: burst space: frame %0d row %0d fill: DRQ back %0d ce16 after the WR rise of transfer %0d of burst %0d, expected with the WR rise (the burst goes on) or %0d..%0d later (a burst space) (ce16 %0d)",
                                 frame, r_idx, n16 - last_wr_at, b_len, row_bursts - 1, SPACE_MIN, SPACE_MAX, n16); tfail(10);
                    end
                    if (b_len >= exp_len(row_bursts - 1) && !b_long) begin
                        b_long = 1'b1;
                        $display("ERROR: burst length: frame %0d row %0d fill: DRQ again after transfer %0d of burst %0d, expected a burst of %0d (ce16 %0d)",
                                 frame, r_idx, b_len, row_bursts - 1, exp_len(row_bursts - 1), n16); tfail(9);
                    end
                end
            end
            // the transfers: IOR rises with DACK2 low the clk before; the 8275 WR rise of a DMA write
            if (dut.crt.wr_n && !q_crtwr && !q_crtdack) begin last_wr_at = n16; wr_clk = clkn; end
            if (dut.dma.ior_n_o && !q_ior && !q_dack2) begin
                n_xfer = n_xfer + 1; fr_xfer = fr_xfer + 1; row_xfer = row_xfer + 1;
                if (dut.crt.vrtc) vr_xfer = vr_xfer + 1;
                if (!b_open) b_new;
                b_len = b_len + 1;
            end
            // AEN per transfer, the HOLD periods
            if (!dut.dma.aen && q_aen && aen_at >= 0) begin
                fr_aen = fr_aen + 1;
                if (n16 - aen_at != AEN16) begin
                    $display("ERROR: aen per transfer: AEN high %0d ce16, expected %0d (frame %0d row %0d, ce16 %0d)",
                             n16 - aen_at, AEN16, frame, r_idx, n16); tfail(5);
                end
            end
            if (dut.dma.hrq && !q_hrq) fr_hrq = fr_hrq + 1;
            // IR: the 8275's set event, once per frame, IR16 after the VRTC fall
            if (dut.crt.ir_set) begin
                fr_ir = fr_ir + 1;
                if (vf_at >= 0) begin
                    n_irt = n_irt + 1;
                    if (n16 + 1 - vf_at != IR16) begin
                        $display("ERROR: irq: IR set %0d ce16 after the VRTC fall, expected %0d (frame %0d, ce16 %0d)",
                                 n16 + 1 - vf_at, IR16, frame, n16 + 1); tfail(12);
                    end
                end
            end
        end
        q_hrtc = dut.crt.hrtc; q_vrtc = dut.crt.vrtc; q_drq = dut.crt.drq; q_ior = dut.dma.ior_n_o; q_dack2 = dut.dma.dack_n[2];
        q_crtwr = dut.crt.wr_n; q_crtdack = dut.crt.dack_n; q_aen = dut.dma.aen; q_adstb = dut.dma.adstb; q_hrq = dut.dma.hrq;
        q_hlda = dut.cpu.pin_hlda; q_du = dut.crt.du; q_ublank = dut.crt.ublank; q_thu = dut.dma.th_up;
    end
endtask

// after the frames: the histogram, the margin, and every check's sample count (no vacuous pass)
task bus_summary;
    integer k, nf, tot;
    begin
        nf = FRAMES - fa;
        tot = hist_over;
        for (k = 0; k <= PER_MISS_MAX; k = k + 1)
            if (hist[k] != 0) begin $display("INFO: dma period %0d ce16: %0d", k, hist[k]); tot = tot + hist[k]; end
        if (hist_over != 0) $display("INFO: dma period over %0d ce16: %0d", PER_MISS_MAX, hist_over);
        $display("INFO: smallest DMA margin %0d ce16 (row %0d)", margin_min, margin_row);
        $display("INFO: machine16: bus timing: %0d frames, %0d rows, %0d lines, %0d transfers, %0d bursts, %0d burst spaces, %0d periods, %0d S4 samples, %0d IR, %0d T-states, %0d HLDA rises, %0d AEN rises",
                 n_frames, n_rows, n_line, n_xfer, n_bursts, n_space, n_per, n_s4, n_irt, n_phi, n_hlda, n_aenup);
        if (nf < 1 || n_frames != nf) begin
            $display("ERROR: frame: %0d frames checked, expected %0d (armed at frame %0d)", n_frames, nf, fa); tfail(2); end
        if (n_phi == 0 || n16 + 1 - f1_at > PHI16 || f1_first - f0_at > PHI16) begin
            $display("ERROR: phi: %0d T-states from frame 0 (first f1 at ce16 %0d, last %0d, end %0d)", n_phi, f1_first, f1_at, n16); tfail(0); end
        if (n_line != nf * LINES || n_hw != nf * LINES) begin
            $display("ERROR: hrtc: %0d lines, %0d HRTC widths checked, expected %0d", n_line, n_hw, nf * LINES); tfail(1); end
        if (n_vw != nf) begin $display("ERROR: vrtc: %0d VRTC widths checked, expected %0d", n_vw, nf); tfail(3); end
        if (n_rows != nf * ROWS || n_xfer != nf * XF_FRAME) begin
            $display("ERROR: transfers: %0d rows, %0d transfers checked, expected %0d, %0d", n_rows, n_xfer, nf * ROWS, nf * XF_FRAME); tfail(4); end
        if (n_bursts != nf * (ROWS - 1) * BURSTS) begin
            $display("ERROR: burst length: %0d bursts checked, expected %0d", n_bursts, nf * (ROWS - 1) * BURSTS); tfail(9); end
        if (n_space != nf * (ROWS - 1) * (BURSTS - 1)) begin
            $display("ERROR: burst space: %0d burst spaces checked, expected %0d", n_space, nf * (ROWS - 1) * (BURSTS - 1)); tfail(10); end
        if (n_per != nf * (ROWS - 1) * (XF_ROW - BURSTS) || tot != n_per) begin
            $display("ERROR: dma period: %0d periods within bursts (histogram %0d), expected %0d", n_per, tot,
                     nf * (ROWS - 1) * (XF_ROW - BURSTS)); tfail(8); end
        if (n_s4 != nf * XF_FRAME || n_h4 != nf * XF_FRAME) begin
            $display("ERROR: drq at s4: %0d DRQ samples at S1 + %0d, %0d HRQ samples at S1 + %0d, expected %0d", n_s4, S1_DRQ,
                     n_h4, S1_HRQ, nf * XF_FRAME); tfail(7); end
        if (n_irt != nf) begin $display("ERROR: irq: %0d IR times checked, expected %0d", n_irt, nf); tfail(12); end
        if (margin_row < 0) begin $display("ERROR: transfers: no DMA margin measured"); tfail(4); end
        if (n_hlda == 0) begin $display("ERROR: hold in a write: no HLDA rise seen"); tfail(14); end
        if (n_aenup == 0) begin $display("ERROR: aen during dbin: no AEN rise seen"); tfail(15); end
    end
endtask

//---------------- the decoder sweep: every address, reads and writes, start-up off and on
reg [15:0] sw_a = 16'h0000, sw_dma = 16'h0000;
reg sw_su = 1'b0, sw_rd = 1'b1, sw_wr_n = 1'b1;
task sweep(input integer ph, input su, input rd);
    integer k;
    begin
        @(posedge clk);
        phase = 9; sw_su = su; sw_rd = rd; sw_wr_n = rd;
        @(posedge clk);
        for (k = 0; k < 65536; k = k + 1) begin
            sw_a = k; sw_dma = {1'b0, ~k[14:0]}; phase = ph;
            @(posedge clk);
        end
        phase = 9;
    end
endtask
// the end condition of start-up (GLUE-12): one access by the forced CPU pins, held 4 clk, then idle; the
// flip-flop (not forced) must hold start-up or end it
integer c_end = 0;
task su_step(input [15:0] a, input rd, input wr, input exp);
    begin
        sw_a = a; sw_rd = rd; sw_wr_n = !wr;
        repeat (4) @(posedge clk);
        sw_rd = 1'b0; sw_wr_n = 1'b1;
        @(posedge clk);
        @(negedge clk);
        c_end = c_end + 1;
        if (dut.startup !== exp) begin
            $display("ERROR: glue: start-up end condition: after a %0s at %h (A15 = %b): start-up %b, expected %b",
                     rd ? "read" : wr ? "write" : "no access", a, a[15], dut.startup, exp);
            fail;
        end
        @(posedge clk);
    end
endtask
integer t0;
task expect_count(input [8*56-1:0] what, input integer got, input integer exp); begin
    if (got != exp) begin $display("ERROR: sweep: %0s: %0d samples, expected %0d", what, got, exp); fail; end
end endtask
task expect_seen(input [8*56-1:0] what, input integer got); begin
    if (got == 0) begin $display("ERROR: glue: never seen: %0s", what); fail; end
end endtask

initial begin
    wait (done);
    if (!timeout) begin
        bus_summary;                    // the bus timing counts are complete at the last VRTC rise
        // GLUE-9, GLUE-12: RESET re-arms start-up; the boot checks (phase 0) run until it ends again
        @(posedge clk); reset <= 1'b1;
        t0 = n16;
        while (n16 < t0 + 200) @(posedge clk);
        reset <= 1'b0;
        t0 = n16;
        while (su_ends < 2 && n16 < t0 + 5000) @(posedge clk);
        if (su_ends < 2) begin
            $display("ERROR: glue: start-up did not end after the second reset (no read with A15 = 1 in 5000 ce16)"); fail;
        end else $display("INFO: machine16: start-up re-armed by RESET, ended again at ce16 %0d", n16);
        t0 = n16;
        while (n16 < t0 + 2000) @(posedge clk);
        // GLUE-12: the end condition alone; start-up set for one clk by a force on the flip-flop (and on the
        // TB's copy), then released, so the flip-flop itself holds it
        @(posedge clk);
        phase = 9;
        sw_a = 16'h0000; sw_rd = 1'b0; sw_wr_n = 1'b1;
        force dut.dma.aen = 1'b0;
        force dut.dma.memw_n = 1'b1;
        force dut.dma.ior_n_o = 1'b1;
        force dut.cpu.a = sw_a;
        force dut.cpu.dbin_pin = sw_rd;
        force dut.cpu.wr_n = sw_wr_n;
        force dut.startup = 1'b1;
        force su_exp = 1'b1;
        repeat (2) @(posedge clk);
        release dut.startup;
        release su_exp;
        phase = 5;
        su_step(16'h0000, 1'b1, 1'b0, 1'b1);
        su_step(16'h0001, 1'b1, 1'b0, 1'b1);
        su_step(16'h4000, 1'b1, 1'b0, 1'b1);
        su_step(16'h2000, 1'b1, 1'b0, 1'b1);
        su_step(16'h1000, 1'b1, 1'b0, 1'b1);
        su_step(16'h0800, 1'b1, 1'b0, 1'b1);
        su_step(16'h6000, 1'b1, 1'b0, 1'b1);
        su_step(16'h7FFF, 1'b1, 1'b0, 1'b1);
        su_step(16'hFFFF, 1'b0, 1'b0, 1'b1);     // A15 without DBIN
        su_step(16'hFFFF, 1'b0, 1'b1, 1'b1);     // a write with A15 = 1
        su_step(16'h8000, 1'b1, 1'b0, 1'b0);     // a read with A15 = 1 ends it
        expect_count("start-up end condition steps", c_end, 11);
        // the decoder sweep (forces never released)
        phase = 9;
        force dut.startup = sw_su;
        sweep(1, 1'b0, 1'b1);
        sweep(2, 1'b0, 1'b0);
        sweep(3, 1'b1, 1'b1);
        sweep(4, 1'b1, 1'b0);
        // GLUE-13: AEN high with the 8257 address below 8000, the CPU address over 0000-FFFF
        force dut.dma.a_o = sw_dma;
        force dut.dma.aen = 1'b1;
        sweep(6, 1'b0, 1'b1);
        sweep(7, 1'b0, 1'b0);
        expect_count("DMA address: samples, reads", c_n[6], 65536);
        expect_count("DMA address: samples, writes", c_n[7], 65536);
        expect_count("DMA address: CS", c_ppa[6] + c_crt[6] + c_dma[6] + c_ppa[7] + c_crt[7] + c_dma[7], 0);
        expect_count("DMA address: window strobes", c_rdr[6] + c_wer[6] + c_rdr[7] + c_wer[7], 0);
        expect_count("DMA address: rom", c_rom[6] + c_rom[7], 0);
        // GLUE-1: 8 KB each; start-up: none, the monitor at every address
        expect_count("8255 CS, reads", c_ppa[1], 8192);     expect_count("8255 CS, writes", c_ppa[2], 8192);
        expect_count("8275 CS, reads", c_crt[1], 8192);     expect_count("8275 CS, writes", c_crt[2], 8192);
        expect_count("8257 CS, reads", c_dma[1], 8192);     expect_count("8257 CS, writes", c_dma[2], 8192);
        expect_count("ext_rd_n, reads", c_rdr[1], 8192);    expect_count("ext_rd_n, writes", c_rdr[2], 0);
        expect_count("ext_we_n, reads", c_wer[1], 0);       expect_count("ext_we_n, writes", c_wer[2], 8192);
        expect_count("rom, reads", c_rom[1], 8192);         expect_count("rom, writes", c_rom[2], 8192);
        expect_count("CPU D from memory", c_din_mem[1], 40960);
        expect_count("CPU D from the 8255", c_din_ppa[1], 8192);
        expect_count("CPU D from the window", c_din_ext[1], 8192);
        expect_count("CPU D from the 8275", c_din_crt[1], 8192);
        expect_count("start-up: CS, reads", c_ppa[3] + c_crt[3] + c_dma[3], 0);
        expect_count("start-up: CS, writes", c_ppa[4] + c_crt[4] + c_dma[4], 0);
        expect_count("start-up: window strobes", c_rdr[3] + c_wer[3] + c_rdr[4] + c_wer[4], 0);
        expect_count("start-up: rom, reads", c_rom[3], 65536);
        expect_count("start-up: rom, writes", c_rom[4], 65536);
        expect_count("start-up: CPU D from memory", c_din_mem[3], 65536);
        // the boot itself
        expect_seen("start-up after the reset", c_su);
        expect_seen("start-up reads below 8000 (the monitor at 0000)", c_su_low);
        expect_seen("rom high in start-up", c_rom_high);
        expect_count("start-up ends (power-up, the RESET pulse)", su_ends, 2);
        expect_seen("the 8255 selected", c_ppa[0]);
        expect_seen("the 8275 selected", c_crt[0]);
        expect_seen("the 8257 selected", c_dma[0]);
        expect_seen("CPU writes to the 8275", c_cpu_crt_wr);
        expect_seen("CPU reads of the 8275", c_cpu_crt_rd);
        expect_seen("CPU reads of the 8255", c_din_ppa[0]);
        expect_seen("CPU reads of memory", c_din_mem[0]);
        expect_seen("CPU writes to the window (the monitor's A002)", c_wer[0]);
        expect_seen("DMA addresses with AEN", c_dma_a);
        expect_seen("DMA READ (MEMW) with AEN", c_dma_rd);
        expect_seen("DMA 8275 WR (IOR) with AEN", c_dma_wr);
        $display("INFO: machine16: boot samples: start-up %0d (reads %0d), 8255 CS %0d, 8275 CS %0d, 8257 CS %0d, window %0d / %0d, AEN %0d",
                 c_su, c_su_rd, c_ppa[0], c_crt[0], c_dma[0], c_rdr[0], c_wer[0], c_dma_a);
    end
    if (fe63 == 0) begin $display("ERROR: no keyboard loop (no fetch at FE63)"); fail; end
    if (errors == 0) $display("PASS: machine16 (%0d frames)", frame);
    $finish;
end
endmodule
`default_nettype wire
