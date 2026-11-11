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
//    docs b; ERROR: hold time); f1 106 640 (ERROR: phi count). The window must not contain an 8275 Reset
//    command (it stops the DMA; the monitor's second video init sends one later in the boot): ERROR: dma
//    cost if it does.
// 2. Samples: at every clk where the 8080 latches pin_din (dbin_pin high, k580vm80a.v:258) or loads its
//    opcode register (~f2 & (reset | m1 & t3), :538), cpu_i must be the reference byte of the CPU's
//    address: the monitor in start-up (the TB's su_exp) and at E000-FFFF, the RAM shadow below 8000, the
//    TB's ext_di at A000-BFFF; the 8255 (8000-9FFF) and the 8275 (C000-DFFF) are excluded (ERROR:
//    sample). At every 8275 DMA byte (the clk after the 8257 IOR rise with DACK2, where the 8275 takes
//    w_d) w_d must be the RAM shadow byte of that transfer's address (ERROR: dma byte). The transfer's
//    address is latched at its ADSTB rise (theta-up of S1, rel 4); from the clk after it until AEN falls
//    or the next ADSTB rise (the update at theta-up after S4, rel 40) the 8257 address and the system
//    address must stay at it, through the IOR rise ([C78] TAHR); it must have A15 = 0 (a RAM address)
//    and follow the channel 2 block the CPU programmed last (the monitor's BIOS 0x2E7-0x2FA: 76D0h, 2340
//    transfers, autoload): the block restarts at every CPU write to the 8257 mode register that enables
//    channel 2 (mode bit 2; the monitor writes A4h, and runs its video init twice during the boot: CALL
//    FACE at F83E and at F858), with the address and the count (low 14 bits + 1) the CPU wrote to channel
//    2 through the first / last flip-flop (modelled from the CPU's writes, not read from the 8257); DMA
//    byte n since the restart is block transfer k = n mod length at base + k (the autoload repeats it);
//    and the first DMA byte of every frame from fa on (the row 0 fill in the retrace row) must be block
//    transfer 0 (the 8257 in step with the frame) (all ERROR: dma byte). The frame start is checked only
//    for a frame that starts after the last enabling mode write with no 8275 Reset command (00h written
//    with A0 = 1) since that write: an 8275 Reset kills the fill in progress, so the 8257 is legitimately
//    out of step with the rows until the monitor reprograms it (INFO for each frame not checked). Each kind counts its mismatches without
//    stopping the run (each kind printed at most 10 times, one summary error each at the end), so a fault
//    that breaks several shows them all. The clk where HLDA rises inside T3 and the clk where AEN rises
//    are counted (and checked when the CPU samples there).
//    The RAM shadow: written at every clk with CPU WR low, AEN low, start-up off and A15 = 0, the TB
//    memory's write rule (the TB memory writes at the first clk of WR low, the shadow at every one, with
//    the same address and data); never written bytes are 00 (the TB memory's power-up content).
//    Known coverage limits (review of Tasks 13-14, mutants m6, m7): the moment a row fill starts (the
//    first DRQ of a fill against the row start) is not checked, only the margin at its end (INFO in
//    stats.txt); the data of the DMA byte check is the monitor's screen content only, so a fault in a bit
//    that no screen byte of the boot sets (e.g. bit 7) can pass.
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
localparam [15:0] X_BASE = 16'h76D0;     // the monitor's channel 2 block: 76D0h, 2340 transfers, autoload
localparam integer X_BLOCK = 2340;       // (the block until the first enabling mode write; no DMA before it)

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
reg [15:0] xa = 16'h0000, xe;
reg adstb_q = 1'b0, xa_on = 1'b0, xa_ok = 1'b0, xa_rep = 1'b0;
integer xk, a_bad = 0, q_bad = 0, f_bad = 0, n_ad = 0, n_hold = 0, n_fs = 0, fs_fr = -1;
// the channel 2 block the CPU programmed: its writes to the 8257 (E000-FFFF) and the 8275 (C000-DFFF),
// latched while WR is low and taken at the WR rise (as the chips do), AEN low and start-up off
reg [15:0] p_ad2 = 16'h0000, p_tr2 = 16'h0000, q_base = X_BASE, w_a;
reg [7:0] w_d;
reg w_on = 1'b0, wr_q = 1'b1, p_ff = 1'b0, m_seen = 1'b0, c_rst = 1'b0, fs_ok = 1'b0;
integer q_n = 0, q_len = X_BLOCK, n_rp = 0, n_cr = 0, n_fs_skip = 0, fr_q = -1;
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
        $display("INFO: machine16: DMA addresses: %0d latched at ADSTB, %0d clk held, %0d frame starts checked, %0d not checked; channel 2 block restarts %0d, 8275 Reset commands %0d",
                 n_ad, n_hold, n_fs, n_fs_skip, n_rp, n_cr);
        if (a_bad != 0) begin $display("ERROR: dma byte: the DMA address moved after the ADSTB rise in %0d transfers", a_bad); err; end
        if (q_bad != 0) begin $display("ERROR: dma byte: %0d DMA bytes not at the address of the 8257 block", q_bad); err; end
        if (f_bad != 0) begin $display("ERROR: dma byte: %0d frames whose first DMA byte is not transfer 0 of the 8257 block", f_bad); err; end
        if (d_n == 0 || n_ad != d_n || n_hold == 0 || n_rp == 0
            || (`M16.arm && (n_fs + n_fs_skip != `M16.frame - `M16.fa || n_fs == 0))) begin
            $display("ERROR: dma byte: %0d DMA bytes, %0d addresses latched, %0d clk held, %0d block restarts, %0d frame starts checked + %0d not checked, expected %0d, %0d, nonzero, nonzero, nonzero + %0d in all",
                     d_n, n_ad, n_hold, n_rp, n_fs, n_fs_skip, d_n, d_n, `M16.arm ? `M16.frame - `M16.fa : 0); err; end
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
    if (fr != fr_q) begin fs_ok = m_seen && !c_rst; fr_q = fr; end   // a frame starts: its start checked?
    win =`M16.arm && fr >= `M16.fa && fr <= `M16.fa + 2;
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
    //---- the CPU's writes to the 8257 and the 8275: the channel 2 block, its restarts, the 8275 Reset
    if (`D16.clocks.reset) p_ff = 1'b0;                          // the 8257 RESET clears the first / last flip-flop
    if (!`D16.cpu.pin_wr_n) begin
        w_on = !`D16.startup && !`D16.dma.aen; w_a = `D16.bus_a; w_d = `D16.cpu.pin_dout;
    end else if (!wr_q && w_on && !`D16.clocks.reset) begin     // the WR rise: the write completes
        if (w_a[15:13] == 3'b111) begin                             // the 8257 (A3-A0)
            if (w_a[3]) begin
                if (w_a[2:0] == 3'd0) begin                         // the mode register
                    p_ff = 1'b0;
                    if (w_d[2]) begin                               // channel 2 enabled: its block restarts
                        q_base = p_ad2; q_len = p_tr2[13:0] + 1; q_n = 0;
                        m_seen = 1'b1; c_rst = 1'b0; fs_ok = 1'b0; n_rp = n_rp + 1;
                        $display("INFO: dma byte: 8257 mode %h: the channel 2 block restarts at %h, %0d transfers (ce16 %0d, frame %0d)",
                                 w_d, q_base, q_len, `M16.n16, fr);
                    end
                end
            end else begin
                if (w_a[2:1] == 2'd2) begin
                    if (w_a[0]) begin if (p_ff) p_tr2[15:8] = w_d; else p_tr2[7:0] = w_d; end
                    else begin if (p_ff) p_ad2[15:8] = w_d; else p_ad2[7:0] = w_d; end
                end
                p_ff = !p_ff;
            end
        end else if (w_a[15:13] == 3'b110 && w_a[0] && w_d == 8'h00) begin     // the 8275 Reset command
            c_rst = 1'b1; fs_ok = 1'b0; n_cr = n_cr + 1;
            $display("INFO: dma byte: 8275 Reset command (ce16 %0d, frame %0d)", `M16.n16, fr);
            if (win) begin                                          // it stops the DMA: the cost would not be 3 x 2340
                $display("ERROR: dma cost: the cost window (frames %0d..%0d) contains an 8275 Reset (ce16 %0d, frame %0d)",
                         `M16.fa, `M16.fa + 2, `M16.n16, fr); err; end
        end
    end
    wr_q = `D16.cpu.pin_wr_n;
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
    //---- the 8275 DMA bytes: the address latched at the ADSTB rise and held; the byte at the clk after IOR rises
    if (`D16.dma.adstb && !adstb_q) begin
        xa = `D16.dma.a_o; xa_on = 1'b1; xa_ok = 1'b1; xa_rep = 1'b0;
    end else if (xa_on) begin
        if (!`D16.dma.aen) xa_on = 1'b0;                          // the transfer's bus cycle is over
        else begin
            n_hold = n_hold + 1;
            if ((`D16.dma.a_o !== xa || `D16.bus_a !== xa) && !xa_rep) begin
                xa_rep = 1'b1; a_bad = a_bad + 1;
                if (a_bad <= PRINTS)
                    $display("ERROR: dma byte: the DMA address moved after the ADSTB rise: 8257 A %h, bus_a %h, latched %h (IOR %0s; ce16 %0d, frame %0d)",
                             `D16.dma.a_o, `D16.bus_a, xa, `D16.dma.ior_n_o ? "high" : "low", `M16.n16, fr);
            end
        end
    end
    if (`D16.dma.ior_n_o && !ior_q && dack_q) begin
        d_n = d_n + 1;
        if (win) w_xfer = w_xfer + 1;
        if (fr >= 0 && fr < NF) st_xfer[fr] = st_xfer[fr] + 1;
        last_byte = `M16.n16;
        row_x = row_x + 1;
        // the address: latched, a RAM address, the programmed block; the frame's first byte is transfer 0
        xk = q_n % q_len;
        xe = q_base + xk;
        q_n = q_n + 1;
        if (xa_ok) n_ad = n_ad + 1;
        if (!xa_ok || xa[15] || xa !== xe) begin
            q_bad = q_bad + 1;
            if (q_bad <= PRINTS) begin
                if (!xa_ok) $display("ERROR: dma byte: DMA byte %0d without an ADSTB rise since the last one (ce16 %0d, frame %0d)",
                                     d_n, `M16.n16, fr);
                else if (xa[15]) $display("ERROR: dma byte: DMA byte %0d at %h: not a RAM address (A15 set), expected %h (ce16 %0d, frame %0d)",
                                          d_n, xa, xe, `M16.n16, fr);
                else $display("ERROR: dma byte: DMA byte %0d at %h, expected %h (%h + transfer %0d of the 8257 block of %0d, autoload; ce16 %0d, frame %0d)",
                              d_n, xa, xe, q_base, xk, q_len, `M16.n16, fr);
            end
        end
        if (`M16.arm && fr >= `M16.fa && fr != fs_fr) begin
            fs_fr = fr;
            if (!fs_ok) begin
                n_fs_skip = n_fs_skip + 1;
                $display("INFO: dma byte: frame %0d start not checked (the 8257 or the 8275 reprogrammed)", fr);
            end else begin
                n_fs = n_fs + 1;
                if (xk != 0) begin
                    f_bad = f_bad + 1;
                    if (f_bad <= PRINTS)
                        $display("ERROR: dma byte: frame %0d: its first DMA byte (the row 0 fill) is transfer %0d of the 8257 block (%h), expected transfer 0 at %h: the 8257 out of step with the frame (ce16 %0d)",
                                 fr, xk, xe, q_base, `M16.n16);
                end
            end
        end
        xa_ok = 1'b0;
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
    ior_q = `D16.dma.ior_n_o; dack_q = !`D16.dma.dack_n[2]; adstb_q = `D16.dma.adstb; vrtc_q = `D16.crt.vrtc; rw_q = `D16.crt.rw;
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
