// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license.
// For complete licensing information see LICENSE.TXT.
// --------------------------------------------------------------------
//
// An open implementation of K580VT57 DMA controller
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
// Modifications: Sorgelig (MiSTer-devel/Apogee_MiSTer rtl/k580vt57.v at
// 4b37da252517ceae3306a56a9eef08290259b098).
// Rewritten to the Intel 8257 data sheet ([C78] 12-98..12-110) for the Radio-86RK 16 MHz machine
// (karabas-go-core-rk86, rk86_16/); kept from the base: the register write decoding by {F/L, A3-A0}.
//   - the states SI, S0, S1, S2, S3, SW, S4 of Fig. 6 on both clock edges: states, DACK, AEN↑, IOR↑ / MEMR↑
//     and the DRQ / HLDA / READY decisions at θ↓ (th_dn); HRQ, AEN↓, ADSTB, the write strobes, TC, MARK
//     and the address update at θ↑ (th_up)
//   - at the θ↓ that starts S4: DRQ and HLDA → S1 after S4; otherwise (no DRQ, or HLDA lost) HRQ↓ at
//     θ↑(S4) and SI after S4 (Fig. 6); with DRQ still active SI → S0 raises HRQ again ([C78] 12-105,
//     12-110 "control override sequence")
//   - verify / write / read cycles; extended write (mode bit 5): MEMW / IOW from θ↑(S2)
//   - READY sampled at θ↑ of S3 and SW: wait states SW (not in verify cycles)
//   - four channels, fixed or rotating priority, TC stop, autoload with the update flag (set with TC↑,
//     Fig. 5), MARK
//   - the status register, register reads, the first / last flip-flop; CS ignored in master mode
//   - the address and count change at θ↑ after S4: the address stays valid through IOR↑
`default_nettype none
module k580vt57(
    input  wire        clk,
    input  wire        th_up,
    input  wire        th_dn,
    input  wire        reset,
    input  wire        cs_n,
    input  wire        ior_n_i,
    input  wire        iow_n_i,
    input  wire  [3:0] a_i,
    input  wire  [7:0] d_i,
    output wire  [7:0] d_o,
    input  wire  [3:0] drq,
    input  wire        hlda,
    input  wire        ready,
    output reg         hrq = 1'b0,
    output wire  [3:0] dack_n,
    output wire [15:0] a_o,
    output reg         aen = 1'b0,
    output reg         adstb = 1'b0,
    output reg         memr_n = 1'b1,
    output reg         memw_n = 1'b1,
    output reg         ior_n_o = 1'b1,
    output reg         iow_n_o = 1'b1,
    output reg         tc = 1'b0,
    output reg         mark = 1'b0
);
localparam [2:0] SI = 3'd0, S0 = 3'd1, S1 = 3'd2, S2 = 3'd3, S3 = 3'd4, SW = 3'd5, S4 = 3'd6;
reg  [2:0] state = SI;
reg  [7:0] mode = 8'h00;           // AL TCS EW RP EN3 EN2 EN1 EN0
reg [15:0] ad [0:3];               // DMA address registers
reg [15:0] tr [0:3];               // terminal count registers: 15:14 the cycle, 13:0 N - 1
reg  [3:0] tcs = 4'd0;             // TC status bits
reg        upd = 1'b0;             // update flag
reg        reload = 1'b0;          // channel 2 takes channel 3 at its next S1
reg        upd_cyc = 1'b0;         // the current cycle is the reload cycle
reg        ff = 1'b0;              // first / last flip-flop
reg  [1:0] ch = 2'd0;
reg  [1:0] top = 2'd0;             // the channel with the highest priority
reg        cont = 1'b0;            // decided at the θ↓ that starts S4: S1 next (DRQ and HLDA), HRQ stays high
reg  [1:0] cont_ch = 2'd0;
reg        rdy = 1'b1;
reg        dack_on = 1'b0;
reg        done = 1'b0, done_tc = 1'b0, done_upd = 1'b0;
reg  [1:0] done_ch = 2'd0;
reg        iow_q = 1'b1, ior_q = 1'b1, w_cs = 1'b0, r_cs = 1'b0;
reg  [3:0] w_a = 4'd0, r_a = 4'd0;
reg  [7:0] w_d = 8'h00;
integer k;
initial for (k = 0; k < 4; k = k + 1) begin ad[k] = 16'h0000; tr[k] = 16'h0000; end

function [2:0] pick(input [3:0] r, input [1:0] t);   // {request, channel}: the first request from channel t on
    integer i;
    reg [1:0] c;
    begin
        pick = 3'b000;
        for (i = 3; i >= 0; i = i - 1) begin
            c = t + i[1:0];
            if (r[c]) pick = {1'b1, c};
        end
    end
endfunction

wire [2:0] p = pick(drq & mode[3:0], top);
wire master = state == S1 || state == S2 || state == S3 || state == SW || state == S4;
wire [13:0] cnt = tr[ch][13:0];
wire [1:0] cyc = tr[ch][15:14];                      // 00 verify, 01 write, 10 read, 11 illegal (SILENT: no strobes)
wire wr_cyc = cyc == 2'b01;
wire rd_cyc = cyc == 2'b10;
wire tc_now = cnt == 14'd0;
// the requests after this cycle, for the S4 decision: TC stop takes the channel out, rotation moves the priority
wire tc_off = tc_now && mode[6] && !(mode[7] && ch == 2'd2);
wire [3:0] en_after = mode[3:0] & ~(tc_off ? (4'd1 << ch) : 4'd0);
wire [1:0] top_after = mode[4] ? ch + 2'd1 : 2'd0;
wire [2:0] p4 = pick(drq & en_after, top_after);
// the address and count change at θ↑ after S4 ([C78] 12-109 TAH: valid through the strobes)
wire upd_now = th_up && done;
wire [1:0] uch = done_ch;
wire utc = done_tc;
wire uupd = done_upd;
assign dack_n = dack_on ? ~(4'd1 << ch) : 4'hF;
assign a_o = ad[ch];
wire [15:0] rsel = a_i[0] ? tr[a_i[2:1]] : ad[a_i[2:1]];
assign d_o = a_i[3] ? {3'b000, upd, tcs} : (ff ? rsel[15:8] : rsel[7:0]);

always @(posedge clk) begin
    iow_q <= iow_n_i;
    ior_q <= ior_n_i;
    if (!iow_n_i) begin w_cs <= !cs_n && !master; w_a <= a_i; w_d <= d_i; end
    if (!ior_n_i) begin r_cs <= !cs_n && !master; r_a <= a_i; end
    if (reset) begin
        state <= SI; mode <= 8'h00; tcs <= 4'd0; upd <= 1'b0; reload <= 1'b0; upd_cyc <= 1'b0;
        ff <= 1'b0; top <= 2'd0; cont <= 1'b0; rdy <= 1'b1;
        hrq <= 1'b0; aen <= 1'b0; adstb <= 1'b0; memr_n <= 1'b1; memw_n <= 1'b1; ior_n_o <= 1'b1; iow_n_o <= 1'b1;
        tc <= 1'b0; mark <= 1'b0; dack_on <= 1'b0; done <= 1'b0;
    end else begin
        //---------------- slave: a register write completes on IOW↑ ([C78] 12-105)
        if (iow_n_i && !iow_q && w_cs) begin
            if (w_a[3]) begin
                if (w_a[2:0] == 3'd0) begin                 // SILENT: other A2-A0 with A3 = 1 ignored
                    mode <= w_d; ff <= 1'b0; top <= 2'd0;
                    if (!w_d[7]) begin upd <= 1'b0; reload <= 1'b0; end
                end
            end else begin
                if (w_a[0]) begin
                    if (ff) tr[w_a[2:1]][15:8] <= w_d; else tr[w_a[2:1]][7:0] <= w_d;
                    if (mode[7] && w_a[2:1] == 2'd2) begin if (ff) tr[3][15:8] <= w_d; else tr[3][7:0] <= w_d; end
                end else begin
                    if (ff) ad[w_a[2:1]][15:8] <= w_d; else ad[w_a[2:1]][7:0] <= w_d;
                    if (mode[7] && w_a[2:1] == 2'd2) begin if (ff) ad[3][15:8] <= w_d; else ad[3][7:0] <= w_d; end
                end
                ff <= !ff;
            end
        end
        //---------------- slave: a register read completes on IOR↑; a status read clears the TC bits
        if (ior_n_i && !ior_q && r_cs) begin
            if (r_a[3]) tcs <= 4'd0; else ff <= !ff;
        end
        //---------------- θ↓: the states, DACK, AEN↑, IOR↑ / MEMR↑, the DRQ / HLDA / READY decisions
        if (th_dn) begin
            case (state)
                SI: if (p[2]) state <= S0;                                // DMA-16: pin-equivalent label
                S0: if (!p[2]) state <= SI;                               // SILENT: DMA-16
                    else if (hlda) begin
                        state <= S1; ch <= p[1:0]; aen <= 1'b1;
                        if (reload && p[1:0] == 2'd2) begin ad[2] <= ad[3]; tr[2] <= tr[3]; reload <= 1'b0; upd_cyc <= 1'b1; end
                    end
                S1: begin state <= S2; dack_on <= 1'b1; end
                S2: state <= S3;
                S3, SW:
                    if (rdy || cyc == 2'b00) begin
                        state <= S4;
                        cont <= hlda && p4[2]; cont_ch <= p4[1:0];
                    end else state <= SW;
                S4: begin
                        dack_on <= 1'b0; ior_n_o <= 1'b1; memr_n <= 1'b1;
                        done <= 1'b1; done_ch <= ch; done_tc <= tc_now; done_upd <= upd_cyc; upd_cyc <= 1'b0;
                        if (cont) begin
                            state <= S1; ch <= cont_ch;
                            if (reload && cont_ch == 2'd2) begin ad[2] <= ad[3]; tr[2] <= tr[3]; reload <= 1'b0; upd_cyc <= 1'b1; end
                        end else state <= SI;                                // no DRQ, or HLDA lost (DMA-15)
                    end
                default: state <= SI;
            endcase
        end
        //---------------- θ↑: HRQ, AEN↓, ADSTB, the write strobes, TC, MARK, READY, the address update
        if (th_up) begin
            hrq <= state == S0 || state == S1 || state == S2 || state == S3 || state == SW || (state == S4 && cont);
            if (state == SI || state == S0) aen <= 1'b0;                 // not the bus master (rel 40)
            adstb <= state == S1;
            if (state == S2) begin
                if (wr_cyc) ior_n_o <= 1'b0;
                if (rd_cyc) memr_n <= 1'b0;
                if (mode[5] && wr_cyc) memw_n <= 1'b0;
                if (mode[5] && rd_cyc) iow_n_o <= 1'b0;
            end
            if (state == S3) begin
                if (wr_cyc) memw_n <= 1'b0;
                if (rd_cyc) iow_n_o <= 1'b0;
            end
            if (state == S4) begin memw_n <= 1'b1; iow_n_o <= 1'b1; end
            tc <= (state == S3 || state == SW) && tc_now;
            mark <= (state == S3 || state == SW) && cnt[6:0] == 7'd0;                // DMA-11: the TC window
            if (state == S3 && tc_now) tcs[ch] <= 1'b1;
            if (state == S3 && tc_now && mode[7] && ch == 2'd2) begin upd <= 1'b1; reload <= 1'b1; end  // with TC↑ (DMA-24)
            if (state == S3 || state == SW) rdy <= ready;
        end
        if (upd_now) begin
            done <= 1'b0;
            if (!(utc && mode[7] && uch == 2'd2)) begin                              // SILENT: skipped before a reload
                ad[uch] <= ad[uch] + 16'd1;
                tr[uch][13:0] <= tr[uch][13:0] - 14'd1;
            end
            if (utc && mode[6] && !(mode[7] && uch == 2'd2)) mode[uch] <= 1'b0;     // TC stop
            if (mode[4]) top <= uch + 2'd1;                                           // rotating priority
            if (uupd) upd <= 1'b0;                                                    // the reload cycle is over
        end
    end
end
endmodule
`default_nettype wire
