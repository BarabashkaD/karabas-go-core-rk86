// k580vg75, the outputs, against the Intel 8275 data sheet ([D79] 1979 00224A; Task 2 CRT-30..36, Task 10): character
// attributes, field attributes and their interaction, the cursor, VSP and LTEN in retrace, the character codes and LC,
// the blink rates.
// Harness of tb_vg75_dma.v (Tasks 8, 9): the ce16 cadence of tb_clocks16.v (64 / 297 of clk); cclk = one clk at every
// 12th ce16 (CCLK falling edge); the CPU bus tasks (CS, RD, WR held 4 clk); the raster model from the pins (lines
// counted from a VRTC fall, characters from an HRTC fall); the error cap and bounded waits. The DMA stand-in is faster
// than the one of Task 9 (DACK low 2 ce16 after it sees DRQ high, WR low 1 ce16 later for 3 ce16), so that a row of
// 16 characters fills in about 10 CCLK and the frames stay small: 0Fh 03h x9h x3h, 16 characters and 8 retrace
// characters per line, 10 lines per row, 4 display rows and 1 retrace row: 1200 CCLK (14400 ce16) per frame.
// The stand-in serves the screen image of the check: row t (the row being filled: row r + 1 during row r, row 0
// during the retrace row, from the HRTC rises that start the rows), transfer k. The reference at every display
// position comes from that image and the data sheet rules only: the row buffer and FIFO contents (a field attribute
// puts the next byte into the FIFO, its MSB stripped, [D79] 1-176), the field attribute in force (from its own
// position in the transparent mode, until the next one, across lines and rows, reset at the VRTC rise, [D79] 1-175,
// 1-176), the character attribute table (Task 1 record d, [D79] 1-174), the interaction (1-176), the cursor (1-177),
// End of Row / End of Screen (1-175), the blanking rules (1-163). Blinking: the frame counter of S3 / S17 = the VRTC
// rises the TB counts from power-up (0 at power-up); character / field blink off (VSP high) in the frames with
// counter bit 4 = 1, the blinking cursor shown in the frames with bit 3 = 0 (the plan's phase and duty, S3).
// Every CCLK fall of a frame window is checked: the display positions against the reference (each output counted per
// frame, the counts checked against the positions the reference checks), the retrace positions VSP high and LTEN low
// ([D79] 1-163 pins 7, 8). CC and LC mismatches print as `cc`, retrace mismatches as `vsp`, the others under the
// topic of the check. Status through CPU reads (CS, A0, RD pulses).
// The checks run in the order 4 (the first CC = 00 frames), 7, 1, 4 (the rest), 2, 3, 5, 6, so that each planned fault
// is first seen by its own check: the images before check 1 have no underline (no U field, no underline cursor, no
// character attribute other than 1001, whose outputs are the same above, at and below the underline line), the cursor
// images no blinking attribute and no character attribute, the blink image no character attribute inside a field, and
// the field attributes of all images before check 2 end before the end of the frame.
`default_nettype none
`timescale 1ns/1ns
`define WAIT_UNTIL(COND, LIM, WHAT) begin tw0 = n16; while (!(COND)) begin @(negedge clk); if (n16 > tw0 + (LIM)) begin $display("FATAL: vg75_attr: %0s timed out", WHAT); $finish; end end end
module tb_vg75_attr;
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
    .drq(drq), .dack_n(dack_n), .irq(irq), .lpen(1'b0), .hrtc(hrtc), .vrtc(vrtc), .cc(cc), .lc(lc), .la(la),
    .vsp(vsp), .lten(lten), .rvv(rvv), .hglt(hglt), .gpa(gpa));
localparam integer NH = 16, NR = 4, NV = 1, NL = 10, NZ = 3, NC = NH + 2 * (NZ + 1);
localparam integer LINE = 12 * NC, ROW = NL * LINE, FRAME = (NR + NV) * ROW;        // 288, 2880, 14400 ce16
localparam integer NRET = (NR + NV) * NL * NC - NR * NL * NH;                        // 560 retrace CCLK per frame
localparam [7:0] P1 = 8'h0F, P2 = 8'h03;                                             // 16 characters, 4 rows, VV = 00
localparam integer KMAX = 32, NIM = 10;
// the images: 0 the cursor, 1 the blink rates, 2 the character attributes, 3 the field attributes, 4 their
// interaction, 5 End of Row / End of Screen, 6 plain characters, 7 and 8 the 128 character codes, 9 the cursor image
// without the U field
localparam integer IM_CUR = 0, IM_BLINK = 1, IM_CA = 2, IM_FA = 3, IM_INT = 4, IM_VSP = 5, IM_PLAIN = 6, IM_CC0 = 7,
    IM_CC1 = 8, IM_CUR0 = 9;
localparam integer K_CHAR = 0, K_CA = 1, K_FA = 2, K_SPEC = 3, K_AFTER = 4;
localparam integer U_ROW = 2;                    // the underrun: the stand-in stalls in the row 2 fill
//---------------- messages: ERROR: vg75: <what> (<ID>, [D79] <page>)
localparam [8*40-1:0] ID_CA = "CRT-30, [D79] 1-174", ID_FA = "CRT-31, [D79] 1-175", ID_INT = "CRT-32, [D79] 1-176",
    ID_CUR = "CRT-33, [D79] 1-177, S3, S4", ID_VSP = "CRT-34, [D79] 1-163", ID_CC = "CRT-35, [D79] 1-164, 1-176",
    ID_BL = "CRT-36, [D79] 1-173, 1-175, S3";
integer n16 = 0, st_q = 0, errors = 0, tw0 = 0;
reg [8*400-1:0] msg;
task err(input [8*400-1:0] what, input [8*40-1:0] id); begin
    $display("ERROR: vg75: %0s (%0s) at ce16 %0d", what, id, n16); errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: vg75_attr: too many errors"); $finish; end
end endtask
//---------------- the parameters the TB wrote, the cursor, VE
integer m_nh = 1, m_nr = 1, m_nv = 1, m_nl = 1, m_z = 0, m_u = 0;
reg m_sp = 1'b0, m_m = 1'b0, t_ve = 1'b0;
reg [1:0] m_c = 2'b00;
integer cur_r = 0, cur_c = 0;
//---------------- the raster model: tl the line since the VRTC fall (-1 until the first HRTC fall), tc the character
// since the HRTC fall, ri the row whose start was the last row-start HRTC rise (0 at the VRTC fall)
integer tl = -1, tc = 0, ri = 0, n_r3 = 0;
reg synced = 1'b0, vf_seen = 1'b0;
integer img_mode = 6, img_next = 6;              // IM_PLAIN; img_next takes effect at the row 3 start (no fill in row 3)
reg cclk_q = 1'b0, hrtc_q = 1'b0, vrtc_q = 1'b0, dwr_q = 1'b1;
reg hr_ev, hf_ev, vr_ev, vf_ev, rs_ev, wf_ev, wu_ev;
// the row fill window of the stand-in, the underrun stall
reg w_open = 1'b0, in_dma = 1'b0, u_arm = 1'b0, u_stop = 1'b0;
integer w_row = 0, w_tgt = 0, w_mode = 0, w_tr = 0, dst = 0, dcnt = 0, s_k = 0;
reg [7:0] s_byte;
//---------------- the images: ims the DMA bytes of row t, transfer k; from them the display of row r, position p:
// dbuf the row buffer byte, dfifo the FIFO character shown at a field attribute, dfa the field attribute in force
// (URGGBH); eos_r / eos_p the End of Screen code, eor_p the End of Row code of each row (-1: none)
reg [7:0] ims [0:NIM*NR*KMAX-1];
reg [7:0] dbuf [0:NIM*NR*NH-1];
reg [6:0] dfifo [0:NIM*NR*NH-1];
reg [5:0] dfa [0:NIM*NR*NH-1];
integer eos_r [0:NIM-1];
integer eos_p [0:NIM-1];
integer eor_p [0:NIM*NR-1];
function [7:0] fch(input integer m, input integer r, input integer p);     // a display character, 21h..7Ah
    fch = 8'h21 + (m * 11 + r * 16 + p) % 90;
endfunction
integer bm, br, bk, bp;
task row_begin(input integer m, input integer r); begin bm = m; br = r; bk = 0; bp = 0; end endtask
task put(input [7:0] v); begin ims[(bm * NR + br) * KMAX + bk] = v; bk = bk + 1; end endtask
task pcode(input [7:0] v); begin put(v); bp = bp + 1; end endtask          // one position: a character or a code
task pch; pcode(fch(bm, br, bp)); endtask
task pchs(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) pch; end endtask
task pfa2(input [7:0] v, input [7:0] f); begin put(v); put(f); bp = bp + 1; end endtask   // a field attribute, its FIFO byte
task pfa(input [7:0] v); pfa2(v, fch(bm, br, bp + 50)); endtask
task row_end; begin while (bp < NH) pch; end endtask
// the display from the DMA bytes: the buffer input puts the byte after a field attribute into the FIFO (transparent
// mode, [D79] 1-176); the field attribute acts from its own position (transparent) until the next one, across lines
// and rows; codes after an End of Row (in its row) and after an End of Screen are ignored ([D79] 1-175)
task derive(input integer m);
    integer r, p, k, i;
    reg [7:0] b;
    reg [5:0] fa;
    reg sr, ss;
    begin
        fa = 6'd0; ss = 1'b0; eos_r[m] = -1; eos_p[m] = -1;
        for (r = 0; r < NR; r = r + 1) begin
            eor_p[m * NR + r] = -1; sr = 1'b0; k = 0;
            for (p = 0; p < NH; p = p + 1) begin
                i = (m * NR + r) * NH + p;
                b = ims[(m * NR + r) * KMAX + k]; k = k + 1;
                dbuf[i] = b; dfifo[i] = 7'h00;
                if (b[7:6] == 2'b10) begin dfifo[i] = ims[(m * NR + r) * KMAX + k]; k = k + 1; end
                if (!sr && !ss) begin
                    if (b[7:2] == 6'b111100) begin
                        if (b[1]) begin eos_r[m] = r; eos_p[m] = p; ss = 1'b1; end
                        else begin eor_p[m * NR + r] = p; sr = 1'b1; end
                    end else if (b[7:6] == 2'b10) fa = b[5:0];
                end
                dfa[i] = fa;
            end
        end
    end
endtask
task build;
    integer m, r, k;
    begin
        for (m = 0; m < NIM; m = m + 1)
            for (r = 0; r < NR; r = r + 1)
                for (k = 0; k < KMAX; k = k + 1) ims[(m * NR + r) * KMAX + k] = fch(m, r, k + 20);
        // the cursor: rows 0, 3 plain; an R field (90h) in row 1 and a U field (A0h) in row 2, positions 2-9
        for (r = 0; r < NR; r = r + 1) begin
            row_begin(IM_CUR, r);
            if (r == 1 || r == 2) begin pchs(2); pfa(r == 1 ? 8'h90 : 8'hA0); pchs(7); pfa(8'h80); end
            row_end;
            row_begin(IM_CUR0, r);
            if (r == 1) begin pchs(2); pfa(8'h90); pchs(7); pfa(8'h80); end
            row_end;
        end
        // the blink rates: E6h (1001, B = 1) at row 0 positions 3, 9; a B field (82h) in row 1, positions 2-9
        row_begin(IM_BLINK, 0); pchs(3); pcode(8'hE6); pchs(5); pcode(8'hE6); row_end;
        row_begin(IM_BLINK, 1); pchs(2); pfa(8'h82); pchs(7); pfa(8'h80); row_end;
        row_begin(IM_BLINK, 2); row_end;
        row_begin(IM_BLINK, 3); row_end;
        // the character attributes: CCCC = 0000..1011 at positions 0-11 of every row, B H = 00, 01, 10, 11 in rows
        // 0-3; F0h (End of Row) at position 12 of row 0
        for (r = 0; r < NR; r = r + 1) begin
            row_begin(IM_CA, r);
            for (k = 0; k < 12; k = k + 1) pcode(8'hC0 + 4 * k + r);
            if (r == 0) pcode(8'hF0);
            row_end;
        end
        // the field attributes: U, R, GG = 11 in row 0, B, H, GG = 01 in row 1, GG = 10, U R H in row 2 (on to the
        // end of the frame)
        row_begin(IM_FA, 0); pchs(4); pfa(8'hA0); pchs(3); pfa(8'h90); pchs(3); pfa(8'h8C); row_end;
        row_begin(IM_FA, 1); pchs(4); pfa(8'h82); pchs(3); pfa(8'h81); pchs(3); pfa(8'h84); row_end;
        row_begin(IM_FA, 2); pchs(4); pfa(8'h88); pchs(3); pfa(8'hB1); row_end;
        row_begin(IM_FA, 3); row_end;
        // the interaction: character attributes inside R, GG (row 0), U, H (row 1), H, B (row 2) fields
        row_begin(IM_INT, 0); pch; pfa(8'h90); pch; pcode(8'hE4); pch; pfa(8'h8C); pch; pcode(8'hE4); pch; pfa(8'h80); row_end;
        row_begin(IM_INT, 1); pch; pfa(8'hA0); pch; pcode(8'hC0); pch; pcode(8'hE0); pch; pfa(8'h80); pch; pfa(8'h81);
        pch; pcode(8'hE4); pch; pcode(8'hE5); row_end;
        row_begin(IM_INT, 2); pch; pfa(8'h82); pch; pcode(8'hE4); pch; pcode(8'hE6); pch; pfa(8'h80); row_end;
        // a B R field (92h) from row 3 position 1 to the end of the frame: every character blinks and is reversed
        // (S26), the field in force at the line ends (retrace) and into the vertical retrace
        row_begin(IM_INT, 3); pch; pfa(8'h92); row_end;
        // End of Row at row 0 position 8, End of Screen at row 1 position 12
        row_begin(IM_VSP, 0); pchs(8); pcode(8'hF0); row_end;
        row_begin(IM_VSP, 1); pchs(12); pcode(8'hF2); row_end;
        row_begin(IM_VSP, 2); row_end;
        row_begin(IM_VSP, 3); row_end;
        for (r = 0; r < NR; r = r + 1) begin row_begin(IM_PLAIN, r); row_end; end
        // the codes 00h-7Fh, row r position p: 16 r + p (IM_CC0), 40h + 16 r + p (IM_CC1); position 7 a field
        // attribute (80h; A0h in IM_CC0 row 3) whose FIFO byte gives the code; IM_CC1: FIFO bytes C7h, F3h, F7h
        // (a character attribute and a special code after a field attribute are plain characters, [D79] 1-176)
        for (r = 0; r < NR; r = r + 1) begin
            row_begin(IM_CC0, r);
            for (k = 0; k < NH; k = k + 1)
                if (k == 7) pfa2(r == 3 ? 8'hA0 : 8'h80, 16 * r + k); else pcode(16 * r + k);
            row_begin(IM_CC1, r);
            for (k = 0; k < NH; k = k + 1)
                if (k == 7) pfa2(8'h80, (r == 0 || r == 3 ? 8'hC0 : 8'h40) + 16 * r + k);
                else if (k == 3 && r == 3) pfa2(8'h80, 8'hF3);
                else pcode(8'h40 + 16 * r + k);
        end
        for (m = 0; m < NIM; m = m + 1) derive(m);
    end
endtask
//---------------- the reference ([D79] 1-174 table: {LA1, LA0, VSP, LTEN} above, at, below the underline line)
function [3:0] ca_ref(input [3:0] c, input [1:0] rg);
    reg [11:0] t;
    begin
        case (c)
            4'd0: t = 12'b0010_1000_0100;  4'd1: t = 12'b0010_1100_0100;  4'd2: t = 12'b0100_1000_0010;
            4'd3: t = 12'b0100_1100_0010;  4'd4: t = 12'b0010_0001_0100;  4'd5: t = 12'b0100_1100_0100;
            4'd6: t = 12'b0100_1000_0100;  4'd7: t = 12'b0100_0001_0010;  4'd8: t = 12'b0010_0001_0010;
            4'd9: t = 12'b0100_0100_0100;  4'd10: t = 12'b0100_0001_0100; 4'd11: t = 12'b0000_0000_0000;
            default: t = 12'b0010_0010_0010;                                   // 1100 special codes
        endcase
        ca_ref = rg == 2'd0 ? t[11:8] : rg == 2'd1 ? t[7:4] : t[3:0];
    end
endfunction
function integer kind_of(input integer m, input integer r, input integer ln, input integer p);
    reg [7:0] b;
    integer e;
    begin
        b = dbuf[(m * NR + r) * NH + p]; e = eor_p[m * NR + r];
        if (eos_r[m] >= 0 && (r > eos_r[m] || (r == eos_r[m] && (ln > 0 || p > eos_p[m])))) kind_of = K_AFTER;
        else if (r == eos_r[m] && p == eos_p[m]) kind_of = K_SPEC;
        else if (e >= 0 && p > e) kind_of = K_AFTER;
        else if (e >= 0 && p == e) kind_of = K_SPEC;
        else if (b[7:6] == 2'b10) kind_of = K_FA;
        else if (b[7:6] == 2'b11) kind_of = K_CA;
        else kind_of = K_CHAR;
    end
endfunction
integer tfr = 0;                 // VRTC rises since power-up: the frame counter of the plan (S3, S17)
integer fw_mode = IM_PLAIN, fw_ur = -1;
reg fw_r0x = 1'b0;               // row 0 not checked: the frame after an underrun shows the buffer as left (S11)
reg [7:0] e_m;                   // checked outputs: 7 CC, 6 LC, 5 LA, 4 VSP, 3 LTEN, 2 RVV, 1 HGLT, 0 GPA
reg [6:0] e_cc;
reg [3:0] e_lc;
reg [1:0] e_la, e_g;
reg e_v, e_l, e_r, e_h;
task ref_out(input integer m, input integer r, input integer ln, input integer p);
    integer i, k;
    reg [7:0] b;
    reg [5:0] f;
    reg [3:0] t;
    reg [1:0] rg;
    reg bo;
    begin
        i = (m * NR + r) * NH + p; b = dbuf[i]; f = dfa[i]; k = kind_of(m, r, ln, p);
        rg = ln < m_u ? 2'd0 : ln == m_u ? 2'd1 : 2'd2;      // above, at, below the underline line (line number)
        bo = tfr % 32 >= 16;                                   // blink off (S3)
        e_m = 8'hFF; e_cc = b[6:0]; e_lc = m_m ? (ln == 0 ? m_nl - 1 : ln - 1) : ln;
        e_la = 2'b00; e_v = 1'b0; e_l = 1'b0; e_r = 1'b0; e_h = 1'b0; e_g = 2'b00;
        case (k)
            K_CHAR, K_FA: begin                                // a character; a transparent field attribute
                if (k == K_FA) e_cc = dfifo[i];
                e_v = f[1] && bo; e_l = f[5] && rg == 2'd1; e_r = f[4]; e_h = f[0]; e_g = f[3:2];
            end
            K_CA: begin                                        // R and GG of the field only ([D79] 1-176)
                t = ca_ref(b[5:2], rg);
                e_la = t[3:2]; e_v = t[1] || (b[1] && bo); e_l = t[0]; e_h = b[0]; e_r = f[4]; e_g = f[3:2];
                e_m[7] = 1'b0;                                 // CC at a character attribute: SILENT S7
            end
            default: begin                                     // a special code, the positions after it
                e_v = 1'b1; e_m[7] = 1'b0;                     // CC: not stated
                if (f != 6'd0) e_m[3:0] = 4'b0000;             // with a field in force: not stated
            end
        endcase
        if (r == cur_r && p == cur_c) begin
            if (k != K_CHAR) e_m[3:2] = 2'b00;                 // the cursor on a code: not stated
            else if (m_c[1] || tfr % 16 < 8) begin             // blinking formats in frames with bit 3 = 0 (S3)
                if (!m_c[0]) e_r = !e_r;                       // reverse block, every line (S4); in an R field normal
                else if (rg == 2'd1) e_l = 1'b1;               // underline
            end
            if (!m_c[1]) e_m[4] = 1'b0;                        // VSP at a blinking cursor: not stated (pin 35)
        end
        if (m_u >= 8 && (ln == 0 || ln == m_nl - 1)) e_v = 1'b1;
        if (m_sp && r % 2 == 1) begin                          // a blanked row: VSP; CC, LC not stated (CRT-6)
            e_v = 1'b1; e_m[7:6] = 2'b00;
            if (m != IM_PLAIN) e_m[5:0] = 6'b010000;
            else begin e_la = 2'b00; e_l = 1'b0; e_r = 1'b0; e_h = 1'b0; e_g = 2'b00; end
        end
        if (!t_ve || (fw_ur >= 0 && r >= fw_ur)) begin e_v = 1'b1; e_m = 8'b0001_0000; end   // VE = 0, underrun (S6)
        if (fw_r0x && r == 0) e_m = 8'h00;
    end
endtask
//---------------- the frame windows: armed by the TB, on from the next VRTC fall for fw_nfr frames
reg fw_arm = 1'b0, fw_on = 1'b0, fw_done = 1'b0, fw_obs = 1'b0, u_req = 1'b0;
integer fw_nfr = 1, fw_k = 0;
reg [8*48-1:0] fw_top = "cursor", fw_lbl = "";
reg [8*40-1:0] fw_id = ID_CUR;
integer n_s [0:7];
integer n_e [0:7];
integer x_s [0:7];
integer n_ret = 0, n_erv = 0, n_erl = 0, o;
reg obs [0:191];                 // per window frame: VSP seen high (character, field blink), RVV (cursor)
integer s_r, s_ln, s_p;
reg [7:0] s_b;
function [8*4-1:0] oname(input integer i);
    case (i)
        0: oname = "CC"; 1: oname = "LC"; 2: oname = "LA"; 3: oname = "VSP"; 4: oname = "LTEN"; 5: oname = "RVV";
        6: oname = "HGLT"; default: oname = "GPA";
    endcase
endfunction
task mis(input integer i, input [7:0] got, input [7:0] ex); begin
    n_e[i] = n_e[i] + 1;
    if (n_e[i] <= 2) begin
        $sformat(msg, "%0s: %0s: row %0d line %0d char %0d (code %h): %0s %0h, expected %0h (frame %0d)",
            i <= 1 ? "cc" : fw_top, fw_lbl, s_r, s_ln, s_p, s_b, oname(i), got, ex, tfr);
        err(msg, i <= 1 ? ID_CC : fw_id);
    end
end endtask
task sample;
    begin
        if (tl >= 0 && tl < NR * NL && tc < NH) begin
            s_r = tl / NL; s_ln = tl % NL; s_p = tc; s_b = dbuf[(fw_mode * NR + s_r) * NH + s_p];
            ref_out(fw_mode, s_r, s_ln, s_p);
            if (e_m[7]) begin n_s[0] = n_s[0] + 1; if (cc !== e_cc) mis(0, {1'b0, cc}, {1'b0, e_cc}); end
            if (e_m[6]) begin n_s[1] = n_s[1] + 1; if (lc !== e_lc) mis(1, {4'h0, lc}, {4'h0, e_lc}); end
            if (e_m[5]) begin n_s[2] = n_s[2] + 1; if (la !== e_la) mis(2, {6'h00, la}, {6'h00, e_la}); end
            if (e_m[4]) begin n_s[3] = n_s[3] + 1; if (vsp !== e_v) mis(3, {7'h00, vsp}, {7'h00, e_v}); end
            if (e_m[3]) begin n_s[4] = n_s[4] + 1; if (lten !== e_l) mis(4, {7'h00, lten}, {7'h00, e_l}); end
            if (e_m[2]) begin n_s[5] = n_s[5] + 1; if (rvv !== e_r) mis(5, {7'h00, rvv}, {7'h00, e_r}); end
            if (e_m[1]) begin n_s[6] = n_s[6] + 1; if (hglt !== e_h) mis(6, {7'h00, hglt}, {7'h00, e_h}); end
            if (e_m[0]) begin n_s[7] = n_s[7] + 1; if (gpa !== e_g) mis(7, {6'h00, gpa}, {6'h00, e_g}); end
            if (fw_obs && s_ln == 1 && fw_k < 64) begin
                if (s_r == 0 && s_p == 3 && vsp === 1'b1) obs[fw_k] = 1'b1;
                if (s_r == 1 && s_p == 5 && vsp === 1'b1) obs[64 + fw_k] = 1'b1;
                if (s_r == 2 && s_p == 5 && rvv === 1'b1) obs[128 + fw_k] = 1'b1;
            end
        end else begin                                          // HRTC or VRTC ([D79] 1-163 pins 7, 8)
            n_ret = n_ret + 1;
            if (vsp !== 1'b1) begin
                n_erv = n_erv + 1;
                if (n_erv <= 2) begin
                    $sformat(msg, "vsp: %0s: retrace line %0d char %0d: VSP %b, expected 1 (frame %0d)", fw_lbl, tl, tc, vsp, tfr);
                    err(msg, ID_VSP);
                end
            end
            if (lten !== 1'b0) begin
                n_erl = n_erl + 1;
                if (n_erl <= 2) begin
                    $sformat(msg, "vsp: %0s: retrace line %0d char %0d: LTEN %b, expected 0 (frame %0d)", fw_lbl, tl, tc, lten, tfr);
                    err(msg, ID_VSP);
                end
            end
        end
    end
endtask
// the end of a window frame: the samples of each output against the positions the reference checks
task frame_counts;
    integer r, ln, p;
    begin
        for (o = 0; o < 8; o = o + 1) x_s[o] = 0;
        for (r = 0; r < NR; r = r + 1)
            for (ln = 0; ln < NL; ln = ln + 1)
                for (p = 0; p < NH; p = p + 1) begin
                    ref_out(fw_mode, r, ln, p);
                    for (o = 0; o < 8; o = o + 1) x_s[o] = x_s[o] + e_m[7 - o];
                end
        for (o = 0; o < 8; o = o + 1)
            if (n_s[o] != x_s[o]) begin
                $sformat(msg, "%0s: %0s: %0d %0s samples in the frame, expected %0d", fw_top, fw_lbl, n_s[o], oname(o), x_s[o]);
                err(msg, fw_id);
            end
        if (n_ret != NRET) begin
            $sformat(msg, "vsp: %0s: %0d retrace CCLK falls checked in the frame, expected %0d", fw_lbl, n_ret, NRET); err(msg, ID_VSP);
        end
        for (o = 0; o < 8; o = o + 1)
            if (n_e[o] > 2) begin
                $sformat(msg, "%0s: %0s: %0d %0s mismatches in the frame (2 shown)", o <= 1 ? "cc" : fw_top, fw_lbl, n_e[o], oname(o));
                err(msg, o <= 1 ? ID_CC : fw_id);
            end
        if (n_erv > 2 || n_erl > 2) begin
            $sformat(msg, "vsp: %0s: %0d VSP, %0d LTEN retrace mismatches in the frame (2 of each shown)", fw_lbl, n_erv, n_erl);
            err(msg, ID_VSP);
        end
    end
endtask
// the blink runs of a window (CRT-36): every complete run per frames, the first and last at most that long, at least
// three changes; from the outputs only (any phase)
task runs(input integer base, input integer n, input integer per, input [8*48-1:0] what);
    integer i, last, nch;
    reg ok;
    begin
        last = 0; nch = 0; ok = 1'b1;
        for (i = 1; i < n; i = i + 1)
            if (obs[base + i] !== obs[base + i - 1]) begin
                if (ok && (nch > 0 ? i - last != per : i > per)) begin
                    ok = 1'b0;
                    $sformat(msg, "blink: %0s: a run of %0d frames (window frames %0d..%0d), expected %0d", what, i - last, last, i - 1, per);
                    err(msg, ID_BL);
                end
                last = i; nch = nch + 1;
            end
        if (ok && n - last > per) begin
            $sformat(msg, "blink: %0s: a run of %0d frames at the end of the window, expected at most %0d", what, n - last, per);
            err(msg, ID_BL);
        end
        if (nch < 3) begin
            $sformat(msg, "blink: %0s: %0d changes in %0d frames, expected at least 3", what, nch, n); err(msg, ID_BL);
        end
    end
endtask
task frame_edge; begin
    if (fw_on) begin
        frame_counts;
        fw_k = fw_k + 1;
        if (fw_k >= fw_nfr) begin
            fw_on = 1'b0; fw_done = 1'b1;
            if (fw_obs) begin
                runs(0, fw_nfr, 16, "character attribute E6h at row 0 char 3, VSP (frame / 32)");
                runs(64, fw_nfr, 16, "field attribute 82h, row 1 char 5, VSP (frame / 32)");
                runs(128, fw_nfr, 8, "cursor CC = 00 at row 2 char 5, RVV (frame / 16)");
            end
        end
    end
    fw_r0x = fw_ur >= 0; fw_ur = -1;
    if (fw_arm) begin fw_arm = 1'b0; fw_on = 1'b1; fw_k = 0; end
    if (fw_on) begin
        fw_mode = img_mode; n_ret = 0; n_erv = 0; n_erl = 0;
        for (o = 0; o < 8; o = o + 1) begin n_s[o] = 0; n_e[o] = 0; end
        if (u_req) begin u_req = 1'b0; fw_ur = U_ROW; u_arm = 1'b1; end
        if (fw_k < 64) begin obs[fw_k] = 1'b0; obs[64 + fw_k] = 1'b0; obs[128 + fw_k] = 1'b0; end
    end
end endtask
always @(posedge clk) begin
    hr_ev = hrtc === 1'b1 && hrtc_q === 1'b0;
    hf_ev = hrtc === 1'b0 && hrtc_q === 1'b1;
    vr_ev = vrtc === 1'b1 && vrtc_q === 1'b0;
    vf_ev = vrtc === 1'b0 && vrtc_q === 1'b1;
    wf_ev = dma_wr_n === 1'b0 && dwr_q === 1'b1;
    wu_ev = dma_wr_n === 1'b1 && dwr_q === 1'b0;
    if (vr_ev) tfr = tfr + 1;
    if (hf_ev) begin tl = tl + 1; tc = 0; end
    else if (cclk_q) tc = tc + 1;
    if (vf_ev) begin tl = -1; ri = 0; if (vf_seen) synced = 1'b1; vf_seen = 1'b1; end
    else if (hr_ev && synced && (tl + 1) % m_nl == 0) ri = (tl + 1) / m_nl;
    rs_ev = hr_ev && synced && (tl + 1) % m_nl == 0;
    if (rs_ev) begin                                    // a row start: the fill of the next row begins
        if (vf_ev) frame_edge;
        if (ri == m_nr - 1) begin img_mode = img_next; n_r3 = n_r3 + 1; end
        w_open = 1'b1; w_row = ri; w_tgt = ri == m_nr + m_nv - 1 ? 0 : ri + 1; w_mode = img_mode; w_tr = 0;
        if (u_stop && ri == U_ROW) begin u_stop = 1'b0; u_arm = 1'b0; end
    end
    if (wf_ev && dack_n === 1'b0) in_dma = 1'b1;
    if (wu_ev && in_dma) begin in_dma = 1'b0; w_tr = w_tr + 1; end
    if (cclk_q && synced && fw_on) sample;
    hrtc_q = hrtc; vrtc_q = vrtc; dwr_q = dma_wr_n; cclk_q = cclk;
    //---------------- the DMA stand-in
    if (ce16) begin
        case (dst)
            0: if (drq === 1'b1 && !u_stop) begin
                if (u_arm && w_open && w_row == U_ROW - 1 && w_tr >= 3) u_stop = 1'b1;   // stops answering in the row 2 fill
                else begin dst = 1; dcnt = 0; end
            end
            1: begin
                dcnt = dcnt + 1;
                if (dcnt >= 2 && !cpu_busy) begin
                    if (drq === 1'b1 && !u_stop) begin
                        s_k = w_tr;
                        s_byte = w_open && w_tgt < NR && s_k < KMAX ? ims[(w_mode * NR + w_tgt) * KMAX + s_k] : 8'h20;
                        dack_n <= 1'b0; dma_d <= s_byte; dst = 2; dcnt = 0;
                    end else dst = 0;
                end
            end
            2: begin dcnt = dcnt + 1; if (dcnt == 1) begin dma_wr_n <= 1'b0; dst = 3; dcnt = 0; end end
            default: begin
                dcnt = dcnt + 1;
                if (dcnt == 3) begin dma_wr_n <= 1'b1; dack_n <= 1'b1; dst = 0; end
            end
        endcase
    end
    st_q = n16; if (ce16) n16 = n16 + 1;
end
//---------------- CPU bus (the bus is free of the stand-in: DACK and its WR high)
reg [7:0] sv;
integer nb;
task bus_free; begin
    @(negedge clk); nb = 0;
    while (!dack_n || !dma_wr_n) begin
        @(negedge clk); nb = nb + 1;
        if (nb > 2000) begin $display("FATAL: vg75_attr: bus: the DMA stand-in holds the bus timed out"); $finish; end
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
// a status read (A0 = 1): the bits of mask mk against e, one message per bit
task stat_chk(input [7:0] e, input [7:0] mk, input [8*48-1:0] where);
    integer b;
    begin
        rd(1'b1, sv);
        for (b = 7; b >= 0; b = b - 1)
            if (mk[b] && sv[b] !== e[b]) begin
                $sformat(msg, "%0s: %0s: status bit %0d (%0s) %b, expected %b", fw_top, where, b, fname(b), sv[b], e[b]);
                err(msg, fw_id);
            end
    end
endtask
task wait_n(input integer n);
    integer tlim;
    begin tlim = n16 + n; while (n16 < tlim) @(negedge clk); end
endtask
// Reset with its four parameters (VE reset, [D79] 1-178); the raster model stays in step when the lengths and S are
// those already running, else it resyncs at the second VRTC fall
task program(input [7:0] p3, input [7:0] p4, input sp);
    reg same;
    reg [7:0] p1;
    begin
        p1 = {sp, P1[6:0]};
        wr(1'b1, 8'h00); t_ve = 1'b0; wr(1'b0, p1); wr(1'b0, P2); wr(1'b0, p3); wr(1'b0, p4);
        same = m_sp == p1[7] && m_nh == p1[6:0] + 1 && m_nv == P2[7:6] + 1 && m_nr == P2[5:0] + 1
            && m_nl == p3[3:0] + 1 && m_z == p4[3:0];
        m_sp = p1[7]; m_nh = p1[6:0] + 1; m_nv = P2[7:6] + 1; m_nr = P2[5:0] + 1;
        m_u = p3[7:4]; m_nl = p3[3:0] + 1; m_m = p4[7]; m_c = p4[5:4]; m_z = p4[3:0];
        if (p4[6] || m_nh != NH || m_nr != NR || m_nv != NV || m_nl != NL || m_z != NZ) begin
            $display("FATAL: vg75_attr: program: the TB is written for 0Fh 03h x9h x3h, transparent attributes"); $finish;
        end
        if (!same) begin synced = 1'b0; vf_seen = 1'b0; w_open = 1'b0; end
    end
endtask
task start_display; begin wr(1'b1, 8'h23); t_ve = 1'b1; end endtask      // SSS = 000, BB = 11
task load_cursor(input integer c, input integer r); begin
    wr(1'b1, 8'h80); wr(1'b0, c); wr(1'b0, r); cur_c = c; cur_r = r;
end endtask
task topic(input [8*48-1:0] top, input [8*40-1:0] id); begin fw_top = top; fw_id = id; end endtask
// a window of n frames of image m: the image from the next row 3 start (after the commands before it), the window
// from the VRTC fall after that
task window(input integer m, input integer n, input [8*48-1:0] lbl);
    integer c;
    begin
        img_next = m; c = n_r3;
        `WAIT_UNTIL(n_r3 > c, 5 * FRAME, "window: the row 3 start")
        fw_lbl = lbl; fw_nfr = n; fw_done = 1'b0; fw_arm = 1'b1;
        `WAIT_UNTIL(fw_done, (n + 2) * FRAME, "window: the frames")
    end
endtask
initial begin
    wait (n16 >= 5000000); $display("FATAL: vg75_attr: run timed out"); $finish;
end
initial begin
    build;
    wait_n(240);
    program(8'h99, 8'h83, 1'b0); load_cursor(79, 63); start_display;   // the cursor off the screen (row 63)
    //---------------- 4. CRT-33 the cursor, the first frames: CC = 00 (an image without underline)
    topic("cursor", ID_CUR);
    load_cursor(5, 0); window(IM_CUR0, 9, "CC = 00, cursor at row 0 char 5");
    //---------------- 7. CRT-36 the blink rates: 49 frames (every frame counter value mod 32)
    topic("blink", ID_BL);
    load_cursor(5, 2);
    fw_obs = 1'b1; window(IM_BLINK, 49, "CC = 00, cursor at row 2 char 5"); fw_obs = 1'b0;
    //---------------- 1. CRT-30 character attributes: UUUU = 9, 7 (17 frames: both blink phases), 8, 10, 0
    topic("char attribute", ID_CA);
    load_cursor(79, 63);
    program(8'h99, 8'h93, 1'b0); start_display; window(IM_CA, 17, "UUUU = 9");
    program(8'h79, 8'h93, 1'b0); start_display; window(IM_CA, 17, "UUUU = 7");
    program(8'h89, 8'h93, 1'b0); start_display; window(IM_CA, 1, "UUUU = 8");
    program(8'hA9, 8'h93, 1'b0); start_display; window(IM_CA, 1, "UUUU = 10 (LLLL = 9)");
    program(8'h09, 8'h93, 1'b0); start_display; window(IM_CA, 1, "UUUU = 0");
    //---------------- 4. CRT-33 the cursor: four formats; R and U fields; the cells at the corners
    topic("cursor", ID_CUR);
    program(8'h99, 8'h83, 1'b0); start_display; load_cursor(5, 0); window(IM_CUR, 1, "CC = 00, cursor at row 0 char 5 (U field image)");
    program(8'h99, 8'h93, 1'b0); start_display; window(IM_CUR, 9, "CC = 01, cursor at row 0 char 5");
    program(8'h99, 8'hA3, 1'b0); start_display; window(IM_CUR, 9, "CC = 10, cursor at row 0 char 5");
    load_cursor(5, 1); window(IM_CUR, 1, "CC = 10, cursor at row 1 char 5 (R field)");
    load_cursor(0, 0); window(IM_CUR, 1, "CC = 10, cursor at row 0 char 0");
    load_cursor(15, 3); window(IM_CUR, 1, "CC = 10, cursor at row 3 char 15");
    program(8'h99, 8'hB3, 1'b0); start_display; load_cursor(5, 0); window(IM_CUR, 9, "CC = 11, cursor at row 0 char 5");
    load_cursor(5, 2); window(IM_CUR, 1, "CC = 11, cursor at row 2 char 5 (U field)");
    load_cursor(15, 3); window(IM_CUR, 1, "CC = 11, cursor at row 3 char 15");
    // the underline line beyond the last line: no underline ([D79] 1-170), neither the U field nor the cursor
    program(8'hA9, 8'hB3, 1'b0); start_display; load_cursor(5, 2);
    window(IM_CUR, 1, "CC = 11, UUUU = 10 (LLLL = 9), cursor at row 2 char 5");
    stat_chk(8'h00, 8'h0B, "after the cursor frames");
    load_cursor(79, 63);
    //---------------- 2. CRT-31 field attributes: three frames (the second and third begin after a frame that ends
    // inside a U R H field)
    topic("field attribute", ID_FA);
    program(8'h99, 8'h93, 1'b0); start_display; window(IM_FA, 3, "UUUU = 9");
    //---------------- 3. CRT-32 character attributes inside fields (17 frames: both blink phases)
    topic("interaction", ID_INT);
    window(IM_INT, 17, "UUUU = 9");
    stat_chk(8'h00, 8'h0B, "after the attribute frames");
    //---------------- 5. CRT-34 VSP: End of Row / Screen, spaced rows, an underrun, VE = 0
    topic("vsp", ID_VSP);
    window(IM_VSP, 2, "End of Row, End of Screen");
    program(8'h99, 8'h93, 1'b1); start_display; window(IM_PLAIN, 1, "spaced rows");
    program(8'h99, 8'h93, 1'b0); start_display; window(IM_PLAIN, 1, "UUUU = 9");
    stat_chk(8'h00, 8'h02, "before the underrun");
    u_req = 1'b1; window(IM_PLAIN, 2, "an underrun in the row 2 fill");
    stat_chk(8'h02, 8'h02, "after the underrun (no status read since)");
    stat_chk(8'h00, 8'h02, "the status read after DU");
    wr(1'b1, 8'h40); t_ve = 1'b0; window(IM_PLAIN, 1, "VE = 0 (40h)"); start_display;
    //---------------- 6. CRT-35 CC, LC: the codes 00h-7Fh, M = 0 and M = 1
    topic("cc", ID_CC);
    program(8'h99, 8'h33, 1'b0); start_display; window(IM_CC0, 1, "M = 0"); window(IM_CC1, 1, "M = 0");
    program(8'h99, 8'hB3, 1'b0); start_display; window(IM_CC0, 1, "M = 1"); window(IM_CC1, 1, "M = 1");
    stat_chk(8'h00, 8'h0B, "at the end");
    if (errors == 0) $display("PASS: vg75_attr (%0d ce16)", n16);
    $finish;
end
endmodule
`default_nettype wire
