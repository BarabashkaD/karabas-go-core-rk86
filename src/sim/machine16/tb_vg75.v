// k580vg75 against the Intel 8275 data sheet ([D79] 1979 00224A; Task 1 section d, Task 2 CRT-n): the raster
// (character, line and row counters, HRTC, VRTC), the commands and parameters, the status register and its flags,
// the light pen registers and Preset Counters (Task 8). Tasks 9 and 10 add the DMA side and the dot outputs.
// Harness: the ce16 cadence of tb_clocks16.v (64 / 297 of clk); cclk = one clk at every 12th ce16 (CCLK falling
// edge); CPU bus tasks like tb_vv55.v (CS, RD, WR held 4 clk); a DMA stand-in that answers DRQ: DACK low 20 ce16
// after it sees DRQ high, WR low 4 ce16 later for 23 ce16, WR and DACK high at the same clk, the byte the next one
// of a screen image (row r, column c of 78: 20h + (r + c) mod 64; 30 rows, then row 0 again).
// The checks take the raster from the pins: every HRTC, VRTC, DRQ, IRQ edge is stamped with the ce16 count of the
// clk that made it (CCLK falling edges: exact multiples of 12); positions count HRTC falls from a VRTC fall (the
// line) and CCLKs from an HRTC fall (the character); lengths are compared with those of the parameters the TB
// wrote. CPU-visible state is read only through register accesses (CS, A0, RD / WR pulses).
`default_nettype none
`timescale 1ns/1ns
module tb_vg75;
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
reg [3:0] step = 4'd0;
always @(posedge clk) if (ce16) step <= step == 4'd11 ? 4'd0 : step + 4'd1;
wire cclk = ce16 && step == 4'd11;
reg cs_n = 1'b1, rd_n = 1'b1, cpu_wr_n = 1'b1, a0 = 1'b0, lpen = 1'b0, cpu_busy = 1'b0;
reg [7:0] cpu_d = 8'h00;
reg dma_wr_n = 1'b1, dack_n = 1'b1;
reg [7:0] dma_d = 8'h00;
wire wr_n = cpu_wr_n & dma_wr_n;
wire [7:0] d_i = dack_n ? cpu_d : dma_d;
wire [7:0] d_o;
wire drq, irq, hrtc, vrtc, vsp, lten, rvv, hglt;
wire [6:0] cc;
wire [3:0] lc;
wire [1:0] la, gpa;
k580vg75 dut(.clk(clk), .cclk(cclk), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .a0(a0), .d_i(d_i), .d_o(d_o),
    .drq(drq), .dack_n(dack_n), .irq(irq), .lpen(lpen), .hrtc(hrtc), .vrtc(vrtc), .cc(cc), .lc(lc), .la(la),
    .vsp(vsp), .lten(lten), .rvv(rvv), .hglt(hglt), .gpa(gpa));
localparam integer LINE = 1032, FRAME = 319920;            // 4Dh 1Dh 99h 93h: 86 CCLK per line, 310 lines
localparam integer SFRAME = 20160;                         // 0Fh 05h 99h 93h: 24 CCLK per line, 70 lines
localparam integer CUR_ROW = 5, CUR_LINE = 9, CUR_CHAR = 10;
//---------------- messages: ERROR: vg75: <what> (<ID>, [D79] <page>)
integer n16 = 0, errors = 0;
reg [8*72-1:0] ids = "CRT-1, [D79] 1-178, 4.2, D14, S17";
reg [8*200-1:0] msg;
task err2(input [8*200-1:0] what, input [8*72-1:0] id); begin
    $display("ERROR: vg75: %0s (%0s) at ce16 %0d", what, id, n16); errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: vg75: too many errors"); $finish; end
end endtask
task err(input [8*200-1:0] what); err2(what, ids); endtask
task chk(input ok, input [8*200-1:0] what); if (!ok) err2(what, ids); endtask
localparam [8*72-1:0] ID2 = "CRT-2, [D79] 1-182, Fig. 26", ID3 = "CRT-3, [D79] Fig. 27, 28",
    ID12 = "CRT-12, [D79] 1-179, S12", ID13 = "CRT-13, [D79] 1-178, 4.2";
//---------------- events: count and stamp of the last one
localparam integer E_HR = 0, E_HF = 1, E_VR = 2, E_VF = 3, E_DRQ = 4, E_IRQ = 5, E_IRS = 6, E_RS = 7;
integer ev_cnt [0:7];
integer ev_t [0:7];
integer k, mk;
initial for (k = 0; k < 8; k = k + 1) begin ev_cnt[k] = 0; ev_t[k] = 0; end
integer st_q = 0;                    // the ce16 stamp of the previous clk (whose edge made what is seen now)
task ev(input integer id); begin ev_cnt[id] = ev_cnt[id] + 1; ev_t[id] = st_q; end endtask
//---------------- the TB's raster model: tl the line since the VRTC fall (-1 until the first HRTC fall), tc the
// character since the HRTC fall, ri the row whose start was the last row-start HRTC rise (0 at the VRTC fall)
integer tl = -1, tc = 0, ri = 0, rs_row = 0, rs_prev = 0, row, line, e_lc;
reg synced = 1'b0;
integer m_nh = 1, m_nr = 1, m_nv = 1, m_nl = 1, m_u = 0, m_z = 0;
reg m_m = 1'b0, m_sp = 1'b0;
// the frame window: armed by the TB, on from the next VRTC fall to the one after it
reg fw_arm = 1'b0, fw_on = 1'b0, fw_done = 1'b0, lc_chk = 1'b0, vsp_chk = 1'b0, e_vsp;
integer n_lc = 0, n_vsp = 0, n_lcr = 0, n_vret = 0, e_lcr;
integer drq_rows [0:63];
// the cursor: one result per frame
reg cur_on = 1'b0, cur_first = 1'b0, cur_seen = 1'b0;
reg cur_hist [0:63];
integer nf = 0;
// Preset Counters: 0 idle, 1 armed (E0h to come), 2 held, 3 resumed (checked at the next clk), 4 after
integer pr = 0, t_res = 0, t_relw = 0, hr_res = -1, drq_res = -1, vf_res = -1, vr_res = -1, dma_res = 0, dma_vf = 0;
reg pr_pend = 1'b0, cc_chk = 1'b0;
reg [3:0] pr_e = 4'd0;
reg [8*32-1:0] pr_ctx = "after E0h";    // what the TB last did while held, for the held messages
reg [7:0] e_cc;
integer n_cc = 0;
// the DMA stand-in
integer ndma = 0, img_r = 0, img_c = 0, dst = 0, dcnt = 0;
reg img_restart = 1'b0, dma_off = 1'b0;    // dma_off: the stand-in does not answer DRQ (an underrun)
// the last CPU write: its WR rise, the row starts and the first DRQ rise after it
integer t_wrup = 0, rs_at_wrup = 0, drq1_t = -1, drq1_rs_t = 0, drq1_rs_row = 0, drq1_rs_prev = 0, drq1_nrs = 0;
reg cclk_q = 1'b0, cpu_wr_q = 1'b1, hrtc_q = 1'b0, vrtc_q = 1'b0, drq_q = 1'b0, irq_q = 1'b0, x_seen = 1'b0;
reg hr_ev, hf_ev, vr_ev, vf_ev;
reg vh_en = 1'b1, pw_chk = 1'b0, vsp_hi = 1'b0, vsp_hi_e = 1'b0;
reg [1:0] pw_e = 2'd0;
always @(posedge clk) begin
    // CRT-13: no output is X
    if (!x_seen && ^{d_o, drq, irq, hrtc, vrtc, cc, lc, la, vsp, lten, rvv, hglt, gpa} === 1'bx) begin
        x_seen = 1'b1; err2("x: an output is X", ID13);
    end
    // the outputs change only at a CCLK fall (seen one clk later) and DRQ at the DMA WR edges: every other clk
    // with no edge of a watched pin and no CPU WR rise has nothing to check
    if (cclk_q || cclk || hrtc !== hrtc_q || vrtc !== vrtc_q || drq !== drq_q || irq !== irq_q || cpu_wr_n !== cpu_wr_q
        || pr == 3) begin
        // CRT-1: the Reset state before the first command (S17)
        if (pw_chk && vsp !== 1'b1 && !pw_e[0]) begin pw_e[0] = 1'b1; err("vsp: low before the first command (S17)"); end
        if (pw_chk && drq !== 1'b0 && !pw_e[1]) begin pw_e[1] = 1'b1; err("drq: high before the first command (S17)"); end
        if (vsp_hi && vsp !== 1'b1 && !vsp_hi_e) begin vsp_hi_e = 1'b1; err("vsp: low with VE = 0"); end
        // CRT-12: held after E0h; VRTC up at the resume
        if (pr == 2) begin
            if (hrtc !== 1'b0 && !pr_e[0]) begin
                pr_e[0] = 1'b1; $sformat(msg, "preset: HRTC high while the counters are held, %0s", pr_ctx); err2(msg, ID12);
            end
            if (vrtc !== 1'b0 && !pr_e[1]) begin
                pr_e[1] = 1'b1; $sformat(msg, "preset: VRTC high while the counters are held, %0s", pr_ctx); err2(msg, ID12);
            end
            if (vsp !== 1'b1 && !pr_e[2]) begin
                pr_e[2] = 1'b1; $sformat(msg, "preset: VSP low while the counters are held, %0s", pr_ctx); err2(msg, ID12);
            end
            if (drq !== 1'b0 && !pr_e[3]) begin
                pr_e[3] = 1'b1; $sformat(msg, "preset: DRQ high while the counters are held, %0s", pr_ctx); err2(msg, ID12);
            end
        end else if (pr == 3) begin
            pr = 4;
            if (vrtc !== 1'b1) err2("preset: VRTC not high after the first CCLK fall after the releasing command", ID12);
        end
        // the edges of HRTC and VRTC
        hr_ev = hrtc === 1'b1 && hrtc_q === 1'b0;
        hf_ev = hrtc === 1'b0 && hrtc_q === 1'b1;
        vr_ev = vrtc === 1'b1 && vrtc_q === 1'b0;
        vf_ev = vrtc === 1'b0 && vrtc_q === 1'b1;
        if (hrtc !== hrtc_q && !cclk_q) err2("hrtc: changed off a CCLK fall", ID2);
        if (vrtc !== vrtc_q && !cclk_q) err2("vrtc: changed off a CCLK fall", ID3);
        if (vh_en && (vr_ev || vf_ev) && !hr_ev) err2("vrtc: changed at a CCLK fall without an HRTC rise", ID3);
        if (hr_ev) ev(E_HR);
        if (hf_ev) ev(E_HF);
        if (vr_ev) ev(E_VR);
        if (vf_ev) ev(E_VF);
        // the raster model
        if (hf_ev) begin tl = tl + 1; tc = 0; end
        else if (cclk_q) tc = tc + 1;
        if (vf_ev) begin
            tl = -1; ri = 0; synced = 1'b1;
            if (fw_on) begin fw_on = 1'b0; fw_done = 1'b1; end
            if (fw_arm) begin
                fw_arm = 1'b0; fw_on = 1'b1; n_lc = 0; n_vsp = 0; n_lcr = 0; n_vret = 0;
                for (mk = 0; mk < 64; mk = mk + 1) drq_rows[mk] = 0;
            end
            if (cur_on) begin
                if (cur_first) cur_first = 1'b0;
                else if (nf < 64) begin cur_hist[nf] = cur_seen; nf = nf + 1; end
                cur_seen = 1'b0;
            end
            if (pr == 4 && vf_res < 0) begin vf_res = st_q; dma_vf = ndma; cc_chk = 1'b1; n_cc = 0; end
        end else if (hr_ev && synced && (tl + 1) % m_nl == 0) ri = (tl + 1) / m_nl;
        if (hr_ev && synced && (tl + 1) % m_nl == 0) begin rs_prev = rs_row; rs_row = ri; ev(E_RS); end
        if (vr_ev) cc_chk = 1'b0;
        if (pr == 4 && vr_ev && vf_res >= 0 && vr_res < 0) vr_res = st_q;
        if (pr == 4 && hr_ev && hr_res < 0) hr_res = st_q;
        // LC holds the next line's value from the CCLK fall of the HRTC rise ([D79] Fig. 15, 27; VID-2)
        if (fw_on && lc_chk && hr_ev && tl >= 0) begin
            line = (tl + 1) % m_nl; e_lcr = m_m ? (line == 0 ? m_nl - 1 : line - 1) : line; n_lcr = n_lcr + 1;
            if (lc !== e_lcr) begin
                $sformat(msg, "lc: at the HRTC rise after line %0d: LC %0d, expected %0d (the next line's)", tl, lc, e_lcr);
                err(msg);
            end
        end
        // VSP high at every CCLK fall during HRTC and VRTC ([D79] 1-163 pin 35)
        if (fw_on && vsp_chk && cclk_q && (hrtc === 1'b1 || vrtc === 1'b1)) begin
            n_vret = n_vret + 1;
            if (vsp !== 1'b1) begin $sformat(msg, "vsp: low during HRTC / VRTC (line %0d char %0d)", tl, tc); err(msg); end
        end
        // DRQ, IRQ, the IR set event
        if (drq === 1'b1 && drq_q === 1'b0) begin
            ev(E_DRQ);
            if (fw_on && ri < 64) drq_rows[ri] = drq_rows[ri] + 1;
            if (pr == 4 && drq_res < 0) drq_res = st_q;
            if (drq1_t < 0) begin
                drq1_t = st_q; drq1_rs_t = ev_t[E_RS]; drq1_rs_row = rs_row; drq1_rs_prev = rs_prev;
                drq1_nrs = ev_cnt[E_RS] - rs_at_wrup;
            end
        end
        if (irq === 1'b1 && irq_q === 1'b0) ev(E_IRQ);
        if (dut.ir_set === 1'b1) begin ev_cnt[E_IRS] = ev_cnt[E_IRS] + 1; ev_t[E_IRS] = n16; end
        // the display positions: the outputs of character tc of line tl
        if (cclk_q && synced && tl >= 0 && tl < m_nr * m_nl && tc < m_nh) begin
            row = tl / m_nl; line = tl % m_nl;
            if (fw_on && lc_chk) begin
                e_lc = m_m ? (line == 0 ? m_nl - 1 : line - 1) : line;
                if (tc == 0) n_lc = n_lc + 1;
                if (lc !== e_lc) begin
                    $sformat(msg, "lc: row %0d line %0d char %0d: LC %0d, expected %0d (M = %0d)", row, line, tc, lc, e_lc, m_m);
                    err(msg);
                end
            end
            if (fw_on && vsp_chk) begin
                e_vsp = (m_sp && row % 2 == 1) || (m_u >= 8 && (line == 0 || line == m_nl - 1));
                n_vsp = n_vsp + 1;
                if (vsp !== e_vsp) begin
                    $sformat(msg, "%0s: row %0d line %0d char %0d: VSP %b, expected %b", m_sp ? "spaced rows" : "vsp",
                        row, line, tc, vsp, e_vsp);
                    err(msg);
                end
            end
            if (cur_on && !cur_first && lten === 1'b1) begin
                if (row == CUR_ROW && line == CUR_LINE && tc == CUR_CHAR) cur_seen = 1'b1;
                else begin $sformat(msg, "cursor: LTEN high at row %0d line %0d char %0d", row, line, tc); err(msg); end
            end
            if (cc_chk && line == 0) begin
                e_cc = (8'h20 + (row + tc) % 64) & 8'h7F; n_cc = n_cc + 1;
                if (cc !== e_cc[6:0]) begin
                    $sformat(msg, "preset: row %0d char %0d: CC %h, expected %h (the screen image row %0d)", row, tc, cc, e_cc, row);
                    err2(msg, ID12);
                end
            end
        end
        // CPU writes: the WR rise; for E0h and the releasing command the first CCLK fall after it
        if (cpu_wr_n && !cpu_wr_q) begin
            t_wrup = n16; rs_at_wrup = ev_cnt[E_RS]; drq1_t = -1;
            if (pr == 1 && a0 && cpu_d == 8'hE0) pr_pend = 1'b1;
            else if (pr == 2 && a0 && cpu_d[7:5] != 3'd7) begin pr_pend = 1'b1; t_relw = n16; end
        end else if (pr_pend && cclk) begin
            pr_pend = 1'b0;
            if (pr == 1) begin pr = 2; vh_en = 1'b0; end
            else if (pr == 2) begin pr = 3; t_res = n16; dma_res = ndma; end
        end
    end
    hrtc_q = hrtc; vrtc_q = vrtc; drq_q = drq; irq_q = irq; cpu_wr_q = cpu_wr_n; cclk_q = cclk;
    st_q = n16;
    if (ce16) n16 = n16 + 1;
end
//---------------- the DMA stand-in
always @(posedge clk) if (ce16) begin
    case (dst)
        0: if (drq === 1'b1 && !dma_off) begin dst = 1; dcnt = 0; end
        1: begin
            dcnt = dcnt + 1;
            if (dcnt >= 20 && !cpu_busy) begin
                if (drq === 1'b1 && !dma_off) begin dack_n <= 1'b0; dma_d <= 8'h20 + (img_r + img_c) % 64; dst = 2; dcnt = 0; end
                else dst = 0;
            end
        end
        2: begin dcnt = dcnt + 1; if (dcnt == 4) begin dma_wr_n <= 1'b0; dst = 3; dcnt = 0; end end
        default: begin
            dcnt = dcnt + 1;
            if (dcnt == 23) begin
                dma_wr_n <= 1'b1; dack_n <= 1'b1; dst = 0; ndma = ndma + 1;
                img_c = img_c + 1;
                if (img_c == 78) begin img_c = 0; img_r = img_r == 29 ? 0 : img_r + 1; end
            end
        end
    endcase
end
//---------------- CPU bus (the bus is free of the stand-in: DACK and its WR high)
reg [7:0] sv;
reg mid_irq;
integer nb;
task bus_free; begin
    @(negedge clk); nb = 0;
    while (!dack_n || !dma_wr_n) begin
        @(negedge clk); nb = nb + 1;
        if (nb > 2000) begin $display("FATAL: vg75: bus: the DMA stand-in holds the bus timed out"); $finish; end
    end
    cpu_busy = 1'b1;
end endtask
task wr(input a, input [7:0] dd); begin
    bus_free;
    cs_n = 1'b0; a0 = a; cpu_d = dd;
    @(negedge clk) cpu_wr_n = 1'b0;
    repeat (4) @(negedge clk);
    cpu_wr_n = 1'b1;
    if (img_restart) begin img_r = 0; img_c = 0; img_restart = 1'b0; end
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
    cpu_busy = 1'b0;
end endtask
task rd(input a, output [7:0] dd); begin
    bus_free;
    cs_n = 1'b0; a0 = a;
    @(negedge clk) rd_n = 1'b0;
    repeat (2) @(negedge clk); mid_irq = irq;
    repeat (2) @(negedge clk); dd = d_o; rd_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
    cpu_busy = 1'b0;
end endtask
function [8*10-1:0] ftopic(input integer b);
    case (b)
        7: ftopic = "status"; 6: ftopic = "ie"; 5: ftopic = "ir"; 4: ftopic = "light pen";
        3: ftopic = "ic"; 2: ftopic = "ve"; 1: ftopic = "du"; default: ftopic = "fo";
    endcase
endfunction
function [8*3-1:0] fname(input integer b);
    case (b)
        7: fname = "0"; 6: fname = "IE"; 5: fname = "IR"; 4: fname = "LP"; 3: fname = "IC"; 2: fname = "VE";
        1: fname = "DU"; default: fname = "FO";
    endcase
endfunction
// a status read (A0 = 1, CRT-43): the bits of mask m against e, one message per bit, named by its flag
task status_is(input [7:0] e, input [7:0] m, input [8*48-1:0] where);
    integer b;
    begin
        rd(1'b1, sv);
        for (b = 7; b >= 0; b = b - 1)
            if (m[b] && sv[b] !== e[b]) begin
                $sformat(msg, "%0s: %0s: status bit %0d (%0s) %b, expected %b", ftopic(b), where, b, fname(b), sv[b], e[b]);
                err(msg);
            end
    end
endtask
//---------------- waits, each with its own bound
task wait_ev(input integer id, input integer lim, input [8*48-1:0] what, output integer t);
    integer c0, tlim;
    begin
        c0 = ev_cnt[id]; tlim = n16 + lim;
        while (ev_cnt[id] == c0) begin
            @(negedge clk);
            if (n16 > tlim) begin $display("FATAL: vg75: %0s timed out", what); $finish; end
        end
        t = ev_t[id];
    end
endtask
task wait_n(input integer n);
    integer tlim;
    begin tlim = n16 + n; while (n16 < tlim) @(negedge clk); end
endtask
task wait_cclk; begin @(posedge clk); while (!cclk) @(posedge clk); @(negedge clk); end endtask
integer tw;
// Reset with its four parameters; the model takes the new lengths and resyncs at the next VRTC fall; the VRTC /
// HRTC rise check is off for the irregular line in which the lengths change
task program(input [7:0] p1, input [7:0] p2, input [7:0] p3, input [7:0] p4); begin
    vh_en = 1'b0;
    wr(1'b1, 8'h00); wr(1'b0, p1); wr(1'b0, p2); wr(1'b0, p3); wr(1'b0, p4);
    synced = 1'b0; m_sp = p1[7]; m_nh = p1[6:0] + 1; m_nv = p2[7:6] + 1; m_nr = p2[5:0] + 1;
    m_u = p3[7:4]; m_nl = p3[3:0] + 1; m_m = p4[7]; m_z = p4[3:0];
    wait_ev(E_HF, 2 * LINE, "program: HRTC fall", tw); wait_ev(E_HF, 2 * LINE, "program: HRTC fall", tw);
    vh_en = 1'b1;
end endtask
// HRTC: fall to rise lo, rise to fall hi ce16, over three lines after the one in which the parameters changed
task line_is(input integer lo, input integer hi, input [8*24-1:0] what);
    integer i, a, b, c;
    begin
        wait_ev(E_HF, 2 * LINE, "hrtc: HRTC fall", a);
        for (i = 0; i < 3; i = i + 1) begin
            wait_ev(E_HR, 2 * LINE, "hrtc: HRTC rise", b);
            wait_ev(E_HF, 2 * LINE, "hrtc: HRTC fall", c);
            if (b - a != lo) begin $sformat(msg, "hrtc: %0s: HRTC fall to rise %0d ce16, expected %0d", what, b - a, lo); err(msg); end
            if (c - b != hi) begin $sformat(msg, "hrtc: %0s: HRTC high %0d ce16, expected %0d", what, c - b, hi); err(msg); end
            a = c;
        end
    end
endtask
// VRTC: high hi, rise to rise per ce16, in a frame that began after the parameters
task frame_is(input integer hi, input integer per, input [8*24-1:0] what);
    integer a, b, c;
    begin
        wait_ev(E_VF, 2 * FRAME, "vrtc: VRTC fall", a);
        wait_ev(E_VR, 2 * FRAME, "vrtc: VRTC rise", a);
        wait_ev(E_VF, 2 * FRAME, "vrtc: VRTC fall", b);
        wait_ev(E_VR, 2 * FRAME, "vrtc: VRTC rise", c);
        if (b - a != hi) begin $sformat(msg, "vrtc: %0s: VRTC high %0d ce16, expected %0d", what, b - a, hi); err(msg); end
        if (c - a != per) begin $sformat(msg, "vrtc: %0s: VRTC rise to rise %0d ce16, expected %0d", what, c - a, per); err(msg); end
    end
endtask
// the frame window: the model in step at a VRTC fall, then the checks from the next VRTC fall to the one after it
task frame_window;
    integer tlim;
    begin
        wait_ev(E_VF, 2 * FRAME, "frame window: VRTC fall", tw);
        fw_done = 1'b0; fw_arm = 1'b1; tlim = n16 + 2 * FRAME;
        while (!fw_done) begin
            @(negedge clk);
            if (n16 > tlim) begin $display("FATAL: vg75: frame window timed out"); $finish; end
        end
    end
endtask
// the counts of a frame window: LC at the HRTC rises after line 0 (all lines but the first); the CCLK falls in
// HRTC or VRTC (all positions of the frame cycle but the display characters)
task window_counts(input [8*24-1:0] what);
    integer e;
    begin
        if (lc_chk && n_lcr != (m_nr + m_nv) * m_nl - 1) begin
            $sformat(msg, "lc: %0s: %0d HRTC rises checked, expected %0d", what, n_lcr, (m_nr + m_nv) * m_nl - 1); err(msg);
        end
        e = (m_nr + m_nv) * m_nl * (m_nh + 2 * (m_z + 1)) - m_nr * m_nl * m_nh;
        if (vsp_chk && n_vret != e) begin
            $sformat(msg, "vsp: %0s: %0d CCLK falls in HRTC / VRTC checked, expected %0d", what, n_vret, e); err(msg);
        end
    end
endtask
// a row whose start begins a fill ([D79] 1-168, 1-172 Fig. 18): the last retrace row (row 0), or the row before a
// display row that is not blanked by spaced rows
function due(input integer r);
    due = r == m_nr + m_nv - 1 || (r + 1 < m_nr && !(m_sp && (r + 1) % 2 == 1));
endfunction
// the resume after E0h (S12): VRTC with the release CCLK fall (the monitor), DRQ within a burst space, the first HRTC
// rise after 78 CCLK, VRTC high 852 CCLK with the 78 bytes of the row 0 fill, line 0 of every row from the image
// rows in order, then the frames of CRT-3
integer tb0, tb1, tb2;
task resume_chk(input [8*24-1:0] lbl, input info); begin
    tb0 = n16;
    while (pr != 4 || vf_res < 0) begin
        @(negedge clk);
        if (n16 > tb0 + 2 * FRAME) begin $display("FATAL: vg75: %0s: the resume and the VRTC fall timed out", lbl); $finish; end
    end
    vh_en = 1'b1;
    if (drq_res < 0 || drq_res - t_res > 84) begin
        $sformat(msg, "%0s: the first DRQ %0d ce16 after the resume CCLK fall, expected 0..84 (the row 0 fill, CRT-20)", lbl, drq_res - t_res);
        err(msg);
    end
    if (info) $display("INFO: vg75: after E0h the first DRQ comes %0d ce16 after the command (row 0 fill, S12)", drq_res - t_relw);
    if (hr_res - t_res != 936) begin $sformat(msg, "%0s: the first HRTC rise %0d ce16 after the resume, expected 936 (78 CCLK)", lbl, hr_res - t_res); err(msg); end
    if (vf_res - t_res != 10224) begin $sformat(msg, "%0s: VRTC high %0d ce16 from the resume, expected 10224 (852 CCLK)", lbl, vf_res - t_res); err(msg); end
    if (dma_vf - dma_res != 78) begin $sformat(msg, "%0s: %0d DMA transfers before the VRTC fall, expected 78 (the row 0 fill)", lbl, dma_vf - dma_res); err(msg); end
    tb0 = n16;
    while (vr_res < 0) begin
        @(negedge clk);
        if (n16 > tb0 + 2 * FRAME) begin $display("FATAL: vg75: %0s: the VRTC rise timed out", lbl); $finish; end
    end
    if (n_cc != 30 * 78) begin $sformat(msg, "%0s: %0d CC samples on line 0 of the rows, expected 2340", lbl, n_cc); err(msg); end
    if (vr_res - vf_res != 309600) begin $sformat(msg, "%0s: VRTC fall to rise %0d ce16, expected 309600 (30 rows)", lbl, vr_res - vf_res); err(msg); end
    wait_ev(E_VF, 2 * FRAME, "preset: VRTC fall", tb1);
    wait_ev(E_VR, 2 * FRAME, "preset: VRTC rise", tb2);
    if (tb1 - vr_res != 10320) begin $sformat(msg, "%0s: VRTC high %0d ce16 in the next frame, expected 10320", lbl, tb1 - vr_res); err(msg); end
    if (tb2 - vr_res != FRAME) begin $sformat(msg, "%0s: VRTC rise to rise %0d ce16 in the next frame, expected 319920", lbl, tb2 - vr_res); err(msg); end
    status_is(8'h00, 8'h02, "after the resume");
end endtask
integer t0, t1, t2, i, c, c2, p1, p2, p3, nt;
reg [7:0] v1, v2, v3;
initial begin
    wait (n16 >= 16000000); $display("FATAL: vg75: run timed out"); $finish;
end
initial begin
    //---------------- 1. CRT-1 power-up: the state after Reset (S17); the counters on parameters 0
    pw_chk = 1'b1;
    wait_n(240);
    status_is(8'h00, 8'hFF, "power-up");
    chk(irq === 1'b0, "ir: power-up: IRQ high");
    // lines of 3 characters (H = 0, ZZZZ = 0): HRTC low for character 0, high for 2
    wait_ev(E_HF, 200, "crt-1: power-up HRTC fall", t0);
    wait_ev(E_HR, 200, "crt-1: power-up HRTC rise", t1);
    wait_ev(E_HF, 200, "crt-1: power-up HRTC fall", t2);
    if (t1 - t0 != 12) begin $sformat(msg, "hrtc: power-up: HRTC low %0d ce16, expected 12 (3 characters per line)", t1 - t0); err(msg); end
    if (t2 - t1 != 24) begin $sformat(msg, "hrtc: power-up: HRTC high %0d ce16, expected 24 (3 characters per line)", t2 - t1); err(msg); end
    // frames of 2 lines (R = 0, VV = 0): 10 VRTC rises in 720 ce16, VRTC high one line
    c = ev_cnt[E_VR]; wait_n(720); c = ev_cnt[E_VR] - c;
    if (c != 10) begin $sformat(msg, "vrtc: power-up: %0d VRTC rises in 720 ce16, expected 10 (2 lines per frame)", c); err(msg); end
    else begin
        wait_ev(E_VR, 200, "crt-1: power-up VRTC rise", t0);
        wait_ev(E_VF, 200, "crt-1: power-up VRTC fall", t1);
        wait_ev(E_VR, 200, "crt-1: power-up VRTC rise", t2);
        if (t1 - t0 != 36) begin $sformat(msg, "vrtc: power-up: VRTC high %0d ce16, expected 36", t1 - t0); err(msg); end
        if (t2 - t0 != 72) begin $sformat(msg, "vrtc: power-up: VRTC rise to rise %0d ce16, expected 72", t2 - t0); err(msg); end
    end
    pw_chk = 1'b0; vsp_hi = 1'b1;
    program(8'h4D, 8'h1D, 8'h99, 8'h93);
    //---------------- 2. CRT-2 the character counter and HRTC
    ids = "CRT-2, [D79] 1-171, 1-178, Fig. 26";
    line_is(936, 96, "4Dh 93h");
    //---------------- 3. CRT-3 rows and VRTC (VE = 0: VSP stays high, CRT-1)
    ids = "CRT-3, [D79] 1-171 Fig. 16, 17, 1-178, Fig. 27, 28";
    frame_is(10320, FRAME, "4Dh 1Dh 99h 93h");
    vsp_hi = 1'b0;
    ids = "CRT-1, [D79] 1-178, 1-179";
    wr(1'b1, 8'h27);
    c = 0; t0 = n16;
    while (c == 0 && n16 < t0 + FRAME + 2 * LINE) begin @(negedge clk); if (vsp === 1'b0) c = 1; end
    chk(c == 1, "display: VSP stays high after 27h (Start Display)");
    ids = "CRT-2, [D79] 1-171, 1-178, Fig. 26";
    program(8'h4F, 8'h1D, 8'h99, 8'h90);
    line_is(960, 24, "4Fh 90h");
    program(8'h00, 8'h1D, 8'h99, 8'h9F);
    line_is(12, 384, "00h 9Fh");
    ids = "CRT-3, [D79] 1-171 Fig. 16, 17, 1-178, Fig. 27, 28";
    program(8'h4D, 8'hC4, 8'h92, 8'h93);
    frame_is(12384, 27864, "4Dh C4h 92h 93h");
    //---------------- 4. CRT-4 line counter modes (LLLL = 9)
    ids = "CRT-4, [D79] 1-169 Fig. 10, 11";
    program(8'h4D, 8'h04, 8'h99, 8'h93);
    lc_chk = 1'b1; frame_window; window_counts("M = 1"); lc_chk = 1'b0;
    if (n_lc != 50) begin $sformat(msg, "lc: M = 1: %0d lines checked, expected 50", n_lc); err(msg); end
    program(8'h4D, 8'h04, 8'h99, 8'h13);
    lc_chk = 1'b1; frame_window; window_counts("M = 0"); lc_chk = 1'b0;
    if (n_lc != 50) begin $sformat(msg, "lc: M = 0: %0d lines checked, expected 50", n_lc); err(msg); end
    //---------------- 5. CRT-5 the underline line and the top / bottom blanking
    ids = "CRT-5, [D79] 1-170 Fig. 12, 13";
    // VSP also checked high at every CCLK fall of HRTC and VRTC ([D79] 1-163 pin 35)
    program(8'h4D, 8'h04, 8'h99, 8'h93); wr(1'b1, 8'h27);
    vsp_chk = 1'b1; frame_window; window_counts("UUUU = 9"); vsp_chk = 1'b0;
    if (n_vsp != 5 * 10 * 78) begin $sformat(msg, "vsp: UUUU = 9: %0d positions checked, expected 3900", n_vsp); err(msg); end
    program(8'h4D, 8'h04, 8'h89, 8'h93); wr(1'b1, 8'h27);          // UUUU = 8: the MSB alone blanks ([D79] 1-178)
    vsp_chk = 1'b1; frame_window; window_counts("UUUU = 8"); vsp_chk = 1'b0;
    if (n_vsp != 5 * 10 * 78) begin $sformat(msg, "vsp: UUUU = 8: %0d positions checked, expected 3900", n_vsp); err(msg); end
    program(8'h4D, 8'h04, 8'h79, 8'h93); wr(1'b1, 8'h27);
    vsp_chk = 1'b1; frame_window; window_counts("UUUU = 7"); vsp_chk = 1'b0;
    if (n_vsp != 5 * 10 * 78) begin $sformat(msg, "vsp: UUUU = 7: %0d positions checked, expected 3900", n_vsp); err(msg); end
    //---------------- 6. CRT-6 spaced rows: the odd rows blanked, no DMA for them
    ids = "CRT-6, [D79] 1-168 Fig. 9, 1-178";
    program(8'hCD, 8'h09, 8'h99, 8'h93); wr(1'b1, 8'h27);      // 10 rows: 0, 2, ..., 8 shown, 1, 3, ..., 9 blanked
    vsp_chk = 1'b1; frame_window; window_counts("spaced rows"); vsp_chk = 1'b0;
    if (n_vsp != 10 * 10 * 78) begin $sformat(msg, "spaced rows: %0d positions checked, expected 7800", n_vsp); err(msg); end
    for (i = 0; i < m_nr + m_nv; i = i + 1)
        if ((drq_rows[i] != 0) != due(i)) begin
            $sformat(msg, "spaced rows: %0d DRQ rises during row %0d, expected %0s", drq_rows[i], i, due(i) ? "some" : "none");
            err(msg);
        end
    //---------------- 7. CRT-7 Start / Stop Display
    ids = "CRT-7, [D79] 1-179, CRT-20";
    program(8'h4D, 8'h1D, 8'h99, 8'h93);
    status_is(8'h00, 8'h44, "display: after 00h (Reset)");
    wait_ev(E_VF, 2 * FRAME, "crt-7: VRTC fall", t0);
    wr(1'b1, 8'h27);
    status_is(8'h44, 8'h44, "display: after 27h");
    t0 = n16;
    while (drq1_t < 0) begin
        @(negedge clk);
        if (n16 > t0 + 3 * 10 * LINE) begin $display("FATAL: vg75: crt-7: the first DRQ after 27h timed out"); $finish; end
    end
    if (drq1_nrs < 1) err("display: the first DRQ after 27h came before the next row start");
    else begin
        if (drq1_t - drq1_rs_t < 0 || drq1_t - drq1_rs_t > 84) begin
            $sformat(msg, "display: the first DRQ %0d ce16 after its row start, expected 0..84 (one burst space)", drq1_t - drq1_rs_t);
            err(msg);
        end
        if (!due(drq1_rs_row)) begin $sformat(msg, "display: the first DRQ in row %0d, which has no fill due", drq1_rs_row); err(msg); end
        if (!(drq1_nrs == 1 || (drq1_nrs == 2 && !due(drq1_rs_prev)))) begin
            $sformat(msg, "display: the first DRQ after 27h at row start %0d after the command, not the next one with a fill due", drq1_nrs);
            err(msg);
        end
    end
    wr(1'b1, 8'h40);
    status_is(8'h40, 8'h44, "display: after 40h");
    wait_cclk;
    vsp_hi = 1'b1;
    frame_is(10320, FRAME, "after 40h");
    // interrupts remain enabled after 40h ([D79] 1-179): IRQ 299 376 ce16 after the VRTC fall (a frame window: no
    // wait on IRQ itself, so a missing IRQ is an ERROR)
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall after 40h", t0);
    rd(1'b1, sv);
    c = ev_cnt[E_IRQ];
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall after 40h", t2);
    if (ev_cnt[E_IRQ] != c + 1) begin
        $sformat(msg, "ir: after 40h (Stop Display): %0d IRQ rises in a frame, expected 1 (interrupts remain enabled)", ev_cnt[E_IRQ] - c);
        err(msg);
    end else if (ev_t[E_IRQ] - t0 != 299376) begin
        $sformat(msg, "ir: after 40h (Stop Display): IRQ rise %0d ce16 after the VRTC fall, expected 299376", ev_t[E_IRQ] - t0);
        err(msg);
    end
    vsp_hi = 1'b0;
    //---------------- 8. CRT-8 interrupts
    ids = "CRT-8, [D79] 1-172 Fig. 19, 20, 1-179, 1-180";
    wr(1'b1, 8'h27);
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    status_is(8'h40, 8'h40, "ir: after 27h");
    c = ev_cnt[E_IRS];
    wait_ev(E_IRQ, FRAME, "ir: IRQ rise", t1);
    if (t1 - t0 != 299376) begin $sformat(msg, "ir: IRQ rise %0d ce16 after the VRTC fall, expected 299376", t1 - t0); err(msg); end
    if (ev_cnt[E_IRS] != c + 1 || ev_t[E_IRS] != t1) err("ir: the set event (dut.ir_set) not once at the IRQ rise");
    status_is(8'h20, 8'h20, "IR set");
    chk(mid_irq === 1'b1, "ir: IRQ low during the status read (expected cleared at RD rise)");
    chk(irq === 1'b0, "ir: IRQ high after the status read");
    status_is(8'h00, 8'h20, "the second status read");
    // the next frame without a status read: IR set again; the frame after it: the set event while IR is set
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    c = ev_cnt[E_IRS];
    wait_ev(E_IRQ, FRAME, "ir: IRQ rise", t1);
    if (t1 - t0 != 299376) begin $sformat(msg, "ir: IRQ rise %0d ce16 after the VRTC fall, expected 299376", t1 - t0); err(msg); end
    c2 = ev_cnt[E_IRQ];
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    if (ev_cnt[E_IRS] != c + 1) begin $sformat(msg, "ir: %0d set events in a frame, expected 1", ev_cnt[E_IRS] - c); err(msg); end
    c = ev_cnt[E_IRS];
    wait_ev(E_IRS, FRAME, "ir: set event", t1);
    if (t1 - t0 != 299376) begin $sformat(msg, "ir: set event with IR set %0d ce16 after the VRTC fall, expected 299376", t1 - t0); err(msg); end
    chk(irq === 1'b1 && ev_cnt[E_IRQ] == c2, "ir: IRQ fell or rose again while IR was set");
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    if (ev_cnt[E_IRS] != c + 1) begin $sformat(msg, "ir: %0d set events in a frame with IR set, expected 1", ev_cnt[E_IRS] - c); err(msg); end
    status_is(8'h20, 8'h20, "IR held over a frame");
    // C0h: no IR in the next frame
    wr(1'b1, 8'hC0);
    status_is(8'h00, 8'h60, "after C0h");
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    c = ev_cnt[E_IRQ]; c2 = ev_cnt[E_IRS];
    wait_ev(E_VF, 2 * FRAME, "ir: VRTC fall", t0);
    chk(ev_cnt[E_IRQ] == c && ev_cnt[E_IRS] == c2, "ir: IR set in a frame after C0h (Disable Interrupt)");
    status_is(8'h00, 8'h20, "a frame after C0h");
    // A0h: IR again
    wr(1'b1, 8'hA0);
    status_is(8'h40, 8'h40, "after A0h");
    wait_ev(E_IRQ, FRAME, "ir: IRQ rise after A0h", t1);
    if (t1 - t0 != 299376) begin $sformat(msg, "ir: IRQ rise after A0h %0d ce16 after the VRTC fall, expected 299376", t1 - t0); err(msg); end
    // 00h (Reset) clears IR and IE
    wr(1'b1, 8'h00);
    chk(irq === 1'b0, "ir: IRQ high after 00h (Reset)");
    status_is(8'h00, 8'h60, "after 00h (Reset)");
    wr(1'b0, 8'h4D); wr(1'b0, 8'h1D); wr(1'b0, 8'h99); wr(1'b0, 8'h93);
    //---------------- 9. CRT-9 improper command
    ids = "CRT-9, [D79] 1-177, 1-180";
    status_is(8'h00, 8'h08, "a complete Reset");
    wr(1'b1, 8'h00); wr(1'b0, 8'h4D); wr(1'b0, 8'h1D); wr(1'b1, 8'h27);
    status_is(8'h08, 8'h08, "00h with 2 parameters, then 27h");
    status_is(8'h00, 8'h08, "the status read after IC");
    wr(1'b0, 8'h55);
    status_is(8'h08, 8'h08, "a parameter with none expected");
    status_is(8'h00, 8'h08, "the status read after IC");
    wr(1'b1, 8'h80); wr(1'b0, 8'h0A); wr(1'b1, 8'h27);
    status_is(8'h08, 8'h08, "80h with 1 parameter, then 27h");
    program(8'h4D, 8'h1D, 8'h99, 8'h93);
    status_is(8'h00, 8'h08, "a Reset with its 4 parameters");
    wr(1'b1, 8'h80); wr(1'b0, 8'h0A); wr(1'b0, 8'h05);
    status_is(8'h00, 8'h08, "80h with its 2 parameters");
    wr(1'b1, 8'h27);
    status_is(8'h00, 8'h08, "27h");
    //---------------- 11. CRT-11 light pen (before CRT-10: the same parameters)
    ids = "CRT-11, [D79] 1-165, 1-177, 1-179, 1-180";
    wait_ev(E_VF, 2 * FRAME, "light pen: VRTC fall", t0);
    rd(1'b0, v1);
    if (v1 !== 8'h00) begin $sformat(msg, "light pen: a parameter read without 60h %h, expected 00h (S1)", v1); err(msg); end
    status_is(8'h00, 8'h10, "before LPEN rise");
    nt = 0;
    while (tl != 7 * m_nl + 3) begin
        wait_ev(E_HF, 2 * LINE, "light pen: HRTC fall", t0); nt = nt + 1;
        if (nt > 200) begin $display("FATAL: vg75: light pen: row 7 timed out"); $finish; end
    end
    while (n16 < t0 + 305) @(negedge clk);
    lpen = 1'b1;
    status_is(8'h10, 8'h10, "after LPEN rise");
    status_is(8'h00, 8'h10, "the status read after LP");
    wr(1'b1, 8'h60); rd(1'b0, v1); rd(1'b0, v2); rd(1'b0, v3);
    if (v1 !== 8'd25) begin $sformat(msg, "light pen: character register %0d, expected 25 (the counter at LPEN rise, 305 ce16 after HRTC fall)", v1); err(msg); end
    if (v2 !== 8'd7) begin $sformat(msg, "light pen: row register %0d, expected 7", v2); err(msg); end
    if (v3 !== 8'h00) begin $sformat(msg, "light pen: a third parameter read %h, expected 00h (S1)", v3); err(msg); end
    nt = 0;
    while (tl != 9 * m_nl + 2) begin
        wait_ev(E_HF, 2 * LINE, "light pen: HRTC fall", t0); nt = nt + 1;
        if (nt > 200) begin $display("FATAL: vg75: light pen: row 9 timed out"); $finish; end
    end
    wait_n(500);
    lpen = 1'b0;
    status_is(8'h00, 8'h10, "after LPEN fall");
    wr(1'b1, 8'h60); rd(1'b0, v1); rd(1'b0, v2);
    if (v1 !== 8'd25 || v2 !== 8'd7) begin $sformat(msg, "light pen: the registers %0d, %0d after LPEN fall, expected 25, 7", v1, v2); err(msg); end
    //---------------- 10. CRT-10 Load Cursor: blinking underline at character 10, row 5 (frames of 70 lines)
    ids = "CRT-10, [D79] 1-179, CRT-36, S3";
    program(8'h0F, 8'h05, 8'h99, 8'h93); wr(1'b1, 8'h27);
    wr(1'b1, 8'h80); wr(1'b0, 8'h0A); wr(1'b0, 8'h05);
    wait_ev(E_VF, 2 * FRAME, "cursor: VRTC fall", t0);
    nf = 0; cur_first = 1'b1; cur_on = 1'b1;
    // until three blink changes (one on run and one off run between them), at most 26 frames
    p1 = -1; p2 = -1; p3 = -1;
    while (p3 < 0 && nf < 26) begin
        wait_ev(E_VF, 2 * SFRAME, "cursor: VRTC fall", t0);
        if (nf >= 2 && cur_hist[nf - 1] != cur_hist[nf - 2]) begin
            if (p1 < 0) p1 = nf - 1; else if (p2 < 0) p2 = nf - 1; else p3 = nf - 1;
        end
    end
    cur_on = 1'b0;
    if (p3 < 0) begin $sformat(msg, "cursor: fewer than 3 blink changes in %0d frames", nf); err(msg); end
    else begin
        if (p2 - p1 != 8) begin $sformat(msg, "cursor: a blink run of %0d frames, expected 8 (frame / 16, 50 %%)", p2 - p1); err(msg); end
        if (p3 - p2 != 8) begin $sformat(msg, "cursor: a blink run of %0d frames, expected 8 (frame / 16, 50 %%)", p3 - p2); err(msg); end
    end
    //---------------- 12. CRT-12 Preset Counters (S12, decided): held, then the last retrace row with the row 0 fill
    ids = "CRT-12, [D79] 1-179, S12";
    program(8'h4D, 8'h1D, 8'h99, 8'h93); wr(1'b1, 8'h27);
    wait_ev(E_VF, 2 * FRAME, "preset: VRTC fall", t0);
    wait_ev(E_VF, 2 * FRAME, "preset: VRTC fall", t0);
    pr = 1; pr_ctx = "after E0h";
    wr(1'b1, 8'hE0);
    wait_n(FRAME);
    // held until a command other than E0h ([D79] 1-179): a second E0h, a parameter write (IC, S16) and a status read
    // do not release; each followed by two lines of the held checks
    pr_ctx = "after a second E0h"; pr_e = 4'd0;
    wr(1'b1, 8'hE0); wait_n(2 * LINE);
    pr_ctx = "after a parameter write"; pr_e = 4'd0;
    wr(1'b0, 8'h55); wait_n(2 * LINE);
    pr_ctx = "after a status read"; pr_e = 4'd0;
    status_is(8'h08, 8'h08, "preset: held: the parameter write (S16)"); wait_n(2 * LINE);
    wait_n(2 * FRAME - 6 * LINE);
    img_restart = 1'b1;
    wr(1'b1, 8'h80); wr(1'b0, 8'h00); wr(1'b0, 8'h00);
    resume_chk("preset", 1'b1);
    //---------------- 12b. Preset Counters with an underrun pending (C1, decided 2026-11-10: the preset clears the
    // underrun's DMA stop, its first DMA is the row 0 fill; the board's tape I/O leaves an underrun, then 27h, E0h)
    ids = "CRT-12, [D79] 1-179, 1-180, S11, S12";
    wait_ev(E_VF, 2 * FRAME, "preset: VRTC fall", t0);
    dma_off = 1'b1;                                     // the stand-in stops answering: the row 1 fill stalls
    wait_n(3 * 10 * LINE);
    status_is(8'h02, 8'h02, "preset after an underrun: before 27h, E0h");
    wr(1'b1, 8'h27);
    pr = 1; pr_ctx = "after E0h, an underrun pending"; pr_e = 4'd0;
    hr_res = -1; drq_res = -1; vf_res = -1; vr_res = -1; cc_chk = 1'b0;
    wr(1'b1, 8'hE0);
    dma_off = 1'b0;
    wait_n(FRAME);
    img_restart = 1'b1;
    wr(1'b1, 8'h80); wr(1'b0, 8'h00); wr(1'b0, 8'h00);
    resume_chk("preset after an underrun", 1'b0);
    //---------------- 13. CRT-13 (the monitor, the whole run)
    if (errors == 0) $display("PASS: vg75 (%0d ce16)", n16);
    $finish;
end
endmodule
`default_nettype wire
