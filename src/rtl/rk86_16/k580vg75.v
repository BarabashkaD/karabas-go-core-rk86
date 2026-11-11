// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license.
// For complete licensing information see LICENSE.TXT.
// --------------------------------------------------------------------
//
// An open implementation of K580VG75 CRT controller
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
// Modifications: Sorgelig (MiSTer-devel/Apogee_MiSTer rtl/k580vg75.sv at
// 4b37da252517ceae3306a56a9eef08290259b098).
// Rewritten to the Intel 8275 data sheet ([D79] 1979 00224A, [D84] 1984) for the Radio-86RK 16 MHz
// machine (karabas-go-core-rk86, rk86_16/), Verilog-2005; kept from the base: the two row buffers and
// FIFOs indexed by the buffer select, the parameter state machine, the status byte layout.
//   - the 8275 pins: CC, LC, LA, VSP, LTEN, RVV, HGLT, GPA, HRTC, VRTC, DRQ, IRQ, LPEN; the font ROM and the
//     dot shift register are the board's (rk86_video16.v); no MiSTer screen shifts, no hblank / vblank
//   - every change at CCLK↓ (cclk); HRTC / VRTC at the data sheet positions, not re-timed to the dots
//   - all commands: Reset (4 parameters), Start / Stop Display, Read Light Pen, Load Cursor, Enable /
//     Disable Interrupt, Preset Counters (held until the next command); IC for short / long strings
//   - all parameters: S, H, VV, R, UUUU, LLLL, M, F, CC, ZZZZ; burst count and space of Start Display
//   - DMA: the first fill of a frame at the start of the last retrace row, row r + 1 during row r;
//     bursts as programmed, the space counted from the end of a burst; DRQ dropped at every DMA WR↓
//     and raised after WR↑ while the burst has characters left (one HOLD period per character, D9)
//   - the DMA byte taken at WR↑ with DACK (not at DACK↑)
//   - special codes F0-F3 with and without Stop DMA; field attributes 10URGGBH (transparent with the
//     FIFOs, non-transparent); character attributes 11CCCCBH (LA, VSP, LTEN table); the four cursor
//     formats; blinking; spaced rows; top / bottom blanking for UUUU >= 8; light pen registers
//   - underrun from the buffer count (not from DRQ): DU; the screen blanked until the row 0 start, the DMA stopped
//     until the start of the last retrace row, whose row 0 fill runs as in every frame ([D79] 1-180 "until after the
//     vertical retrace interval"; S11 decided 2026-11-11 by D11, spec 4.4: the board's picture is aligned after boot;
//     approved for now, to be checked on a real 8275 with a logic analyser: README.md, "Follow-up")
//   - the power-up state = the state after the Reset command (display, interrupts and DMA off, flags 0,
//     VSP high; parameters, counters and cursor 0); the plain 8275, not the 8275-2; SILENT items marked
`default_nettype none
module k580vg75(
    input  wire       clk,
    input  wire       cclk,
    input  wire       cs_n,
    input  wire       rd_n,
    input  wire       wr_n,
    input  wire       a0,
    input  wire [7:0] d_i,
    output wire [7:0] d_o,
    output reg        drq = 1'b0,
    input  wire       dack_n,
    output wire       irq,
    input  wire       lpen,
    output reg        hrtc = 1'b0,
    output reg        vrtc = 1'b0,
    output reg  [6:0] cc = 7'd0,
    output reg  [3:0] lc = 4'd0,
    output reg  [1:0] la = 2'd0,
    output reg        vsp = 1'b1,
    output reg        lten = 1'b0,
    output reg        rvv = 1'b0,
    output reg        hglt = 1'b0,
    output reg  [1:0] gpa = 2'd0
);
//---------------- programming and status ([D79] 1-178..1-180)
reg       p_s = 1'b0;          // S: spaced rows
reg [6:0] p_h = 7'd0;          // HHHHHHH: characters per row - 1
reg [1:0] p_v = 2'd0;          // VV: vertical retrace rows - 1
reg [5:0] p_r = 6'd0;          // RRRRRR: rows per frame - 1
reg [3:0] p_u = 4'd0;          // UUUU: underline line
reg [3:0] p_l = 4'd0;          // LLLL: lines per row - 1
reg       p_m = 1'b0;          // M: line counter mode
reg       p_f = 1'b0;          // F: field attribute mode, 0 transparent
reg [1:0] p_c = 2'd0;          // CC: cursor format
reg [3:0] p_z = 4'd0;          // ZZZZ: horizontal retrace (Z + 1) x 2 characters
reg [2:0] p_bs = 3'd0;         // SSS: burst space
reg [1:0] p_bc = 2'd0;         // BB: burst count
reg [6:0] cur_c = 7'd0;
reg [5:0] cur_r = 6'd0;
reg [6:0] lp_c = 7'd0;
reg [5:0] lp_r = 6'd0;
reg ie = 1'b0, ir = 1'b0, lp = 1'b0, ic = 1'b0, ve = 1'b0, du = 1'b0, fo = 1'b0;
reg [2:0] pexp = 3'd0;         // parameter bytes still expected
reg [1:0] pidx = 2'd0;
reg       ptyp = 1'b0;         // 0 Reset, 1 Load Cursor
reg [1:0] rlp = 2'd0;          // light pen bytes still to be read
assign d_o = a0 ? {1'b0, ie, ir, lp, ic, ve, du, fo}                                     // CRT-43
               : rlp == 2'd2 ? {1'b0, lp_c} : rlp == 2'd1 ? {2'b00, lp_r} : 8'h00;       // SILENT S1
assign irq = ir;
//---------------- counters
reg [7:0] ch = 8'd0;           // character counter: 0..H display, H+1..H+2(Z+1) retrace
reg [3:0] ln = 4'd0;           // line counter (line number)
reg [6:0] rw = 7'd0;           // row counter: 0..R display, R+1..R+VV+1 retrace
reg [4:0] frame = 5'd0;        // VRTC count, for blinking (bits 4 and 3)
reg       preset = 1'b0, hold = 1'b0, rel = 1'b0;
wire [7:0] h_last = {1'b0, p_h};
wire [7:0] line_last = h_last + {3'b000, p_z, 1'b0} + 8'd2;
wire [6:0] r_last = {1'b0, p_r};
wire [6:0] row_last = r_last + {5'd0, p_v} + 7'd1;
wire [7:0] chn = ch >= line_last ? 8'd0 : ch + 8'd1;
// the IR set event: the CCLK↓ that ends HRTC before line 0 of the last display row, with IE ([D79] 1-172)
wire ir_set = cclk && !preset && !hold && chn == 8'd0 && rw == r_last && ln == 4'd0 && ie;
wire [3:0] bcn = 4'd1 << p_bc;                                    // 1, 2, 4, 8 transfers
wire [5:0] bsn = p_bs == 3'd0 ? 6'd0 : {p_bs, 3'b000} - 6'd1;     // 0, 7, 15, ..., 55 CCLK
//---------------- row buffers, FIFOs, DMA
reg [7:0] rbuf [0:255];        // two row buffers: {buffer, position}
reg [6:0] fifo [0:31];         // two FIFOs of 16: {buffer, pointer}
reg       dsel = 1'b0;         // the displayed buffer; DMA fills the other
reg [7:0] code_q = 8'h00;      // the code at the next display position
reg [6:0] fifo_q = 7'h00;      // the FIFO character at the read pointer
reg       fill = 1'b0, filled = 1'b0, to_fifo = 1'b0, stop_next = 1'b0, stop_frame = 1'b0;
reg [6:0] ipos = 7'd0;
reg [3:0] iw = 4'd0;
reg [4:0] icount = 5'd0;
reg [3:0] bleft = 4'd0;        // transfers left in the burst
reg [5:0] space = 6'd0;        // CCLK left until the next burst
reg       dmae = 1'b0, fstop = 1'b0, ustop = 1'b0, ublank = 1'b0;   // fstop: F3; ustop: an underrun
//---------------- display scan
reg [5:0] fa = 6'd0, fa_row = 6'd0;   // field attributes U R G G B H in force; at the start of the row
reg [3:0] fr = 4'd0;
reg       eor = 1'b0, eos = 1'b0;
//---------------- bus
reg       wr_q = 1'b1, rd_q = 1'b1, lpen_q = 1'b0;
reg       w_a0 = 1'b0, w_cs = 1'b0, w_dack = 1'b0, r_a0 = 1'b0, r_cs = 1'b0;
reg [7:0] w_d = 8'h00;
//---------------- temporaries of the clocked block
reg [7:0] t_code;
reg [3:0] t_ca, t_ln, t_bl;
reg [1:0] t_reg, t_la, t_g;
reg [6:0] t_cc, t_rn;
reg       t_v, t_l, t_r, t_h, t_cur, t_full, t_stop, t_done, t_tf, t_ur;
integer k;
initial begin
    for (k = 0; k < 256; k = k + 1) rbuf[k] = 8'h00;
    for (k = 0; k < 32; k = k + 1) fifo[k] = 7'h00;
end

// a display row that is not blanked by spaced rows; S and the last row as arguments (not read from the module scope)
function text_row(input [6:0] r, input s, input [6:0] last);
    text_row = r <= last && !(s && r[0]);         // SILENT S8
endfunction

function [3:0] ca_table(input [3:0] c, input [1:0] where);   // {LA1, LA0, VSP, LTEN} ([D79] 1-174)
    case ({c, where})                                         // where: 0 above, 1 at, 2 below the underline
        6'b0000_00: ca_table = 4'b0010;  6'b0000_01: ca_table = 4'b1000;  6'b0000_10: ca_table = 4'b0100;
        6'b0001_00: ca_table = 4'b0010;  6'b0001_01: ca_table = 4'b1100;  6'b0001_10: ca_table = 4'b0100;
        6'b0010_00: ca_table = 4'b0100;  6'b0010_01: ca_table = 4'b1000;  6'b0010_10: ca_table = 4'b0010;
        6'b0011_00: ca_table = 4'b0100;  6'b0011_01: ca_table = 4'b1100;  6'b0011_10: ca_table = 4'b0010;
        6'b0100_00: ca_table = 4'b0010;  6'b0100_01: ca_table = 4'b0001;  6'b0100_10: ca_table = 4'b0100;
        6'b0101_00: ca_table = 4'b0100;  6'b0101_01: ca_table = 4'b1100;  6'b0101_10: ca_table = 4'b0100;
        6'b0110_00: ca_table = 4'b0100;  6'b0110_01: ca_table = 4'b1000;  6'b0110_10: ca_table = 4'b0100;
        6'b0111_00: ca_table = 4'b0100;  6'b0111_01: ca_table = 4'b0001;  6'b0111_10: ca_table = 4'b0010;
        6'b1000_00: ca_table = 4'b0010;  6'b1000_01: ca_table = 4'b0001;  6'b1000_10: ca_table = 4'b0010;
        6'b1001_00: ca_table = 4'b0100;  6'b1001_01: ca_table = 4'b0100;  6'b1001_10: ca_table = 4'b0100;
        6'b1010_00: ca_table = 4'b0100;  6'b1010_01: ca_table = 4'b0001;  6'b1010_10: ca_table = 4'b0100;
        6'b1100_00: ca_table = 4'b0010;  6'b1100_01: ca_table = 4'b0010;  6'b1100_10: ca_table = 4'b0010;
        default:    ca_table = 4'b0000;               // 1011 (not recommended); SILENT S7a: 1101-1111
    endcase
endfunction

// the start of row rn: VRTC, the buffer swap, the underrun check, the fill of the next row
task row_start(input [6:0] rn);
    begin
        vrtc <= rn > r_last;
        if (rn == r_last + 7'd1) begin                 // VRTC rises: field attributes and End of Screen reset
            frame <= frame + 5'd1; eos <= 1'b0; fa <= 6'd0; fa_row <= 6'd0;
        end else fa_row <= fa;
        if (rn == row_last) ustop <= 1'b0;             // S11 (decided 2026-11-11, D11): the row 0 fill runs
        if (rn == 7'd0) ublank <= 1'b0;                // the display of the new frame
        t_ur = text_row(rn, p_s, r_last) && fill && !filled;        // SILENT S11: the moment of the underrun check
        if (t_ur) begin du <= 1'b1; ustop <= 1'b1; ublank <= 1'b1; end
        if (text_row(rn, p_s, r_last)) dsel <= !dsel;
        if ((rn == row_last || text_row(rn + 7'd1, p_s, r_last)) && dmae && !t_ur && (!ustop || rn == row_last)
            && (rn == row_last || !fstop)) begin
            fill <= 1'b1; filled <= 1'b0; ipos <= 7'd0; iw <= 4'd0; icount <= 5'd0; to_fifo <= 1'b0;
            stop_next <= 1'b0; stop_frame <= 1'b0; bleft <= bcn; space <= 6'd0; drq <= 1'b1;
        end else begin
            fill <= 1'b0; drq <= 1'b0; space <= 6'd0;
        end
        if (rn == row_last) fstop <= 1'b0;             // the first DMA of the frame (after an underrun too)
    end
endtask

always @(posedge clk) begin
    code_q <= rbuf[{dsel, chn[6:0]}];
    fifo_q <= fifo[{dsel, fr}];
    wr_q <= wr_n;
    rd_q <= rd_n;
    lpen_q <= lpen;
    if (!wr_n) begin w_a0 <= a0; w_d <= d_i; w_cs <= !cs_n; w_dack <= !dack_n; end
    if (!rd_n) begin r_a0 <= a0; r_cs <= !cs_n; end
    //---------------- light pen: the counters at the LPEN rising edge ([D79] 1-165, 1-177)
    if (lpen && !lpen_q) begin lp_c <= ch[6:0]; lp_r <= rw[5:0]; lp <= 1'b1; end
    //---------------- DMA WR↓ with DACK: DRQ falls ([D79] Fig. 30 tRQ)
    if (!wr_n && wr_q && !dack_n) drq <= 1'b0;
    //---------------- CCLK↓
    if (cclk) begin
        if (preset) begin                       // S12 (decided): the top left corner of the frame cycle =
            preset <= 1'b0; hold <= 1'b1;       // the start of the last retrace row, its row 0 fill to come
            ch <= line_last; ln <= 4'd0; rw <= row_last;
            hrtc <= 1'b0; vrtc <= 1'b0; vsp <= 1'b1; lten <= 1'b0; rvv <= 1'b0; hglt <= 1'b0; la <= 2'b00; gpa <= 2'b00;
            drq <= 1'b0; fill <= 1'b0; space <= 6'd0; bleft <= 4'd0; eor <= 1'b0; fr <= 4'd0;
            // S12 / S11 (decided): an underrun's DMA stop ends at the resume (row_start of the last retrace row),
            // its first DMA is the row 0 fill; ublank stays until the row 0 start
        end else if (!hold) begin
            // the burst space before the row starts below, so that a row start in the same CCLK decides DRQ: after
            // an underrun no DMA request ([D79] 1-180 "the DMA operation is stopped"; final review 2026-11-11, I1)
            if (space != 6'd0) begin                                                 // the burst space
                space <= space - 6'd1;
                if (space == 6'd1 && fill && !filled && dmae) begin bleft <= bcn; drq <= 1'b1; end
            end
            if (rel) begin                      // the resume: the row start of the last retrace row (VRTC↑,
                rel <= 1'b0;                    // the row 0 fill) with the actions of a VRTC rise
                row_start(row_last);
                frame <= frame + 5'd1; eos <= 1'b0; fa <= 6'd0; fa_row <= 6'd0;
            end
            ch <= chn;
            t_ln = ln;
            if (chn == h_last + 8'd1) begin                                          // HRTC rises
                hrtc <= 1'b1; eor <= 1'b0; fr <= 4'd0;
                if (ln >= p_l) begin
                    t_ln = 4'd0;
                    t_rn = rw >= row_last ? 7'd0 : rw + 7'd1;
                    rw <= t_rn;
                    row_start(t_rn);
                end else begin
                    t_ln = ln + 4'd1;
                    fa <= fa_row;                                                    // every line of a row starts alike
                end
                ln <= t_ln;
            end
            if (chn == 8'd0) hrtc <= 1'b0;                                           // HRTC falls: a line begins
            if (ir_set) ir <= 1'b1;                                                  // the last display row
            lc <= p_m ? (t_ln == 4'd0 ? p_l : t_ln - 4'd1) : t_ln;
            if (chn > h_last || rw > r_last) begin                                   // HRTC or VRTC
                vsp <= 1'b1; lten <= 1'b0; rvv <= 1'b0; hglt <= 1'b0; la <= 2'b00; gpa <= 2'b00;  // SILENT S5
            end else begin
                t_code = code_q;
                t_reg = ln < p_u ? 2'd0 : ln == p_u ? 2'd1 : 2'd2;
                t_cur = rw[5:0] == cur_r && chn[6:0] == cur_c && (p_c[1] || !frame[3]);   // SILENT S3
                t_cc = t_code[6:0]; t_la = 2'b00; t_v = 1'b0; t_l = 1'b0; t_r = 1'b0; t_h = 1'b0; t_g = 2'b00;
                if (eos || eor) begin                                // after End of Row only End of Screen acts
                    t_v = 1'b1;
                    if (!eos && t_code[7:1] == 7'b1111001) eos <= 1'b1;
                end else if (t_code[7:2] == 6'b111100) begin         // F0-F3: End of Row / End of Screen
                    t_v = 1'b1;
                    if (t_code[1]) eos <= 1'b1; else eor <= 1'b1;
                end else if (t_code[7:6] == 2'b10) begin             // field attribute 10URGGBH
                    fa <= t_code[5:0];
                    if (p_f) t_v = 1'b1;                             // non-transparent: a blank position (SILENT S7)
                    else begin                                       // transparent: the FIFO character
                        t_cc = fifo_q; fr <= fr + 4'd1;
                        t_v = t_code[1] && frame[4]; t_l = t_code[5] && t_reg == 2'd1;
                        t_r = t_code[4]; t_h = t_code[0]; t_g = t_code[3:2];
                    end
                end else if (t_code[7:6] == 2'b11) begin             // character attribute 11CCCCBH (SILENT S7)
                    t_ca = ca_table(t_code[5:2], t_reg);
                    t_la = t_ca[3:2]; t_v = t_ca[1] || (t_code[1] && frame[4]); t_l = t_ca[0];
                    t_h = t_code[0]; t_r = fa[4]; t_g = fa[3:2];      // affected by R and GG only ([D79] 1-176)
                end else begin                                       // a character
                    t_v = fa[1] && frame[4]; t_l = fa[5] && t_reg == 2'd1; t_r = fa[4]; t_h = fa[0]; t_g = fa[3:2];
                end
                if (t_cur && !p_c[0]) t_r = !t_r;                     // reverse video block (SILENT S4)
                if (t_cur && p_c[0] && t_reg == 2'd1) t_l = 1'b1;     // underline
                if (!ve || ublank || !text_row(rw, p_s, r_last) || (p_u[3] && (ln == 4'd0 || ln == p_l))) t_v = 1'b1;
                if (!ve || ublank) t_l = 1'b0;                        // SILENT S6
                cc <= t_cc; la <= t_la; vsp <= t_v; lten <= t_l; rvv <= t_r; hglt <= t_h; gpa <= t_g;
            end
        end
    end
    //---------------- a DMA byte at WR↑ with DACK ([D79] 1-185 tDW, tWD)
    if (wr_n && !wr_q && w_dack) begin
        if (fill && !filled && !(cclk && preset)) begin   // SILENT S14; at the preset CCLK the byte is ignored
            t_tf = 1'b0; t_stop = 1'b0;
            if (to_fifo) begin
                fifo[{!dsel, iw}] <= w_d[6:0]; iw <= iw + 4'd1;
                if (icount == 5'd16) fo <= 1'b1; else icount <= icount + 5'd1;      // overrun: the first ones lost
                t_full = ipos > p_h;                                                 // SILENT S13
            end else begin
                rbuf[{!dsel, ipos}] <= w_d; ipos <= ipos + 7'd1;
                t_tf = !p_f && w_d[7:6] == 2'b10;
                t_full = ipos == p_h;
                t_stop = w_d[7:2] == 6'b111100 && w_d[0];                            // F1, F3: Stop DMA
            end
            to_fifo <= t_tf;
            if (t_stop && w_d[1]) stop_frame <= 1'b1;
            t_bl = bleft - 4'd1;
            t_done = (t_full && !t_tf) || stop_next || (t_stop && (t_bl == 4'd0 || t_full));
            if (t_stop && !t_done) stop_next <= 1'b1;                                // after the next character
            if (t_done) begin
                filled <= 1'b1; drq <= 1'b0; bleft <= 4'd0;
                if (stop_frame || (t_stop && w_d[1])) fstop <= 1'b1;
            end else if (t_bl == 4'd0) begin                                         // the end of a burst
                if (bsn == 6'd0) begin bleft <= bcn; drq <= 1'b1; end
                else begin bleft <= 4'd0; space <= bsn; end
            end else begin
                bleft <= t_bl; drq <= 1'b1;                                          // tWQ after WR↑
            end
        end
    end
    //---------------- a command or a parameter at WR↑ ([D79] 1-177..1-179)
    if (wr_n && !wr_q && !w_dack && w_cs) begin
        if (w_a0) begin
            if (pexp != 3'd0) ic <= 1'b1;                                            // SILENT S16
            pexp <= 3'd0; pidx <= 2'd0;
            if (hold && w_d[7:5] != 3'd7) begin hold <= 1'b0; rel <= 1'b1; end
            case (w_d[7:5])
                3'd0: begin                                                          // Reset
                    pexp <= 3'd4; ptyp <= 1'b0;
                    dmae <= 1'b0; drq <= 1'b0; fill <= 1'b0; space <= 6'd0;
                    ie <= 1'b0; ve <= 1'b0; ir <= 1'b0;
                end
                3'd1: begin p_bs <= w_d[4:2]; p_bc <= w_d[1:0]; ie <= 1'b1; ve <= 1'b1; dmae <= 1'b1; end  // SILENT S9
                3'd2: ve <= 1'b0;                                                    // Stop Display (SILENT S10)
                3'd3: rlp <= 2'd2;                                                   // Read Light Pen (SILENT S15)
                3'd4: begin pexp <= 3'd2; ptyp <= 1'b1; end                          // Load Cursor
                3'd5: ie <= 1'b1;                                                    // Enable Interrupt
                3'd6: ie <= 1'b0;                                                    // Disable Interrupt
                default: preset <= 1'b1;                                             // Preset Counters
            endcase
        end else if (pexp == 3'd0) ic <= 1'b1;
        else begin
            pexp <= pexp - 3'd1; pidx <= pidx + 2'd1;
            case ({ptyp, pidx})
                3'b000: {p_s, p_h} <= w_d;
                3'b001: {p_v, p_r} <= w_d;
                3'b010: {p_u, p_l} <= w_d;
                3'b011: {p_m, p_f, p_c, p_z} <= w_d;
                3'b100: cur_c <= w_d[6:0];
                default: cur_r <= w_d[5:0];
            endcase
        end
    end
    //---------------- a read at RD↑: the status read clears IR, LP, IC, DU, FO ([D79] 1-180)
    if (rd_n && !rd_q && r_cs) begin
        if (r_a0) begin ir <= 1'b0; lp <= 1'b0; ic <= 1'b0; du <= 1'b0; fo <= 1'b0; end
        else if (rlp != 2'd0) rlp <= rlp - 2'd1;
    end
end
endmodule
`default_nettype wire
