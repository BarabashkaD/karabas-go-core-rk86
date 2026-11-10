// k580vg75, the DMA side, against the Intel 8275 data sheet ([D79] 1979 00224A; Task 2 CRT-20..28, Task 9): the DMA
// of a frame, bursts and the burst space, DRQ per DMA write, the byte at WR rise, buffer full, underrun, the special
// codes, transparent field attributes with the FIFOs, non-transparent field attributes.
// Harness of tb_vg75.v (Task 8): the ce16 cadence of tb_clocks16.v (64 / 297 of clk); cclk = one clk at every 12th
// ce16 (CCLK falling edge); the CPU bus tasks (CS, RD, WR held 4 clk); the raster model from the pins (lines counted
// from a VRTC fall, characters from an HRTC fall); the error cap and bounded waits. The DMA stand-in answers DRQ: DACK
// low 20 ce16 after it sees DRQ high, WR low 4 ce16 later for 23 ce16, WR and DACK high at the same clk. Its byte is
// the one of the memory image of the check at row t, transfer k: t the row being filled (row r + 1 during row r, row 0
// during the last retrace row, from the HRTC rises that start the rows), k the transfers of that fill so far.
// Every DRQ edge, DMA WR fall / rise and byte is recorded (printed with +dmalog). A row fill window runs from the HRTC
// rise that starts a row to the next one; per window the TB counts the transfers, the DRQ rises, the bursts (a DRQ
// rise more than 2 clk after the last WR rise starts a new burst) and the burst spaces (ce16 from the last WR rise of
// a burst to the next DRQ rise). Expected values come from the parameters the TB wrote, the image it serves and the
// pin timing; flags from status reads (CS, A0, RD pulses).
// The checks run in the order 1, 4, 3, 2, 6, 7, 8, 9, 5: a byte taken at WR fall also keeps DRQ high through the
// burst and counts the burst space from WR fall, so the byte check comes before the DRQ and burst checks; check 5
// changes the line length (a raster resync), so it comes last.
`default_nettype none
`timescale 1ns/1ns
`define WAIT_UNTIL(COND, LIM, WHAT) begin tw0 = n16; while (!(COND)) begin @(negedge clk); if (n16 > tw0 + (LIM)) begin $display("FATAL: vg75_dma: %0s timed out", WHAT); $finish; end end end
module tb_vg75_dma;
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
reg [3:0] step = 4'd0;
always @(posedge clk) if (ce16) step <= step == 4'd11 ? 4'd0 : step + 4'd1;
wire cclk = ce16 && step == 4'd11;
reg cs_n = 1'b1, rd_n = 1'b1, cpu_wr_n = 1'b1, a0 = 1'b0, cpu_busy = 1'b0;
reg [7:0] cpu_d = 8'h00;
reg dma_wr_n = 1'b1, dack_n = 1'b1, stray_on = 1'b0;   // stray_on: the stand-in drives a WR with DACK and CS high
reg [7:0] dma_d = 8'h00;
wire wr_n = cpu_wr_n & dma_wr_n;
wire [7:0] d_i = (!dack_n || stray_on) ? dma_d : cpu_d;
wire [7:0] d_o;
wire drq, irq, hrtc, vrtc, vsp, lten, rvv, hglt;
wire [6:0] cc;
wire [3:0] lc;
wire [1:0] la, gpa;
k580vg75 dut(.clk(clk), .cclk(cclk), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .a0(a0), .d_i(d_i), .d_o(d_o),
    .drq(drq), .dack_n(dack_n), .irq(irq), .lpen(1'b0), .hrtc(hrtc), .vrtc(vrtc), .cc(cc), .lc(lc), .la(la),
    .vsp(vsp), .lten(lten), .rvv(rvv), .hglt(hglt), .gpa(gpa));
localparam integer LINE = 1032, ROW = 10320, FRAME = 319920;    // 4Dh 1Dh 99h 93h: 86 CCLK per line, 10 lines, 31 rows
// the memory images: 0 the plain screen (row r, column c: 20h + (r + c) mod 64), 1 the byte timing variants (CRT-23),
// 2 the special codes (CRT-26), 3 transparent field attributes (CRT-27), 4 non-transparent field attributes (CRT-28)
localparam integer IM_NORM = 0, IM_BYTE = 1, IM_SPEC = 2, IM_FIFO = 3, IM_NT = 4;
//---------------- messages: ERROR: vg75: <what> (<ID>, [D79] <page>)
integer n16 = 0, nclk = 0, st_q = 0, errors = 0, tw0 = 0;
reg [8*200-1:0] msg;
reg [8*56-1:0] ids = "CRT-20, [D79] 1-172 Fig. 18, [D84] 8-60";
reg dlog = 1'b0;
task err(input [8*200-1:0] what); begin
    $display("ERROR: vg75: %0s (%0s) at ce16 %0d", what, ids, n16); errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: vg75_dma: too many errors"); $finish; end
end endtask
//---------------- the raster model: tl the line since the VRTC fall (-1 until the first HRTC fall), tc the character
// since the HRTC fall, ri the row whose start was the last row-start HRTC rise (0 at the VRTC fall)
integer tl = -1, tc = 0, ri = 0, hf_t = 0, vr_t = 0;
reg synced = 1'b0, vf_seen = 1'b0;     // in step from the second VRTC fall after new lengths (the first may end a
                                        // retrace that began under the old ones)
integer m_nh = 1, m_nr = 1, m_nv = 1, m_nl = 1, m_u = 0, m_z = 0;
reg m_sp = 1'b0;
// a row whose start begins a fill ([D79] 1-168, 1-172 Fig. 18): the last retrace row (row 0), or the row before a
// display row that is not blanked by spaced rows
function due(input integer r);
    due = r == m_nr + m_nv - 1 || (r + 1 < m_nr && !(m_sp && (r + 1) % 2 == 1));
endfunction
//---------------- the images
integer img_mode = IM_NORM, img_next = IM_NORM;     // img_next takes effect at the row 29 start (no fill in row 29)
function [7:0] nbyte(input integer r, input integer k);
    nbyte = 8'h20 + (r + k) % 64;
endfunction
// the byte of image m at row t, transfer k
function [7:0] mem(input integer m, input integer t, input integer k);
    begin
        mem = nbyte(t, k);
        case (m)
            IM_SPEC: if ((t == 1 || t == 3) && k == 10) mem = 8'hF0;              // End of Row
                     else if (t == 3 && k == 20) mem = 8'hF2;                     // End of Screen, later in that row
                     else if (t == 5 && k == 10) mem = 8'hF1;                     // End of Row-Stop DMA, mid-burst
                     else if (t == 7 && k == 15) mem = 8'hF1;                     // the last byte of a burst
                     else if (t == 9 && k == 10) mem = 8'hF3;                     // End of Screen-Stop DMA
            IM_FIFO: if (t == 2 && k == 1) mem = 8'hA0;                           // A, A0h (U), B, C ...
                     else if (t == 4 && k == 1) mem = 8'h90;                      // A, 90h (R), B, C ...
                     else if (t == 6 && k < 32 && k % 2 == 0) mem = 8'h90;        // 16 field attributes: FO stays 0
                     else if (t == 8 && k < 34 && k % 2 == 0) mem = 8'h90;        // 17 field attributes: FO
                     else if (t == 10 && k == 10) mem = 8'hF0;                    // End of Row, then 80h: ignored
                     else if (t == 10 && k == 12) mem = 8'h80;
            IM_NT:   if (t == 2 && k == 1) mem = 8'hA0;
                     else if (t == 4 && k == 1) mem = 8'h90;
            default: ;
        endcase
    end
endfunction
// the transfers of the fill of row t (the brief's values): Stop DMA after the next byte when not the last of a burst
// (8 per burst), 79 with one transparent field attribute (its FIFO byte), 78 + 17 with 17
function integer e_fill(input integer m, input integer t);
    begin
        e_fill = m_nh;
        case (m)
            IM_SPEC: if (t == 5 || t == 9) e_fill = 12; else if (t == 7) e_fill = 16; else if (t >= 10 && t < m_nr) e_fill = 0;
            IM_FIFO: if (t == 2 || t == 4 || t == 10) e_fill = m_nh + 1; else if (t == 6) e_fill = m_nh + 16;
                     else if (t == 8) e_fill = m_nh + 17;
            default: ;
        endcase
    end
endfunction
// the display of image m at row r, line ln, character c: {checked: CC (line 0), VSP, LTEN, RVV; CC, VSP, LTEN, RVV}
function [13:0] exp_out(input integer m, input integer r, input integer ln, input integer c);
    reg [6:0] e_cc;
    reg e_v, e_l, e_r, k_cc, k_v, k_l, k_r;
    integer p;
    begin
        p = r * m_nh + c;
        e_cc = nbyte(r, c); e_v = m_u >= 8 && (ln == 0 || ln == m_nl - 1); e_l = 1'b0; e_r = 1'b0;
        k_cc = 1'b1; k_v = 1'b1; k_l = 1'b0; k_r = 1'b0;          // CC on every line (the FIFO characters too)
        case (m)
            IM_NORM: begin k_l = p != 0; k_r = p != 0; end                    // no attributes: LTEN, RVV low
            IM_BYTE: begin                                                     // odd rows: the right byte only before WR fall
                if (r % 2 == 1) e_cc = e_cc ^ 7'h01;
                k_l = p != 0; k_r = p != 0;
            end
            IM_SPEC: if ((r == 1 && c >= 10) || (r == 3 && (ln > 0 || c >= 10)) || r > 3) begin e_v = 1'b1; k_cc = 1'b0; end
            IM_FIFO: begin                                                    // the cursor at row 0 char 0: no LTEN / RVV
                k_l = p != 0; k_r = p != 0;
                if (r == 2 || r == 4) e_cc = c == 0 ? nbyte(r, 0) : c == 1 ? nbyte(r, 2) : nbyte(r, c + 1);
                if (r == 6) e_cc = c < 16 ? nbyte(6, 2 * c + 1) : nbyte(6, c + 16);              // 16 FIFO characters
                // FIFO overrun: the 17th character overwrote the first ([D79] 1-176 "the first characters in the FIFO
                // are written over and lost"): position 0 shows character 17, 1-15 characters 2-16; 16 open (wrap)
                if (r == 8) begin
                    if (c == 0) e_cc = nbyte(8, 33); else if (c < 16) e_cc = nbyte(8, 2 * c + 1);
                    else if (c == 16) k_cc = 1'b0; else e_cc = nbyte(8, c + 17);
                end
                if (r == 10 && c >= 10) begin e_v = 1'b1; k_cc = 1'b0; k_l = 1'b0; k_r = 1'b0; end  // End of Row
                e_l = ln == m_u && p >= 2 * m_nh + 1 && p < 4 * m_nh + 1;
                e_r = p >= 4 * m_nh + 1;
            end
            IM_NT: begin
                k_l = p != 0; k_r = p != 0;
                // the attribute position: blank (VSP), its own attributes not yet active ([D79] 1-176 Fig. 22): no
                // LTEN at A0h (no field before it), no RVV at 90h; CC (S7) and LTEN at 90h (the U field before) open
                if ((r == 2 || r == 4) && c == 1) begin e_v = 1'b1; k_cc = 1'b0; k_l = r == 2; end
                e_l = ln == m_u && p >= 2 * m_nh + 2 && p < 4 * m_nh + 1;
                e_r = p >= 4 * m_nh + 2;
            end
            default: ;
        endcase
        exp_out = {k_cc, k_v, k_l, k_r, e_cc, e_v, e_l, e_r};
    end
endfunction
//---------------- the row fill window
reg w_open = 1'b0, w_due = 1'b0, w_ba = 1'b0, w_c3 = 1'b0, w_fw = 1'b0;
integer w_row = 0, w_tgt = 0, w_e = 0, w_mode = 0, w_t0 = 0, w_tr = 0, w_drq = 0, w_drq1 = -1, w_late = 0;
integer runs [0:127];
integer spc [0:127];
integer n_runs = 0, cur_run = 0, wu_obs = 0, wu_st = 0;
// Start Display: burst count and space (CCLK) in force
integer cur_bc = 8, cur_s = 7;
// burst analysis (checks 2, 5)
integer ba_left = 0, ba_n = 0;
reg [8*32-1:0] ba_cfg = "BB = 11, SSS = 001", ba_tl = "burst length", ba_ts = "burst space";
// DRQ per WR (check 3)
integer c3_left = 0, c3_n = 0, n3_wf = 0, n3_low = 0, n3_rise = 0, c3_k = 0, d_wf_obs = 0, r3_t = 0, r3_k = 0;
reg in_dma = 1'b0, c3_e = 1'b0, r3_pend = 1'b0, r3_seen = 1'b0;
// frame windows: armed by the TB, on from the next VRTC fall for fw_nfr frames
reg fw_arm = 1'b0, fw_on = 1'b0, fw_done = 1'b0, fw_disp = 1'b0, fw_cnt = 1'b0, fw_first = 1'b0, fw_inf = 1'b0;
integer fw_rmin = 0, fw_nfr = 1, fw_k = 0, fw_mode = 0, fw_nw = 0, fw_ninf = 0, n_cc = 0, n_vsp = 0, n_lt = 0, n_rv = 0;
integer n_stray = 0, fw_xstray = 0;    // WR pulses with DACK and CS high seen in the frame; fills that drive one
reg [8*24-1:0] t_cnt = "frame dma", t_disp = "frame dma";
// underrun (check 6)
reg u_arm = 1'b0, u_stop = 1'b0;
integer u_phase = 0, u_drq = 0, u_nv = 0, u_ve = 0;
integer t_ref, row, line;
reg [13:0] ex;
task open_window(input integer r); begin
    w_open = 1'b1; w_row = r; w_t0 = st_q; w_tr = 0; w_drq = 0; w_drq1 = -1; w_late = 0; n_runs = 0; cur_run = 0;
    w_due = due(r); w_tgt = r == m_nr + m_nv - 1 ? 0 : r + 1; w_mode = img_mode;
    w_e = w_due ? e_fill(img_mode, w_tgt) : 0;
    w_ba = ba_left > 0 && w_due; if (w_ba) ba_left = ba_left - 1;
    w_c3 = c3_left > 0 && w_due; if (w_c3) c3_left = c3_left - 1;
    w_fw = fw_on && fw_cnt;
end endtask
// the bursts of a fill against BB and SSS: lengths BC (the last one the rest), spaces in ((S - 1) x 12, S x 12] ce16;
// S = 0: every DRQ within 2 clk of the WR rise; no DRQ after the last transfer
task ba_eval;
    integer b, en, el, ol, lo, hi, nb;
    reg ok;
    begin
        ba_n = ba_n + 1;
        nb = n_runs;
        if (cur_run > 0) begin runs[n_runs] = cur_run; nb = n_runs + 1; end
        ok = 1'b1;
        if (cur_s == 0) begin
            if (nb > 1) begin
                $sformat(msg, "%0s: %0s: row %0d fill: DRQ %0d ce16 after the WR rise of transfer %0d, expected within 2 clk (as within a burst)",
                    ba_ts, ba_cfg, w_tgt, spc[0], runs[0] - 1);
                err(msg);
            end else if (w_tr != w_e) begin
                $sformat(msg, "%0s: %0s: row %0d fill: %0d transfers, expected %0d", ba_tl, ba_cfg, w_tgt, w_tr, w_e); err(msg);
            end
        end else begin
            en = (w_e + cur_bc - 1) / cur_bc;
            for (b = 0; ok && b < (nb > en ? nb : en); b = b + 1) begin
                el = b < en - 1 ? cur_bc : b == en - 1 ? w_e - cur_bc * (en - 1) : 0;
                ol = b < nb ? runs[b] : 0;
                if (ol != el) begin
                    ok = 1'b0;
                    $sformat(msg, "%0s: %0s: row %0d fill: burst %0d has %0d transfers, expected %0d", ba_tl, ba_cfg, w_tgt, b, ol, el);
                    err(msg);
                end
            end
            lo = (cur_s - 1) * 12 + 1; hi = cur_s * 12;
            for (b = 0; ok && b < nb - 1; b = b + 1)
                if (spc[b] < lo || spc[b] > hi) begin
                    ok = 1'b0;
                    $sformat(msg, "%0s: %0s: row %0d fill: DRQ %0d ce16 after the last WR rise of burst %0d, expected %0d..%0d",
                        ba_ts, ba_cfg, w_tgt, spc[b], b, lo, hi);
                    err(msg);
                end
        end
        if (w_late != 0) begin
            $sformat(msg, "%0s: %0s: row %0d fill: %0d DRQ rises after transfer %0d, expected none until the next row start",
                ba_tl, ba_cfg, w_tgt, w_late, w_e);
            err(msg);
        end
    end
endtask
task close_window; begin
    if (w_fw) begin
        fw_nw = fw_nw + 1;
        if (w_mode == IM_BYTE && w_e > 3) fw_xstray = fw_xstray + 1;
        if (w_tr != w_e) begin
            if (w_due) $sformat(msg, "%0s: during row %0d (the row %0d fill): %0d transfers, expected %0d", t_cnt, w_row, w_tgt, w_tr, w_e);
            else $sformat(msg, "%0s: during row %0d (no fill due): %0d transfers, expected 0", t_cnt, w_row, w_tr);
            err(msg);
        end
        if (w_late != 0) begin
            $sformat(msg, "%0s: during row %0d: %0d DRQ rises after transfer %0d, expected none", t_cnt, w_row, w_late, w_e); err(msg);
        end
        if (fw_first && w_e > 0) begin
            t_ref = w_row == m_nr + m_nv - 1 ? vr_t : w_t0;
            if (w_drq1 < 0 || w_drq1 - t_ref > cur_s * 12) begin
                $sformat(msg, "%0s: the row %0d fill: the first DRQ %0d ce16 after the %0s, expected 0..%0d (one burst space)", t_cnt,
                    w_tgt, w_drq1 < 0 ? -1 : w_drq1 - t_ref, w_row == m_nr + m_nv - 1 ? "VRTC rise" : "row start", cur_s * 12);
                err(msg);
            end else if (w_row == m_nr + m_nv - 1 && fw_inf) begin
                $display("INFO: vg75: first DRQ of a frame %0d ce16 after the VRTC rise", w_drq1 - vr_t); fw_ninf = fw_ninf + 1;
            end
        end
    end
    if (w_ba) ba_eval;
    if (w_c3) c3_n = c3_n + 1;
    if (u_phase == 2 && w_row == 0) begin                 // the first DRQ after the underrun: the row 1 fill at the VRTC fall
        if (w_drq1 < 0 || w_drq1 - w_t0 > cur_s * 12) begin
            $sformat(msg, "underrun: the first DRQ %0d ce16 after the VRTC fall, expected 0..%0d (the row 1 fill)",
                w_drq1 < 0 ? -1 : w_drq1 - w_t0, cur_s * 12);
            err(msg);
        end
        u_phase = 0;
    end
end endtask
task fw_reset; begin
    fw_nw = 0; fw_ninf = 0; n_cc = 0; n_vsp = 0; n_lt = 0; n_rv = 0; n_stray = 0; fw_xstray = 0;
end endtask
// the counts of a frame of a frame window: every row fill, every checked display position
task frame_counts;
    integer r, ln, c, xc, xv, xl, xr;
    reg [13:0] e;
    begin
        if (n_stray != fw_xstray) begin
            $sformat(msg, "%0s: %0d WR pulses with DACK and CS high in the frame, expected %0d (one per fill)", t_cnt, n_stray, fw_xstray);
            err(msg);
        end
        if (fw_cnt && fw_nw != m_nr + m_nv) begin
            $sformat(msg, "%0s: %0d row fills checked in the frame, expected %0d", t_cnt, fw_nw, m_nr + m_nv); err(msg);
        end
        if (fw_first && fw_inf && fw_ninf != 1) begin
            $sformat(msg, "%0s: %0d first DMA of the frame seen, expected 1", t_cnt, fw_ninf); err(msg);
        end
        if (fw_disp) begin
            xc = 0; xv = 0; xl = 0; xr = 0;
            for (r = fw_rmin; r < m_nr; r = r + 1)
                for (ln = 0; ln < m_nl; ln = ln + 1)
                    for (c = 0; c < m_nh; c = c + 1) begin
                        e = exp_out(fw_mode, r, ln, c); xc = xc + e[13]; xv = xv + e[12]; xl = xl + e[11]; xr = xr + e[10];
                    end
            if (n_cc != xc || n_vsp != xv || n_lt != xl || n_rv != xr) begin
                $sformat(msg, "%0s: display samples CC %0d, VSP %0d, LTEN %0d, RVV %0d in the frame, expected %0d, %0d, %0d, %0d",
                    t_disp, n_cc, n_vsp, n_lt, n_rv, xc, xv, xl, xr);
                err(msg);
            end
        end
    end
endtask
task frame_edge; begin
    if (fw_on) begin
        frame_counts;
        fw_k = fw_k + 1;
        if (fw_k >= fw_nfr) begin fw_on = 1'b0; fw_done = 1'b1; end
        else begin fw_rmin = 0; fw_reset; fw_mode = img_mode; end
    end
    if (u_phase == 1) begin                                // the end of the vertical retrace after the underrun
        if (u_drq != 0) begin
            $sformat(msg, "underrun: %0d DRQ rises from the row 6 start to the VRTC fall, expected 0 (DMA stopped until after the vertical retrace)", u_drq);
            err(msg);
        end
        if (u_nv != (m_nr + m_nv - 6) * m_nl * (m_nh + 2 * (m_z + 1))) begin
            $sformat(msg, "underrun: %0d CCLK falls checked from the row 6 start to the VRTC fall, expected %0d", u_nv,
                (m_nr + m_nv - 6) * m_nl * (m_nh + 2 * (m_z + 1)));
            err(msg);
        end
        u_phase = 2; fw_arm = 1'b1;
    end
    if (fw_arm) begin fw_arm = 1'b0; fw_on = 1'b1; fw_k = 0; fw_reset; fw_mode = img_mode; end
end endtask
//---------------- the monitor and the DMA stand-in
reg cclk_q = 1'b0, hrtc_q = 1'b0, vrtc_q = 1'b0, drq_q = 1'b0, dwr_q = 1'b1;
reg [7:0] di_q = 8'h00;
reg hr_ev, hf_ev, vr_ev, vf_ev, rs_ev, dr_ev, df_ev, wf_ev, wu_ev;
integer dst = 0, dcnt = 0, s_k = 0;
reg s_late = 1'b0, s_early = 1'b0, s_stray = 1'b0;
reg [7:0] s_b = 8'h00;
always @(posedge clk) begin
    hr_ev = hrtc === 1'b1 && hrtc_q === 1'b0;
    hf_ev = hrtc === 1'b0 && hrtc_q === 1'b1;
    vr_ev = vrtc === 1'b1 && vrtc_q === 1'b0;
    vf_ev = vrtc === 1'b0 && vrtc_q === 1'b1;
    dr_ev = drq === 1'b1 && drq_q === 1'b0;
    df_ev = drq === 1'b0 && drq_q === 1'b1;
    wf_ev = dma_wr_n === 1'b0 && dwr_q === 1'b1;
    wu_ev = dma_wr_n === 1'b1 && dwr_q === 1'b0;
    if (dlog) begin
        if (dr_ev) $display("DMA: ce16 %0d: DRQ rise", st_q);
        if (df_ev) $display("DMA: ce16 %0d: DRQ fall", st_q);
        if (wf_ev) $display("DMA: ce16 %0d: WR fall%0s, byte %h", st_q, dack_n ? " (DACK high, CS high)" : "", d_i);
        if (wu_ev) $display("DMA: ce16 %0d: WR rise, byte %h", st_q, di_q);
    end
    // the raster model
    if (vr_ev) vr_t = st_q;
    if (hf_ev) begin tl = tl + 1; tc = 0; hf_t = st_q; end
    else if (cclk_q) tc = tc + 1;
    if (vf_ev) begin tl = -1; ri = 0; if (vf_seen) synced = 1'b1; vf_seen = 1'b1; end
    else if (hr_ev && synced && (tl + 1) % m_nl == 0) ri = (tl + 1) / m_nl;
    rs_ev = hr_ev && synced && (tl + 1) % m_nl == 0;
    // a row start: the window of the last row closes, the next one opens
    if (rs_ev) begin
        if (w_open) close_window;
        if (vf_ev) frame_edge;
        if (ri == m_nr - 1) img_mode = img_next;
        open_window(ri);
        if (ri == 6 && u_stop) begin u_stop = 1'b0; u_arm = 1'b0; u_phase = 1; u_drq = 0; u_nv = 0; u_ve = 0; end
    end
    // DRQ rises: the first of the window, after the last transfer, the burst boundaries
    if (dr_ev && w_open) begin
        w_drq = w_drq + 1;
        if (w_drq1 < 0) w_drq1 = st_q;
        if (w_tr >= w_e) w_late = w_late + 1;
        if (w_tr > 0 && nclk - wu_obs > 2 && n_runs < 127) begin
            runs[n_runs] = cur_run; spc[n_runs] = st_q - wu_st; n_runs = n_runs + 1; cur_run = 0;
        end
    end
    if (dr_ev && u_phase == 1) u_drq = u_drq + 1;
    // DMA WR (with DACK): CRT-22 DRQ low from WR fall + 2 clk to WR rise, high again within 2 clk of WR rise
    if (wf_ev && dack_n === 1'b1 && cs_n === 1'b1 && fw_on) n_stray = n_stray + 1;
    if (wf_ev && dack_n === 1'b0) begin
        in_dma = 1'b1; d_wf_obs = nclk;
        if (w_c3) begin n3_wf = n3_wf + 1; c3_k = w_tr; c3_e = 1'b0; end
    end
    if (in_dma && w_c3 && nclk >= d_wf_obs + 2) begin
        n3_low = n3_low + 1;
        if (drq !== 1'b0 && !c3_e) begin
            c3_e = 1'b1;
            $sformat(msg, "drq at wr: row %0d fill transfer %0d: DRQ high %0d clk after the DMA WR fall, expected low from WR fall + 2 clk to WR rise",
                w_tgt, c3_k, nclk - d_wf_obs);
            err(msg);
        end
    end
    if (wu_ev && in_dma) begin
        in_dma = 1'b0; w_tr = w_tr + 1; cur_run = cur_run + 1; wu_obs = nclk; wu_st = st_q;
        if (w_c3 && (c3_k + 1) % cur_bc != 0 && c3_k + 1 != w_e) begin r3_pend = 1'b1; r3_t = nclk; r3_seen = 1'b0; r3_k = c3_k; n3_rise = n3_rise + 1; end
    end
    if (r3_pend && nclk > r3_t) begin
        if (drq === 1'b1) r3_seen = 1'b1;
        if (nclk >= r3_t + 2) begin
            r3_pend = 1'b0;
            if (!r3_seen) begin
                $sformat(msg, "drq at wr: row %0d fill transfer %0d: DRQ not high within 2 clk of the DMA WR rise, expected high (characters left in the burst)",
                    w_tgt, r3_k);
                err(msg);
            end
        end
    end
    // the display positions of a frame window: the outputs of character tc of line tl
    if (cclk_q && synced && fw_on && fw_disp && tl >= 0 && tl < m_nr * m_nl && tc < m_nh) begin
        row = tl / m_nl; line = tl % m_nl;
        if (row >= fw_rmin) begin
            ex = exp_out(fw_mode, row, line, tc);
            if (ex[13]) begin
                n_cc = n_cc + 1;
                if (cc !== ex[9:3]) begin $sformat(msg, "%0s: row %0d line %0d char %0d: CC %h, expected %h", t_disp, row, line, tc, cc, ex[9:3]); err(msg); end
            end
            if (ex[12]) begin
                n_vsp = n_vsp + 1;
                if (vsp !== ex[2]) begin $sformat(msg, "%0s: row %0d line %0d char %0d: VSP %b, expected %b", t_disp, row, line, tc, vsp, ex[2]); err(msg); end
            end
            if (ex[11]) begin
                n_lt = n_lt + 1;
                if (lten !== ex[1]) begin $sformat(msg, "%0s: row %0d line %0d char %0d: LTEN %b, expected %b", t_disp, row, line, tc, lten, ex[1]); err(msg); end
            end
            if (ex[10]) begin
                n_rv = n_rv + 1;
                if (rvv !== ex[0]) begin $sformat(msg, "%0s: row %0d line %0d char %0d: RVV %b, expected %b", t_disp, row, line, tc, rvv, ex[0]); err(msg); end
            end
        end
    end
    // after the underrun: VSP high at every CCLK fall from the row 6 start to the VRTC fall
    if (u_phase == 1 && cclk_q) begin
        u_nv = u_nv + 1;
        if (vsp !== 1'b1 && u_ve < 4) begin
            u_ve = u_ve + 1;
            $sformat(msg, "underrun: VSP low at line %0d char %0d, expected high from the row 6 start to the VRTC fall", tl, tc); err(msg);
        end
    end
    hrtc_q = hrtc; vrtc_q = vrtc; drq_q = drq; dwr_q = dma_wr_n; cclk_q = cclk; di_q = d_i;
    //---------------- the DMA stand-in
    if (ce16) begin
        case (dst)
            0: if (drq === 1'b1 && !u_stop) begin
                if (u_arm && w_open && w_row == 5 && w_tr >= 3) u_stop = 1'b1;   // stops answering in the row 6 fill
                else begin dst = 1; dcnt = 0; end
            end
            1: begin
                dcnt = dcnt + 1;
                if (dcnt >= 20 && !cpu_busy) begin
                    if (drq === 1'b1 && !u_stop) begin
                        s_k = w_tr; s_b = w_open ? mem(w_mode, w_tgt, s_k) : nbyte(0, s_k);
                        s_late = w_open && w_mode == IM_BYTE && w_tgt % 2 == 0;      // the right byte only in the last ce16
                        // the right byte only before WR fall (the wrong one from the WR fall clk on): this catches a
                        // model that latches before WR fall (at DACK fall); one that latches at WR fall shows the wrong
                        // byte here as expected, so only the even rows catch a WR fall latch
                        s_early = w_open && w_mode == IM_BYTE && w_tgt % 2 == 1;
                        s_stray = w_open && w_mode == IM_BYTE && s_k == 3;           // then a WR with DACK and CS high
                        dack_n <= 1'b0; dma_d <= s_late ? s_b ^ 8'h01 : s_b; dst = 2; dcnt = 0;
                    end else dst = 0;
                end
            end
            2: begin
                dcnt = dcnt + 1;
                if (dcnt == 4) begin dma_wr_n <= 1'b0; if (s_early) dma_d <= s_b ^ 8'h01; dst = 3; dcnt = 0; end
            end
            3: begin
                dcnt = dcnt + 1;
                if (dcnt == 22 && s_late) dma_d <= s_b;
                if (dcnt == 23) begin dma_wr_n <= 1'b1; dack_n <= 1'b1; dcnt = 0; dst = s_stray ? 4 : 0; end
            end
            default: begin
                dcnt = dcnt + 1;
                if (dcnt == 2 && !cpu_busy) begin stray_on <= 1'b1; dma_d <= 8'h7E; dma_wr_n <= 1'b0; end
                if (dcnt == 6) dma_wr_n <= 1'b1;
                if (dcnt == 7) begin stray_on <= 1'b0; dst = 0; end
            end
        endcase
    end
    st_q = n16; if (ce16) n16 = n16 + 1;
    nclk = nclk + 1;
end
//---------------- CPU bus (the bus is free of the stand-in: DACK and its WR high)
reg [7:0] sv;
integer nb;
task bus_free; begin
    @(negedge clk); nb = 0;
    while (!dack_n || !dma_wr_n) begin
        @(negedge clk); nb = nb + 1;
        if (nb > 2000) begin $display("FATAL: vg75_dma: bus: the DMA stand-in holds the bus timed out"); $finish; end
    end
    cpu_busy = 1'b1;
end endtask
task wr(input a, input [7:0] dd); begin
    bus_free;
    cs_n = 1'b0; a0 = a; cpu_d = dd;
    @(negedge clk) cpu_wr_n = 1'b0;
    repeat (4) @(negedge clk);
    cpu_wr_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
    cpu_busy = 1'b0;
end endtask
task rd(input a, output [7:0] dd); begin
    bus_free;
    cs_n = 1'b0; a0 = a;
    @(negedge clk) rd_n = 1'b0;
    repeat (4) @(negedge clk); dd = d_o; rd_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
    cpu_busy = 1'b0;
end endtask
function [8*3-1:0] fname(input integer b);
    case (b)
        7: fname = "0"; 6: fname = "IE"; 5: fname = "IR"; 4: fname = "LP"; 3: fname = "IC"; 2: fname = "VE";
        1: fname = "DU"; default: fname = "FO";
    endcase
endfunction
// a status read (A0 = 1): the bits of mask m against e, one message per bit
task stat_chk(input [7:0] e, input [7:0] m, input [8*24-1:0] topic, input [8*64-1:0] where);
    integer b;
    begin
        rd(1'b1, sv);
        for (b = 7; b >= 0; b = b - 1)
            if (m[b] && sv[b] !== e[b]) begin
                $sformat(msg, "%0s: %0s: status bit %0d (%0s) %b, expected %b", topic, where, b, fname(b), sv[b], e[b]);
                err(msg);
            end
    end
endtask
task wait_n(input integer n);
    integer tlim;
    begin tlim = n16 + n; while (n16 < tlim) @(negedge clk); end
endtask
// Reset with its four parameters; the raster model stays in step when the lengths are those already running (the
// counters keep running through Reset), else it resyncs at the next VRTC fall
task program(input [7:0] p1, input [7:0] p2, input [7:0] p3, input [7:0] p4);
    reg same;
    begin
        wr(1'b1, 8'h00); wr(1'b0, p1); wr(1'b0, p2); wr(1'b0, p3); wr(1'b0, p4);
        same = m_sp == p1[7] && m_nh == p1[6:0] + 1 && m_nv == p2[7:6] + 1 && m_nr == p2[5:0] + 1
            && m_nl == p3[3:0] + 1 && m_z == p4[3:0];
        m_sp = p1[7]; m_nh = p1[6:0] + 1; m_nv = p2[7:6] + 1; m_nr = p2[5:0] + 1;
        m_u = p3[7:4]; m_nl = p3[3:0] + 1; m_z = p4[3:0];
        if (!same) begin synced = 1'b0; vf_seen = 1'b0; w_open = 1'b0; end
    end
endtask
task start_display(input [2:0] sss, input [1:0] bb); begin
    wr(1'b1, {3'b001, sss, bb});
    cur_bc = 1 << bb; cur_s = sss == 3'd0 ? 0 : 8 * sss - 1;
end endtask
// a burst configuration (CRT-21): Start Display with BB, SSS, then two row fills that begin after it
task burst_cfg(input [1:0] bb, input [2:0] sss); begin
    start_display(sss, bb);
    $sformat(ba_cfg, "BB = %b, SSS = %b", bb, sss);
    ba_n = 0; ba_left = 2;
    `WAIT_UNTIL(ba_n == 2, 4 * ROW, "burst: two row fills")
end endtask
task use_image(input integer m); begin
    img_next = m;
    `WAIT_UNTIL(img_mode == m, 2 * FRAME, "image: the switch at the row 29 start")
end endtask
task frame_window; begin
    fw_done = 1'b0; fw_arm = 1'b1;
    `WAIT_UNTIL(fw_done, (fw_nfr + 2) * FRAME, "frame window")
end endtask
initial begin
    wait (n16 >= 9000000); $display("FATAL: vg75_dma: run timed out"); $finish;
end
initial begin
    if ($test$plusargs("dmalog")) dlog = 1'b1;
    wait_n(240);
    program(8'h4D, 8'h1D, 8'h99, 8'h93); start_display(3'b001, 2'b11);
    //---------------- 1. CRT-20 the DMA of a frame: the first fill (row 0) at the VRTC rise, row r + 1 during row r
    ids = "CRT-20, [D79] 1-172 Fig. 18, [D84] 8-60";
    t_cnt = "frame dma"; fw_disp = 1'b0; fw_cnt = 1'b1; fw_first = 1'b1; fw_inf = 1'b1; fw_rmin = 0; fw_nfr = 1;
    frame_window;
    stat_chk(8'h00, 8'h03, "frame dma", "after a frame of complete fills");
    //---------------- 4. CRT-23 the byte at WR rise; a WR with DACK and CS high takes nothing
    ids = "CRT-23, [D79] 1-185";
    use_image(IM_BYTE); img_next = IM_NORM;
    t_cnt = "byte"; t_disp = "byte"; fw_disp = 1'b1; fw_first = 1'b0; fw_inf = 1'b0;
    frame_window;
    stat_chk(8'h00, 8'h03, "byte", "after the frame with the WR without DACK and CS");
    //---------------- 3. CRT-22 DRQ per character: low at every DMA WR, high again after it within a burst
    ids = "CRT-22, [D79] 1-184 Fig. 30, D9";
    c3_n = 0; n3_wf = 0; n3_low = 0; n3_rise = 0; c3_left = 3;
    `WAIT_UNTIL(c3_n == 3, 5 * ROW, "drq at wr: three row fills")
    if (n3_wf != 3 * m_nh || n3_rise != 3 * (m_nh - (m_nh + cur_bc - 1) / cur_bc) || n3_low < 100 * n3_wf) begin
        $sformat(msg, "drq at wr: %0d WR falls, %0d WR rises in a burst, %0d low samples checked, expected %0d, %0d, at least %0d",
            n3_wf, n3_rise, n3_low, 3 * m_nh, 3 * (m_nh - (m_nh + cur_bc - 1) / cur_bc), 100 * n3_wf);
        err(msg);
    end
    //---------------- 2. CRT-21 bursts: BB with SSS = 001, SSS with BB = 11
    ids = "CRT-21, [D79] 1-172, 1-179";
    ba_tl = "burst length"; ba_ts = "burst space";
    burst_cfg(2'b00, 3'b001); burst_cfg(2'b01, 3'b001); burst_cfg(2'b10, 3'b001); burst_cfg(2'b11, 3'b001);
    burst_cfg(2'b11, 3'b000); burst_cfg(2'b11, 3'b011); burst_cfg(2'b11, 3'b111);
    start_display(3'b001, 2'b11);
    //---------------- 6. CRT-25 underrun: the stand-in stops after 3 bytes of the row 6 fill
    ids = "CRT-25, [D79] 1-172, 1-180, S11";
    stat_chk(8'h00, 8'h02, "underrun", "before the stall");
    `WAIT_UNTIL(w_open && w_row == 2, FRAME + ROW, "underrun: row 2")
    u_arm = 1'b1;
    `WAIT_UNTIL(u_stop, FRAME, "underrun: the stall in the row 6 fill")
    `WAIT_UNTIL(tl == 6 * m_nl - 1, 2 * ROW, "underrun: the last line of row 5")
    while (n16 < hf_t + 12 * m_nh - 36) @(negedge clk);
    stat_chk(8'h00, 8'h02, "underrun", "3 CCLK before the row 6 start");
    `WAIT_UNTIL(u_phase == 1, 2 * LINE, "underrun: the row 6 start")
    // DU stays set over row starts until a status read ([D79] 1-180): the first read after the row 8 start
    `WAIT_UNTIL(w_open && w_row == 8, 3 * ROW, "underrun: row 8")
    wait_n(LINE);
    stat_chk(8'h02, 8'h02, "underrun", "after the row 8 start (set at the row 6 start, no read since)");
    stat_chk(8'h00, 8'h02, "underrun", "the status read after DU");
    // the next frame: rows 1-29 from the image (row 0 shows its buffer as left, S11); the frame after it: all rows
    t_cnt = "underrun"; t_disp = "underrun"; fw_disp = 1'b1; fw_cnt = 1'b1; fw_first = 1'b0; fw_inf = 1'b0;
    fw_rmin = 1; fw_nfr = 2; fw_done = 1'b0;
    `WAIT_UNTIL(fw_done, 4 * FRAME, "underrun: the two frames after the VRTC fall")
    if (u_phase != 0) err("underrun: the first DRQ after the VRTC fall not checked");
    fw_nfr = 1;
    //---------------- 7. CRT-26 special codes
    ids = "CRT-26, [D79] 1-175";
    use_image(IM_SPEC); img_next = IM_NORM;
    // two frames: the frame with the codes, then a plain frame (F3h stops DMA only until the next frame's first DMA,
    // End of Screen only until VRTC)
    t_cnt = "stop dma"; t_disp = "special codes"; fw_first = 1'b1; fw_nfr = 2;
    frame_window;
    fw_first = 1'b0;
    stat_chk(8'h00, 8'h02, "stop dma", "after the frames with F1h and F3h (no underrun)");
    //---------------- 8. CRT-27 transparent field attributes and the FIFOs
    ids = "CRT-27, [D79] 1-165, 1-176";
    use_image(IM_FIFO); img_next = IM_NORM;
    // two frames: the frame with the attributes, then a plain frame (field attributes reset in the vertical retrace)
    t_cnt = "fifo"; t_disp = "fifo"; fw_nfr = 2;
    fw_done = 1'b0; fw_arm = 1'b1;
    `WAIT_UNTIL(fw_on && w_open && w_row == 6, 2 * FRAME, "fifo: row 6")
    wait_n(6000);
    stat_chk(8'h00, 8'h01, "fifo", "after 16 field attributes in the row 6 fill");
    `WAIT_UNTIL(w_row == 8, 3 * ROW, "fifo: row 8")
    wait_n(6000);
    stat_chk(8'h01, 8'h01, "fifo", "after 17 field attributes in the row 8 fill");
    stat_chk(8'h00, 8'h01, "fifo", "the status read after FO");
    `WAIT_UNTIL(fw_done, 3 * FRAME, "fifo: the frame window")
    fw_nfr = 1;
    //---------------- 9. CRT-28 non-transparent field attributes (F = 1)
    ids = "CRT-28, [D79] 1-176";
    program(8'h4D, 8'h1D, 8'h99, 8'hD3); start_display(3'b001, 2'b11);
    use_image(IM_NT); img_next = IM_NORM;
    t_cnt = "non-transparent"; t_disp = "non-transparent";
    frame_window;
    //---------------- 5. CRT-24 buffer full inside a burst: H = 4Ch (77 characters), BB = 11
    ids = "CRT-24, [D79] 1-172";
    program(8'h4C, 8'h1D, 8'h99, 8'h93); start_display(3'b001, 2'b11);
    ba_tl = "buffer full"; ba_ts = "buffer full"; ba_cfg = "H = 4Ch, BB = 11, SSS = 001";
    ba_n = 0; ba_left = 2;
    `WAIT_UNTIL(ba_n == 2, 2 * FRAME + 4 * ROW, "buffer full: the raster sync and two row fills")
    stat_chk(8'h00, 8'h02, "buffer full", "after the fills ended by a full buffer (no underrun)");
    if (errors == 0) $display("PASS: vg75_dma (%0d ce16)", n16);
    $finish;
end
endmodule
`default_nettype wire
