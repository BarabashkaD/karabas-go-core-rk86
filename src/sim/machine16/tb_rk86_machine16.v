// rk86_machine16, the Radio-86RK machine with the original 16 MHz timing. Part 1 (Task 12): the monitor
// boots to its keyboard loop (FE63) and the board glue of the Радио 1986 board (Task 2 GLUE-n) holds at
// every clk; Tasks 13 and 14 add to it.
// The glue checks probe the ports of the chip instances (dut.cpu, dut.dma, dut.crt, dut.ppa, dut.clocks,
// dut.video) and the TB memory, never the machine's internal nets: each expectation is made from the
// ports of the driving instances and compared with the port of the driven one (GLUE-1 decoder, GLUE-3
// ЧТЕНИЕ, GLUE-4 / 5 the 8257, GLUE-6 the 8275 WR gate, GLUE-7 / 8 the tied pins, GLUE-9 RESET,
// GLUE-11 / 12 start-up, GLUE-13 the bus during HOLD).
// Frames (spec 7): counted as VRTC rises from the first VRTC rise after the 8275's VE rises (frame 0
// starts there); the run ends FRAMES frames after the start of frame 0. The arming point (spec 8): the
// second VRTC rise after the first clk with the 8257 mode A4h (arm, fa).
// After the frames, a decoder sweep forces the CPU address over 0000-FFFF (reads, then writes; start-up
// off, then on; AEN and the 8257 strobes forced inactive) and counts the selects of every range, so the
// decoder edges (7FFF / 8000, 9FFF / A000, BFFF / C000, DFFF / E000) are checked whatever the boot does.
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
integer phase = 0;                                         // 0 the boot; 1-4 the decoder sweep; 9 between
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
integer c_ppa [0:4], c_crt [0:4], c_dma [0:4], c_wer [0:4], c_rdr [0:4], c_rom [0:4];
integer c_din_mem [0:4], c_din_ppa [0:4], c_din_ext [0:4], c_din_crt [0:4];
integer c_su = 0, c_su_rd = 0, c_su_low = 0, su_ends = 0, c_dma_a = 0, c_dma_rd = 0, c_dma_wr = 0;
integer c_cpu_crt_wr = 0, c_cpu_crt_rd = 0, c_rom_high = 0, k0;
initial for (k0 = 0; k0 < 5; k0 = k0 + 1) begin
    c_ppa[k0] = 0; c_crt[k0] = 0; c_dma[k0] = 0; c_wer[k0] = 0; c_rdr[k0] = 0; c_rom[k0] = 0;
    c_din_mem[k0] = 0; c_din_ppa[k0] = 0; c_din_ext[k0] = 0; c_din_crt[k0] = 0;
end
reg su_q = 1'b1;
reg [7:0] x_din;

//---------------- the glue, at every clk (sampled at the falling edge, between the enables)
always @(negedge clk) begin
    // start-up (GLUE-11, GLUE-12; the controller's ruling): the monitor answers every address, the
    // decoder is off
    if (phase == 0) begin
        if (dut.startup !== su_exp)
            gerr(su_exp ? "start-up ended before the first read with A15 = 1"
                        : "start-up not ended by the first read with A15 = 1");
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
            if (phase < 5) c_dma_a = c_dma_a + 1;
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
    if (phase < 5) begin
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
    end

//---------------- the decoder sweep: every address, reads and writes, start-up off and on
reg [15:0] sw_a = 16'h0000;
reg sw_su = 1'b0, sw_rd = 1'b1;
task sweep(input integer ph, input su, input rd);
    integer k;
    begin
        @(posedge clk);
        phase = 9; sw_su = su; sw_rd = rd;
        @(posedge clk);
        for (k = 0; k < 65536; k = k + 1) begin
            sw_a = k; phase = ph;
            @(posedge clk);
        end
        phase = 9;
    end
endtask
task expect_count(input [8*40-1:0] what, input integer got, input integer exp); begin
    if (got != exp) begin $display("ERROR: sweep: %0s: %0d samples, expected %0d", what, got, exp); fail; end
end endtask
task expect_seen(input [8*56-1:0] what, input integer got); begin
    if (got == 0) begin $display("ERROR: glue: never seen: %0s", what); fail; end
end endtask

initial begin
    wait (done);
    if (!timeout) begin
        force dut.dma.aen = 1'b0;
        force dut.dma.memw_n = 1'b1;
        force dut.dma.ior_n_o = 1'b1;
        force dut.startup = sw_su;
        force dut.cpu.a = sw_a;
        force dut.cpu.dbin_pin = sw_rd;
        force dut.cpu.wr_n = sw_rd;
        sweep(1, 1'b0, 1'b1);
        sweep(2, 1'b0, 1'b0);
        sweep(3, 1'b1, 1'b1);
        sweep(4, 1'b1, 1'b0);
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
        expect_count("start-up ends", su_ends, 1);
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
