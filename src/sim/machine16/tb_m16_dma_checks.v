// The DMA cost and the sample checks of tb_rk86_machine16 (spec 9.1-4, 9.1-6) and its outputs frame.hex
// and stats.txt. One instance inside tb_rk86_machine16; it reads the machine and the TB through
// hierarchical names (tb_rk86_machine16.dut..., frame, arm, fa, done, su_exp, ext_di). It samples at the
// rising clk edge the values the flip-flops take there (the pre-edge values: the same values the TB's
// falling-edge checks see), so the TB's falling-edge counters (frame, arm, fa, done) are settled.
// Everything runs in the normal frames only (until the TB's done): the RESET re-arm, the end condition
// and the forced decoder sweep after them are not looked at.
// 1. DMA cost over the three frames fa, fa + 1, fa + 2 (from the arming VRTC rise; the Global
//    Constraints): ce16 with AEN high 280 800 = 3 x 2340 x 40 (ERROR: dma cost); HOLD (HRQ) rises 7020
//    (ERROR: hold periods); f1 with HLDA high 42 120, and [6, 6] per HOLD period (4N + 2 with N = 1,
//    docs b; ERROR: hold time); f1 106 640 (ERROR: phi count).
// 2. Samples: at every clk where the 8080 latches pin_din (dbin_pin high, k580vm80a.v:258) or loads its
//    opcode register (~f2 & (reset | m1 & t3), :538), cpu_i must be the reference byte of the CPU's
//    address: the monitor in start-up (the TB's su_exp) and at E000-FFFF, the RAM shadow below 8000, the
//    TB's ext_di at A000-BFFF; the 8255 (8000-9FFF) and the 8275 (C000-DFFF) are excluded (ERROR:
//    sample). At every 8275 DMA byte (the clk after the 8257 IOR rise with DACK2, where the 8275 takes
//    w_d) w_d must be the RAM shadow byte of that transfer's address (ERROR: dma byte). Both count their
//    mismatches without stopping the run (each kind printed at most 10 times, one summary error each at
//    the end), so a fault that breaks both shows both. The clk where HLDA rises inside T3 and the clk
//    where AEN rises are counted (and checked when the CPU samples there).
//    The RAM shadow: written at every clk with CPU WR low, AEN low, start-up off and A15 = 0 (the TB
//    memory's write rule); never written bytes are 00 (the TB memory's power-up content).
// 3. frame.hex: pix (0 / 1, one line per dot) at every pix_ce for 516 x 310 dots from a VRTC fall, the
//    last frame completed before done (from the arming point on; each capture must be exactly 516 x 310
//    dots from one VRTC fall to the next). stats.txt: per frame the ce16 with AEN high, the HOLD periods,
//    the f1 with HLDA high, the transfers, the f1, the smallest margin (from the last DMA byte of a row's
//    fill to the start of that row, the 8275's row counter change at its HRTC rise) and its row.
`default_nettype none
`timescale 1ns/1ns
`define M16 tb_rk86_machine16
`define D16 tb_rk86_machine16.dut
module tb_m16_dma_checks;
localparam integer X_AEN = 280800;       // 3 x 2340 x 40
localparam integer X_HOLD = 7020;        // 3 x 2340
localparam integer X_HLDA = 42120;       // 3 x 2340 x 6
localparam integer X_HLDA_PER = 6;       // HLDA high 4N + 2 f1 per HOLD period, N = 1
localparam integer X_F1 = 106640;        // 3 x 319 920 / 9
localparam integer X_XFER = 7020;        // 3 x 2340 DMA bytes
localparam integer DOTS = 516 * 310;
localparam integer NF = 64;              // frames in stats.txt
localparam integer PRINTS = 10;          // mismatch lines per kind

wire clk = `M16.clk;

//---------------- the reference: the RAM shadow and the monitor
reg [7:0] ram [0:32767];
reg       wrt [0:32767];
reg [7:0] bios [0:2047];
reg [8*512-1:0] bios_file;
integer k;
integer st_aen [0:NF-1], st_hold [0:NF-1], st_hlda [0:NF-1], st_xfer [0:NF-1], st_f1 [0:NF-1];
integer st_mm [0:NF-1], st_mr [0:NF-1];
initial begin
    for (k = 0; k < 32768; k = k + 1) begin ram[k] = 8'h00; wrt[k] = 1'b0; end
    for (k = 0; k < NF; k = k + 1) begin
        st_aen[k] = 0; st_hold[k] = 0; st_hlda[k] = 0; st_xfer[k] = 0; st_f1[k] = 0; st_mm[k] = -1; st_mr[k] = -1;
    end
    if ($value$plusargs("bios=%s", bios_file)) $readmemh(bios_file, bios);    // the TB stops without it
end

//---------------- state
reg aen_q = 1'b0, hold_q = 1'b0, hlda_q = 1'b0, ior_q = 1'b1, dack_q = 1'b0, vrtc_q = 1'b0;
reg [6:0] rw_q = 7'd0;
reg [15:0] xa = 16'h0000;
reg win = 1'b0, win_end = 1'b0, fin = 1'b0;
integer obs = 0, fr = -1, hl_cur = 0, last_byte = 0, row_x = 0;
// the window, frames fa .. fa + 2
integer w_aen = 0, w_hold = 0, w_hlda = 0, w_f1 = 0, w_hl_n = 0, w_hl_min = 0, w_hl_max = 0, w_aen_rise = 0;
integer w_xfer = 0, w_db = 0, w_op = 0, w_hl_t3 = 0, w_hl_t3_s = 0, w_aen_s = 0, w_from = -1;
// the samples, the whole normal run
integer s_db = 0, s_op = 0, s_rst = 0, s_mon = 0, s_ram = 0, s_unw = 0, s_ext = 0, s_excl = 0, s_bad = 0;
integer d_n = 0, d_bad = 0;
// frame.hex
reg fb [0:DOTS-1];
integer fb_n = -1, fb_written = 0, fb_from = -1, fb_start = -1, fd;
// temporaries
reg [15:0] a;
reg [7:0] x;
reg [2:0] src;           // 0 monitor, 1 RAM, 2 RAM never written, 3 window, 4 excluded (8255, 8275)
reg smp_db, smp_op, aen_rise, hl_rise;
reg aen_after = 1'b0;    // the clk after an AEN rise (the memory output follows the DMA address there)

task err; begin `M16.fail; end endtask

task write_frame;
    integer i;
    begin
        fd = $fopen("frame.hex", "w");
        if (fd == 0) begin $display("ERROR: frame.hex: cannot open"); err; end
        else begin
            for (i = 0; i < DOTS; i = i + 1) $fwrite(fd, "%0d\n", fb[i]);
            $fclose(fd);
            fb_written = fb_written + 1;
        end
    end
endtask

task window_checks; begin
    $display("INFO: machine16: frames %0d..%0d: AEN %0d ce16, HOLD periods %0d, HLDA %0d f1 (%0d..%0d per period over %0d), f1 %0d, AEN rises %0d, DMA bytes %0d",
             `M16.fa, `M16.fa + 2, w_aen, w_hold, w_hlda, w_hl_min, w_hl_max, w_hl_n, w_f1, w_aen_rise, w_xfer);
    $display("INFO: machine16: frames %0d..%0d: samples DBIN %0d, opcode %0d; HLDA rises inside T3 %0d (with a sample %0d); samples at an AEN rise %0d",
             `M16.fa, `M16.fa + 2, w_db, w_op, w_hl_t3, w_hl_t3_s, w_aen_s);
    if (w_aen != X_AEN) begin
        $display("ERROR: dma cost: %0d ce16 with AEN high in frames %0d..%0d, expected %0d (3 x 2340 x 40)",
                 w_aen, `M16.fa, `M16.fa + 2, X_AEN); err; end
    if (w_aen_rise != X_XFER) begin
        $display("ERROR: dma cost: %0d AEN rises in frames %0d..%0d, expected %0d (3 x 2340)",
                 w_aen_rise, `M16.fa, `M16.fa + 2, X_XFER); err; end
    if (w_hold != X_HOLD) begin
        $display("ERROR: hold periods: %0d HOLD rises in frames %0d..%0d, expected %0d (3 x 2340)",
                 w_hold, `M16.fa, `M16.fa + 2, X_HOLD); err; end
    if (w_hlda != X_HLDA) begin
        $display("ERROR: hold time: %0d f1 with HLDA high in frames %0d..%0d, expected %0d (3 x 2340 x 6)",
                 w_hlda, `M16.fa, `M16.fa + 2, X_HLDA); err; end
    if (w_hl_n != X_HOLD || w_hl_min != X_HLDA_PER || w_hl_max != X_HLDA_PER) begin
        $display("ERROR: hold time: HLDA high %0d..%0d f1 per HOLD period over %0d periods in frames %0d..%0d, expected %0d..%0d over %0d",
                 w_hl_min, w_hl_max, w_hl_n, `M16.fa, `M16.fa + 2, X_HLDA_PER, X_HLDA_PER, X_HOLD); err; end
    if (w_f1 != X_F1) begin
        $display("ERROR: phi count: %0d f1 in frames %0d..%0d, expected %0d (3 x 319920 / 9)", w_f1, `M16.fa, `M16.fa + 2, X_F1);
        err; end
    if (w_xfer != X_XFER) begin
        $display("ERROR: dma byte: %0d DMA bytes checked in frames %0d..%0d, expected %0d (3 x 2340)",
                 w_xfer, `M16.fa, `M16.fa + 2, X_XFER); err; end
    if (w_db == 0 || w_op == 0) begin
        $display("ERROR: sample: in frames %0d..%0d %0d DBIN and %0d opcode samples checked, expected both nonzero",
                 `M16.fa, `M16.fa + 2, w_db, w_op); err; end
    if (w_hl_t3 == 0 || w_hl_t3_s == 0) begin
        $display("ERROR: sample: in frames %0d..%0d %0d HLDA rises inside T3, %0d of them with a CPU sample, expected both nonzero",
                 `M16.fa, `M16.fa + 2, w_hl_t3, w_hl_t3_s); err; end
end endtask

task final_checks;
    integer i, last;
    begin
        if (!win_end) begin
            $display("ERROR: dma cost: the window of frames fa..fa + 2 did not end before the end of the frames (arm %b, fa %0d, frame %0d)",
                     `M16.arm, `M16.fa, `M16.frame); err; end
        $display("INFO: machine16: samples checked: DBIN %0d, opcode %0d (in reset %0d); monitor %0d, RAM %0d (never written %0d), window %0d; excluded (8255, 8275) %0d; DMA bytes %0d",
                 s_db, s_op, s_rst, s_mon, s_ram, s_unw, s_ext, s_excl, d_n);
        if (s_db == 0 || s_op == 0 || s_mon == 0 || s_ram == 0) begin
            $display("ERROR: sample: DBIN %0d, opcode %0d, monitor %0d, RAM %0d samples checked, expected all nonzero", s_db, s_op, s_mon, s_ram);
            err; end
        if (s_bad != 0) begin $display("ERROR: sample: %0d mismatches in all", s_bad); err; end
        if (d_bad != 0) begin $display("ERROR: dma byte: %0d mismatches of %0d DMA bytes", d_bad, d_n); err; end
        if (fb_written == 0) begin $display("ERROR: frame.hex: no complete frame captured"); err; end
        else $display("INFO: machine16: frame.hex: 516 x 310 dots from the VRTC fall at ce16 %0d (%0d frames written in turn)",
                      fb_from, fb_written);
        fd = $fopen("stats.txt", "w");
        if (fd == 0) begin $display("ERROR: stats.txt: cannot open"); err; end
        else begin
            $fwrite(fd, "# rk86_machine16 per frame (from the VRTC rise; ce16 = one 16 MHz period, f1 = one 8224 phase)\n");
            $fwrite(fd, "# window frames %0d..%0d: aen_ce16 %0d hold_periods %0d hlda_f1 %0d f1 %0d transfers %0d\n",
                    `M16.fa, `M16.fa + 2, w_aen, w_hold, w_hlda, w_f1, w_xfer);
            $fwrite(fd, "# frame window aen_ce16 hold_periods hlda_f1 transfers f1 min_margin_ce16 min_margin_row\n");
            last = `M16.frame - 1;
            if (last > NF - 1) last = NF - 1;
            for (i = 0; i <= last; i = i + 1)
                $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n", i, `M16.arm && i >= `M16.fa && i <= `M16.fa + 2,
                        st_aen[i], st_hold[i], st_hlda[i], st_xfer[i], st_f1[i], st_mm[i], st_mr[i]);
            $fclose(fd);
        end
    end
endtask

//---------------- every clk of the normal frames
always @(posedge clk) if (!`M16.done && !fin) begin
    obs = obs + 1;
    fr = `M16.frame;
    win = `M16.arm && fr >= `M16.fa && fr <= `M16.fa + 2;
    if (win && w_from < 0) w_from = `M16.n16;
    if (`M16.arm && !win_end && fr == `M16.fa + 3) begin win_end = 1'b1; window_checks; end
    //---- DMA cost
    aen_rise = `D16.dma.aen && !aen_q;
    hl_rise = `D16.cpu.pin_hlda && !hlda_q;
    if (hl_rise) hl_cur = 0;
    if (`D16.clocks.f1 && `D16.cpu.pin_hlda) hl_cur = hl_cur + 1;
    if (win) begin
        if (`D16.clocks.f1) w_f1 = w_f1 + 1;
        if (`M16.ce16 && `D16.dma.aen) w_aen = w_aen + 1;
        if (`D16.cpu.pin_hold && !hold_q) w_hold = w_hold + 1;
        if (`D16.clocks.f1 && `D16.cpu.pin_hlda) w_hlda = w_hlda + 1;
        if (aen_rise) w_aen_rise = w_aen_rise + 1;
        if (hl_rise && `D16.cpu.t3) w_hl_t3 = w_hl_t3 + 1;
    end
    if (!`D16.cpu.pin_hlda && hlda_q && win) begin            // a HOLD period ended (HLDA fell)
        if (w_hl_n == 0 || hl_cur < w_hl_min) w_hl_min = hl_cur;
        if (w_hl_n == 0 || hl_cur > w_hl_max) w_hl_max = hl_cur;
        w_hl_n = w_hl_n + 1;
    end
    if (fr >= 0 && fr < NF) begin
        if (`D16.clocks.f1) st_f1[fr] = st_f1[fr] + 1;
        if (`M16.ce16 && `D16.dma.aen) st_aen[fr] = st_aen[fr] + 1;
        if (`D16.cpu.pin_hold && !hold_q) st_hold[fr] = st_hold[fr] + 1;
        if (`D16.clocks.f1 && `D16.cpu.pin_hlda) st_hlda[fr] = st_hlda[fr] + 1;
    end
    //---- the RAM shadow (the TB memory's write rule, at the CPU's address)
    if (!`D16.cpu.pin_wr_n && !`D16.dma.aen && !`M16.su_exp && !`D16.cpu.pin_a[15]) begin
        ram[`D16.cpu.pin_a[14:0]] = `D16.cpu.pin_dout;
        wrt[`D16.cpu.pin_a[14:0]] = 1'b1;
    end
    //---- the CPU's samples
    smp_db = `D16.cpu.dbin_pin;
    smp_op = !`D16.clocks.f2 && (`D16.cpu.reset || (`D16.cpu.m1 && `D16.cpu.t3));
    if ((smp_db || smp_op) && obs >= 2) begin                  // the TB memory output is valid from the 2nd clk
        a = `D16.cpu.pin_a;
        if (`M16.su_exp || a[15:13] == 3'b111) begin x = bios[a[10:0]]; src = 3'd0; end
        else if (!a[15]) begin x = ram[a[14:0]]; src = wrt[a[14:0]] ? 3'd1 : 3'd2; end
        else if (a[15:13] == 3'b101) begin x = `M16.ext_di; src = 3'd3; end
        else begin x = 8'hxx; src = 3'd4; end
        if (src == 3'd4) s_excl = s_excl + 1;
        else begin
            if (smp_db) s_db = s_db + 1;
            if (smp_op) s_op = s_op + 1;
            if (smp_op && `D16.cpu.reset) s_rst = s_rst + 1;
            case (src)
                3'd0: s_mon = s_mon + 1;
                3'd1: s_ram = s_ram + 1;
                3'd2: begin s_ram = s_ram + 1; s_unw = s_unw + 1; end
                default: s_ext = s_ext + 1;
            endcase
            if (win) begin
                if (smp_db) w_db = w_db + 1;
                if (smp_op) w_op = w_op + 1;
                if (hl_rise && `D16.cpu.t3) w_hl_t3_s = w_hl_t3_s + 1;
                if (aen_rise || aen_after) w_aen_s = w_aen_s + 1;
            end
            if (`D16.cpu_i !== x) begin
                s_bad = s_bad + 1;
                if (s_bad <= PRINTS)
                    $display("ERROR: sample: cpu_i %h, expected %h (%0s at %h, %0s; ce16 %0d, frame %0d, hlda %b, aen %b, bus_a %h)",
                             `D16.cpu_i, x, smp_db ? "DBIN" : "opcode load", a,
                             src == 3'd0 ? "the monitor" : src == 3'd3 ? "the window" : "RAM",
                             `M16.n16, fr, `D16.cpu.pin_hlda, `D16.dma.aen, `D16.bus_a);
            end
        end
    end
    //---- the 8275 DMA bytes: the address while IOR is low with DACK2; the byte at the clk after IOR rises
    if (!`D16.dma.ior_n_o && !`D16.dma.dack_n[2]) xa = `D16.dma.a_o;
    if (`D16.dma.ior_n_o && !ior_q && dack_q) begin
        d_n = d_n + 1;
        if (win) w_xfer = w_xfer + 1;
        if (fr >= 0 && fr < NF) st_xfer[fr] = st_xfer[fr] + 1;
        last_byte = `M16.n16;
        row_x = row_x + 1;
        if (`D16.crt.w_d !== ram[xa[14:0]]) begin
            d_bad = d_bad + 1;
            if (d_bad <= PRINTS)
                $display("ERROR: dma byte: the 8275 holds %h at the IOR rise, expected %h (RAM at %h; ce16 %0d, frame %0d)",
                         `D16.crt.w_d, ram[xa[14:0]], xa, `M16.n16, fr);
        end
    end
    //---- the row starts (the 8275's row counter changes at the HRTC rise): the margin of the row's fill
    if (`D16.crt.rw !== rw_q) begin
        if (row_x > 0 && fr >= 0 && fr < NF && (st_mm[fr] < 0 || `M16.n16 - last_byte < st_mm[fr])) begin
            st_mm[fr] = `M16.n16 - last_byte; st_mr[fr] = `D16.crt.rw;
        end
        row_x = 0;
    end
    //---- frame.hex: from a VRTC fall, 516 x 310 dots on pix_ce
    if (`M16.arm) begin
        if (!`D16.crt.vrtc && vrtc_q) begin
            if (fb_n >= 0 && fb_n != DOTS) begin
                $display("ERROR: frame.hex: %0d dots between two VRTC falls (ce16 %0d), expected %0d", fb_n, `M16.n16, DOTS); err; end
            fb_n = 0;
        end
        if (`D16.pix_ce && fb_n >= 0) begin
            if (fb_n < DOTS) fb[fb_n] = `D16.pix;
            if (fb_n == 0) fb_start = `M16.n16;
            fb_n = fb_n + 1;
            if (fb_n == DOTS) begin fb_from = fb_start; write_frame; end
        end
    end
    aen_after = aen_rise;
    aen_q = `D16.dma.aen; hold_q = `D16.cpu.pin_hold; hlda_q = `D16.cpu.pin_hlda;
    ior_q = `D16.dma.ior_n_o; dack_q = !`D16.dma.dack_n[2]; vrtc_q = `D16.crt.vrtc; rw_q = `D16.crt.rw;
end

//---------------- at the end of the frames (the TB's done, before its late phases)
always @(posedge clk) if (`M16.done && !fin) begin
    fin = 1'b1;
    final_checks;
end
endmodule
`undef M16
`undef D16
`default_nettype wire
