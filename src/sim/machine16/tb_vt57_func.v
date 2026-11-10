// k580vt57 against every function of the 8257 data sheet ([C78] 12-98..12-110; Task 2 DMA-n). The clock,
// the 8080 stand-in and the bus tasks are those of tb_vt57.v; rel = sample - S1 - 1 as there.
// Every ce16 sample of the pins goes into a history (hist); after each stimulus the checks read it per transfer
// (S1 from ADSTB↑, the channel from DACK at rel 10) against the data sheet edges: AEN 0..39, ADSTB 4..12,
// DACK 9..35, the read strobe 13..35, the write strobe 22..30 (extended 13..30), TC / MARK 22..30, HRQ to 30
// (or on through a back-to-back S1), the address from rel 4 through rel 39; each SW adds 9 ([C78] 12-109, 12-110).
// The update flag is read on d_o with A = 8 (the status register) between the slave accesses.
`default_nettype none
`timescale 1ns/1ns
module tb_vt57_func;
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
reg [3:0] step = 4'd0;
always @(posedge clk) if (ce16) step <= step == 4'd8 ? 4'd0 : step + 4'd1;
wire f1 = ce16 && step == 4'd0;
wire f2 = ce16 && step == 4'd2;
wire f2_fall = ce16 && step == 4'd7;
reg reset = 1'b1, cs_n = 1'b1, ior_n = 1'b1, iow_n = 1'b1, ready = 1'b1;
reg [3:0] a = 4'd0;
reg [7:0] d = 8'h00;
reg [3:0] drq = 4'd0;
reg hold_s = 1'b0, hlda = 1'b0, hlda_off = 1'b0;
wire [7:0] d_o;
wire [3:0] dack_n;
wire [15:0] a_o;
wire hrq, aen, adstb, memr_n, memw_n, ior_n_o, iow_n_o, tc, mark;
k580vt57 dut(.clk(clk), .th_up(f2), .th_dn(f2_fall), .reset(reset), .cs_n(cs_n), .ior_n_i(ior_n), .iow_n_i(iow_n),
    .a_i(a), .d_i(d), .d_o(d_o), .drq(drq), .hlda(hlda), .ready(ready), .hrq(hrq), .dack_n(dack_n),
    .a_o(a_o), .aen(aen), .adstb(adstb), .memr_n(memr_n), .memw_n(memw_n), .ior_n_o(ior_n_o), .iow_n_o(iow_n_o),
    .tc(tc), .mark(mark));
// the 8080 of tb_vt57.v: HOLD sampled at Φ2↑, HLDA at the next Φ1↑; hlda_off holds HLDA low (DMA-15, DMA-16)
always @(posedge clk) begin
    if (f2) hold_s <= hrq;
    if (f1) hlda <= hold_s && !hlda_off;
end
// the requesters: rmode[c] 0 held, 1 per strobe; ctype[c] the cycle type programmed for channel c
// (count bits 15:14); left[c] the transfers still to request
reg [3:0] rmode = 4'd0;
reg [1:0] ctype [0:3];
integer left [0:3];
reg [3:0] dack_q = 4'hF;
reg ior_q = 1'b1, iow_q = 1'b1;
integer c, k;
initial for (k = 0; k < 4; k = k + 1) begin left[k] = 0; ctype[k] = 2'b01; end
always @(posedge clk) begin
    for (c = 0; c < 4; c = c + 1) begin
        if (!dack_n[c] && dack_q[c]) begin                                  // a transfer of channel c begins
            left[c] = left[c] - 1;
            if (!rmode[c] && left[c] <= 0) drq[c] <= 1'b0;                  // held: down at the last DACK↓
            if (rmode[c] && ctype[c] == 2'b00) drq[c] <= 1'b0;              // per strobe, verify: at DACK↓
        end
        if (rmode[c] && !dack_n[c]) begin
            if (ctype[c] == 2'b01 && !ior_n_o && ior_q) drq[c] <= 1'b0;     // write cycle: at IOR↓
            if (ctype[c] == 2'b10 && !iow_n_o && iow_q) drq[c] <= 1'b0;     // read cycle: at IOW↓
        end
        if (rmode[c] && left[c] > 0 && !dack_q[c] &&
            ((ctype[c] == 2'b01 && ior_n_o && !ior_q) || (ctype[c] == 2'b10 && iow_n_o && !iow_q) ||
             (ctype[c] == 2'b00 && dack_n[c]))) drq[c] <= 1'b1;
    end
    dack_q <= dack_n; ior_q <= ior_n_o; iow_q <= iow_n_o;
end
task request(input integer ch, input integer n, input md); begin
    @(negedge clk) begin rmode[ch] = md; left[ch] = n; drq[ch] = n > 0; end
end endtask
// several channels at the same clock: mask m, n transfers each, mode md
task request_all(input [3:0] m, input integer n, input md); begin
    @(negedge clk) for (k = 0; k < 4; k = k + 1) if (m[k]) begin rmode[k] = md; left[k] = n; drq[k] = n > 0; end
end endtask
// the event log: S1 from ADSTB↑ (θ↑ S1 = rel 4); the channel from DACK at rel 10
integer n16 = 0, s1 = -1000, rel, ntr = 0, errors = 0;
integer s1_of [0:4095];
reg [1:0] ch_of [0:4095];
reg adstb_q = 1'b0;
// the pin history: hist[n] = the sample at ce16 n, {0, HLDA, UP (d_o[4] with A = 8), MARK, TC, IOW, IOR, MEMW, MEMR,
// DACK3-0, ADSTB, AEN, HRQ, A15-A0}
localparam HB = 18;
reg [31:0] hist [0:(1 << HB) - 1];
integer quiet = 0, holds = 0, hrq_up = -1000, hlda_up = -1000, rdy_hi = -1, rdy_t0 = 0;
reg hrq_q = 1'b0, hlda_q = 1'b0;
always @(posedge clk) if (ce16) begin
    if (adstb && !adstb_q) s1 = n16 - 5;
    rel = n16 - s1 - 1;
    if (rel == 10) begin
        s1_of[ntr] = s1;
        ch_of[ntr] = !dack_n[0] ? 2'd0 : !dack_n[1] ? 2'd1 : !dack_n[2] ? 2'd2 : 2'd3;
        ntr = ntr + 1;
    end
    hist[n16 % (1 << HB)] = {1'b0, hlda, (a == 4'd8) ? d_o[4] : 1'bx, mark, tc, iow_n_o, ior_n_o, memw_n, memr_n,
        dack_n, adstb, aen, hrq, a_o};
    if (hrq && !hrq_q) begin hrq_up = n16 - 1; holds = holds + 1; end          // the edge of the rise
    if (hlda && !hlda_q) hlda_up = n16 - 1;
    quiet = (hrq || aen) ? 0 : quiet + 1;
    // READY of check 7: high from edge rdy_hi of the transfer that starts after rdy_t0 (set here, seen 2 edges on)
    if (rdy_hi >= 0 && s1 >= rdy_t0 && rel + 2 >= rdy_hi) begin ready <= 1'b1; rdy_hi = -1; end
    adstb_q = adstb; hrq_q = hrq; hlda_q = hlda;
    n16 = n16 + 1;
end
task chk(input ok, input [8*200-1:0] what); begin
    if (!ok) begin
        $display("ERROR: vt57f: %0s at ce16 %0d", what, n16); errors = errors + 1;
        if (errors >= 20) begin $display("FATAL: vt57f: too many errors"); $finish; end
    end end endtask
// the current check: ctx starts every message, ids is the data sheet reference; ntr0 the first transfer of the part
reg [8*24-1:0] ctx = "";
reg [8*64-1:0] ids = "";
reg [8*120-1:0] dmsg;
reg [8*200-1:0] msg;
integer ntr0 = 0, holds0 = 0;
task ck(input ok, input [8*120-1:0] detail); begin
    if (!ok) begin $sformat(msg, "%0s: %0s (%0s)", ctx, detail, ids); chk(1'b0, msg); end
end endtask
task part(input [8*24-1:0] cx_name, input [8*64-1:0] id_src); begin
    ctx = cx_name; ids = id_src; ntr0 = ntr; holds0 = holds;
end endtask
// wr57, rd57: copied from tb_vt57.v
task wr57(input [3:0] ad, input [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; d = dd; end
    @(negedge clk) iow_n = 1'b0;
    repeat (4) @(negedge clk); iow_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
task rd57(input [3:0] ad, output [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; end
    @(negedge clk) ior_n = 1'b0;
    repeat (4) @(negedge clk); dd = d_o; ior_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
// programming with the expected register model: exp_ad / exp_tr the address and the count (with the cycle bits)
// of the next transfer of each channel; mode_tb the last mode word
reg [15:0] exp_ad [0:3];
reg [15:0] exp_tr [0:3];
reg [7:0] mode_tb = 8'h00;
reg [7:0] v8;
reg [15:0] v16;
task mode_set(input [7:0] m); begin wr57(4'd8, m); a = 4'd8; mode_tb = m; end endtask
task prog(input [1:0] ch, input [15:0] adr, input [15:0] cnt); begin
    wr57({1'b0, ch, 1'b0}, adr[7:0]); wr57({1'b0, ch, 1'b0}, adr[15:8]);
    wr57({1'b0, ch, 1'b1}, cnt[7:0]); wr57({1'b0, ch, 1'b1}, cnt[15:8]);
    a = 4'd8;
    exp_ad[ch] = adr; exp_tr[ch] = cnt; ctype[ch] = cnt[15:14];
    if (mode_tb[7] && ch == 2'd2) begin exp_ad[3] = adr; exp_tr[3] = cnt; end
end endtask
task rd8(input [3:0] ad, output [7:0] v); begin rd57(ad, v); a = 4'd8; end endtask
task rd16(input [3:0] ad, output [15:0] v); reg [7:0] lo, hi; begin
    rd57(ad, lo); rd57(ad, hi); v = {hi, lo}; a = 4'd8;
end endtask
task wait_ce(input integer n); integer t0; begin
    t0 = n16; wait (n16 >= t0 + n); @(negedge clk);
end endtask
// the end of a stimulus: HRQ and AEN low for 150 ce16 (the 8257 in SI), at most 40 000 ce16
task wait_idle; integer t0; begin
    t0 = n16; @(negedge clk) quiet = 0;
    while (quiet < 150 && n16 - t0 < 40000) @(negedge clk);
    if (quiet < 150) ck(1'b0, "the transfers do not end");
end endtask
function [31:0] h(input integer s, input integer r);   // the sample at rel r of the transfer with S1 at s
    h = hist[(s + 1 + r) % (1 << HB)];
endfunction
// one transfer against the data sheet edges; one message per signal and transfer
reg [15:0] bad;
task sig(input integer b, input ok, input [8*12-1:0] name, input integer r, input integer j); begin
    if (!ok && !bad[b]) begin
        bad[b] = 1'b1;
        $sformat(dmsg, "%0s at %0d (transfer %0d)", name, r, j - ntr0);
        ck(1'b0, dmsg);
    end
end endtask
task xfer(input integer j, input [1:0] chx, input [15:0] adx, input [1:0] cy, input ex, input tcx, input mkx,
          input integer sw, input cx);
    integer r, s, e4, en;
    reg [31:0] v;
    begin
        bad = 16'h0000;
        s = s1_of[j]; e4 = 27 + 9 * sw; en = e4 + 9;           // S4 starts at e4, the next S1 / SI at en
        sig(15, ch_of[j] === chx, "channel", 10, j);
        for (r = 0; r <= en + 4; r = r + 1) begin
            v = h(s, r);
            if (r <= en + 3) begin
                sig(0, v[17] === 1'b1, "aen", r, j);
                sig(1, v[18] === (r >= 4 && r <= 12), "adstb", r, j);
                sig(2, v[22:19] === ((r >= 9 && r < en) ? ~(4'd1 << chx) : 4'hF), "dack", r, j);
                sig(3, v[25] === !(cy == 2'b01 && r >= 13 && r < en), "ior", r, j);
                sig(4, v[23] === !(cy == 2'b10 && r >= 13 && r < en), "memr", r, j);
                sig(5, v[24] === !(cy == 2'b01 && r >= (ex ? 13 : 22) && r <= e4 + 3), "memw", r, j);
                sig(6, v[26] === !(cy == 2'b10 && r >= (ex ? 13 : 22) && r <= e4 + 3), "iow", r, j);
                sig(7, v[27] === (tcx && r >= 22 && r <= e4 + 3), "tc", r, j);
                sig(8, v[28] === (mkx && r >= 22 && r <= e4 + 3), "mark", r, j);
                if (r >= 4) sig(9, v[15:0] === adx, "address", r, j);
            end else if (!cx) sig(0, v[17] === 1'b0, "aen", r, j);
            sig(10, v[16] === (r <= e4 + 3 || cx), "hrq", r, j);
        end
    end
endtask
// one transfer of channel ch against the register model; the model then counts (or reloads channel 2)
task xm(input integer j, input [1:0] ch, input integer sw, input cx);
    reg tcx;
    reg [15:0] t;
    begin
        t = exp_tr[ch];
        tcx = t[13:0] == 14'd0;
        xfer(j, ch, exp_ad[ch], t[15:14], mode_tb[5], tcx, t[6:0] == 7'd0, sw, cx);
        if (tcx && mode_tb[7] && ch == 2'd2) begin exp_ad[2] = exp_ad[3]; exp_tr[2] = exp_tr[3]; end
        else begin exp_ad[ch] = exp_ad[ch] + 16'd1; exp_tr[ch] = {t[15:14], t[13:0] - 14'd1}; end
    end
endtask
// the transfers of the part: n of them, channel of transfer i in ord (one hex digit each, the first on the left),
// back to back (S1 to S1 36) or each its own HOLD period (S1 to S1 72)
task one(input integer i, input integer n, input [1:0] ch, input b2b); integer p; begin
    if (ch_of[ntr0 + i] !== ch) begin
        $sformat(dmsg, "order: transfer %0d channel %0d, expected %0d", i, ch_of[ntr0 + i], ch); ck(1'b0, dmsg);
    end
    xm(ntr0 + i, ch, 0, b2b && i < n - 1);
    p = b2b ? 36 : 72;
    if (i > 0 && s1_of[ntr0 + i] - s1_of[ntr0 + i - 1] != p) begin
        $sformat(dmsg, "S1 to S1 %0d before transfer %0d, expected %0d", s1_of[ntr0 + i] - s1_of[ntr0 + i - 1], i, p);
        ck(1'b0, dmsg);
    end
end endtask
task count_is(input integer n); begin
    if (ntr - ntr0 != n) begin $sformat(dmsg, "%0d transfers, expected %0d", ntr - ntr0, n); ck(1'b0, dmsg); end
end endtask
task run_order(input integer n, input [4*32-1:0] ord, input b2b); integer i; begin
    count_is(n);
    for (i = 0; i < n && ntr0 + i < ntr; i = i + 1) one(i, n, ord[4 * (n - 1 - i) +: 2], b2b);
end endtask
task run_ch(input integer n, input [1:0] ch, input b2b); integer i; begin
    count_is(n);
    for (i = 0; i < n && ntr0 + i < ntr; i = i + 1) one(i, n, ch, b2b);
end endtask
task holds_is(input integer n); begin
    if (holds - holds0 != n) begin $sformat(dmsg, "%0d HOLD periods, expected %0d", holds - holds0, n); ck(1'b0, dmsg); end
end endtask
task status_is(input [7:0] e, input [8*40-1:0] what); begin
    rd8(4'd8, v8);
    if (v8 !== e) begin $sformat(dmsg, "%0s: status %h, expected %h", what, v8, e); ck(1'b0, dmsg); end
end endtask
task reg_is(input [3:0] ad, input [15:0] e, input [8*40-1:0] what); begin
    rd16(ad, v16);
    if (v16 !== e) begin $sformat(dmsg, "%0s: register %0d reads %h, expected %h", what, ad, v16, e); ck(1'b0, dmsg); end
end endtask
// the update flag (status bit 4 on d_o) at rel r of transfer j
task upd_is(input integer j, input integer r, input e); reg [31:0] v; begin
    v = h(s1_of[j], r);
    if (v[29] !== e) begin
        $sformat(dmsg, "update flag at %0d (transfer %0d) %b, expected %b", r, j - ntr0, v[29], e); ck(1'b0, dmsg);
    end
end endtask
integer i, j, s, t, r;
reg [31:0] hv;
initial begin
    #(40000000) $display("FATAL: vt57f: timeout"); $finish;
end
initial begin
    repeat (40) @(negedge clk); reset = 1'b0; repeat (20) @(negedge clk);
    a = 4'd8;

    // 1. DMA-1: four channels, fixed priority, burst
    part("priority", "DMA-1, [C78] 12-99, 12-103, 12-105, Fig. 6");
    mode_set(8'h0F);
    for (i = 0; i < 4; i = i + 1) prog(i, 16'h0100 + 16'h1000 * i, 16'h4002);
    request_all(4'hF, 3, 1'b0);                                  // (a) held, bursts of 3
    wait_idle;
    run_order(12, 48'h000111222333, 1'b1);
    holds_is(1);
    part("priority", "DMA-1, [C78] 12-105, D9");                 // (b) channel 2 per strobe, the others low
    prog(2, 16'h2200, 16'h4002);
    request(2, 3, 1'b1);
    wait_idle;
    run_order(3, 12'h222, 1'b0);
    holds_is(3);
    part("priority", "DMA-1, [C78] 12-105, Fig. 6");             // (c) all four per strobe, bursts of 3
    for (i = 0; i < 4; i = i + 1) prog(i, 16'h0300 + 16'h1000 * i, 16'h4002);
    request_all(4'hF, 3, 1'b1);
    wait_idle;
    run_order(12, 48'h010101232323, 1'b1);
    holds_is(1);

    // 2. DMA-2: rotating priority
    part("rotating", "DMA-2, [C78] 12-103");
    mode_set(8'h1F);
    for (i = 0; i < 4; i = i + 1) prog(i, 16'h0500 + 16'h1000 * i, 16'h4002);
    request_all(4'hF, 3, 1'b0);
    wait_idle;
    run_order(12, 48'h012301230123, 1'b1);
    holds_is(1);

    // 3. DMA-3: channel enables
    part("enables", "DMA-3, [C78] 12-103");
    mode_set(8'h05);
    for (i = 0; i < 4; i = i + 1) prog(i, 16'h0700 + 16'h1000 * i, 16'h4001);
    request_all(4'hF, 2, 1'b0);
    wait_idle;
    run_order(4, 16'h0022, 1'b1);
    wait_ce(500);                                                // DRQ1 and DRQ3 still high
    ck(quiet >= 500 && ntr - ntr0 == 4, "a disabled channel's DRQ raised HRQ");
    request(1, 0, 1'b0); request(3, 0, 1'b0);

    // 4. DMA-4: read cycle, normal and extended write
    part("read cycle", "DMA-4, [C78] 12-105, 12-109");
    mode_set(8'h01);
    prog(0, 16'h4000, 16'h8001);
    request(0, 2, 1'b0);
    wait_idle;
    run_ch(2, 0, 1'b1);
    part("read cycle", "DMA-4, DMA-6, [C78] 12-103, 12-105");
    mode_set(8'h21);
    prog(0, 16'h4100, 16'h8001);
    request(0, 2, 1'b0);
    wait_idle;
    run_ch(2, 0, 1'b1);

    // 5. DMA-5: verify cycle, no strobes, no wait state with READY low
    part("verify", "DMA-5, [C78] 12-99, 12-105, Fig. 6");
    mode_set(8'h01);
    prog(0, 16'h5000, 16'h0001);
    @(negedge clk) ready = 1'b0;
    request(0, 2, 1'b0);
    wait_idle;
    @(negedge clk) ready = 1'b1;
    run_ch(2, 0, 1'b1);

    // 6. DMA-6: write cycle, normal and extended
    part("write cycle", "DMA-6, [C78] 12-105");
    mode_set(8'h01);
    prog(0, 16'h6000, 16'h4001);
    request(0, 2, 1'b0);
    wait_idle;
    run_ch(2, 0, 1'b1);
    part("write cycle", "DMA-6, [C78] 12-103, 12-105");
    mode_set(8'h21);
    prog(0, 16'h6100, 16'h4001);
    request(0, 2, 1'b0);
    wait_idle;
    run_ch(2, 0, 1'b1);

    // 7. DMA-7: READY, wait states SW
    part("ready", "DMA-7, [C78] 12-105, 12-109, 12-110");
    mode_set(8'h02);
    for (i = 2; i >= 1; i = i - 1) begin                         // READY low through rel 35 (2 SW), then 26 (1 SW)
        prog(1, 16'h7000 + 16'h0100 * i, 16'h4000);
        @(negedge clk) begin ready = 1'b0; rdy_t0 = n16; rdy_hi = i == 2 ? 36 : 27; end
        request(1, 1, 1'b0);
        wait_idle;
        count_is(1);
        if (ntr - ntr0 >= 1) begin
            xm(ntr0, 1, i, 1'b0);
            t = 0;
            while (t < 100 && h(s1_of[ntr0], t) & 32'h00020000) t = t + 1;
            if (t != 40 + 9 * i) begin
                $sformat(dmsg, "AEN high %0d ce16 with %0d SW, expected %0d", t, i, 40 + 9 * i); ck(1'b0, dmsg);
            end
        end
        ntr0 = ntr;
        @(negedge clk) ready = 1'b1;
    end

    // 8. DMA-8: TC output and the TC status bits
    part("tc output", "DMA-8, DMA-23, [C78] 12-102, 12-104");
    rd8(4'd8, v8);                                               // clears the TC bits of the earlier checks
    mode_set(8'h02);
    prog(1, 16'h8000, 16'h4002);
    request(1, 3, 1'b0);
    wait_idle;
    run_ch(3, 1, 1'b1);
    status_is(8'h02, "after TC of channel 1");
    status_is(8'h00, "the second read");
    mode_set(8'h84);                                             // the update flag is not cleared by a status read
    prog(2, 16'h8100, 16'h4002);
    part("tc output", "DMA-8, DMA-24, [C78] 12-104");
    request(2, 3, 1'b0);
    wait_idle;
    run_ch(3, 2, 1'b1);
    status_is(8'h14, "after TC of channel 2 with autoload");
    status_is(8'h10, "the second read");

    // 9. DMA-9: TC stop
    part("tc stop", "DMA-9, [C78] 12-102, 12-103");
    mode_set(8'h41);
    prog(0, 16'h9000, 16'h4003);
    request(0, 6, 1'b0);                                         // DRQ0 held for 6
    wait_idle;
    run_ch(4, 0, 1'b1);
    wait_ce(500);
    ck(quiet >= 500 && ntr - ntr0 == 4, "channel 0 served after TC with TC stop");
    mode_set(8'h01);                                             // enabled again, without TC stop
    part("tc stop", "DMA-9, DMA-27, [C78] 12-102, 12-103");
    wait_idle;
    run_ch(2, 0, 1'b1);
    reg_is(4'd1, 16'h7FFD, "count after the wrap");
    reg_is(4'd0, 16'h9006, "address after 6 transfers");
    part("tc stop", "DMA-9, [C78] 12-102, 12-103");              // no TC stop: the transfers go past TC
    prog(0, 16'h9100, 16'h4003);
    request(0, 5, 1'b0);
    wait_idle;
    run_ch(5, 0, 1'b1);
    reg_is(4'd1, 16'h7FFE, "count after TC without TC stop");

    // 10. DMA-10 / DMA-24: autoload, the update flag
    part("autoload", "DMA-10, [C78] 12-103, 12-104");
    mode_set(8'h80);
    prog(2, 16'hA000, 16'h4001);
    reg_is(4'd6, 16'hA000, "channel 3 address copied");
    reg_is(4'd7, 16'h4001, "channel 3 count copied");
    prog(3, 16'hB000, 16'h8002);
    reg_is(4'd6, 16'hB000, "channel 3 address own");
    reg_is(4'd7, 16'h8002, "channel 3 count own");
    reg_is(4'd4, 16'hA000, "channel 2 address");
    reg_is(4'd5, 16'h4001, "channel 2 count");
    rd8(4'd8, v8);                                               // clears the TC bit of check 9
    mode_set(8'hC4);                                             // autoload, TC stop, channel 2
    part("autoload", "DMA-10, DMA-24, [C78] 12-104, Fig. 5");
    request(2, 2, 1'b0);                                         // A000, A001 (TC)
    wait_idle;
    run_ch(2, 2, 1'b1);
    if (ntr - ntr0 == 2) begin
        upd_is(ntr0 + 1, 21, 1'b0); upd_is(ntr0 + 1, 22, 1'b1); upd_is(ntr0 + 1, 44, 1'b1);
    end
    status_is(8'h14, "after the TC cycle");
    status_is(8'h10, "the second read");
    part("autoload", "DMA-10, DMA-24, [C78] 12-103, 12-104");
    request(2, 4, 1'b0);                                         // B000 (reload from S0), B001, B002 (TC), B000 (back to back)
    wait_idle;
    run_ch(4, 2, 1'b1);
    if (ntr - ntr0 == 4) begin
        upd_is(ntr0, 0, 1'b1); upd_is(ntr0, 39, 1'b1); upd_is(ntr0, 40, 1'b0);
        upd_is(ntr0 + 2, 21, 1'b0); upd_is(ntr0 + 2, 22, 1'b1);
        upd_is(ntr0 + 3, 39, 1'b1); upd_is(ntr0 + 3, 40, 1'b0);
    end
    reg_is(4'd6, 16'hB000, "channel 3 after the reloads");
    reg_is(4'd7, 16'h8002, "channel 3 count after the reloads");
    status_is(8'h04, "after the reload cycle");
    part("autoload", "DMA-22, DMA-24, [C78] 12-104");
    request(2, 2, 1'b0);                                         // B001, B002 (TC): the flag set again
    wait_idle;
    run_ch(2, 2, 1'b1);
    status_is(8'h14, "after the TC cycle");
    mode_set(8'h04);
    status_is(8'h00, "after a mode write without autoload");

    // 11. DMA-11: MARK
    part("mark", "DMA-11, [C78] 12-102, 12-109, 12-110");
    mode_set(8'h01);
    for (j = 0; j < 2; j = j + 1) begin                          // count 00FFh: MARK 128, 256; 0080h: MARK 1, 129
        prog(0, 16'hC000 + 16'h1000 * j, j == 0 ? 16'h40FF : 16'h4080);
        request(0, j == 0 ? 256 : 129, 1'b0);
        wait_idle;
        run_ch(j == 0 ? 256 : 129, 0, 1'b1);
        for (i = 0; i < ntr - ntr0; i = i + 1) begin
            hv = h(s1_of[ntr0 + i], 26);
            if (hv[28] !== (j == 0 ? (i == 127 || i == 255) : (i == 0 || i == 128))) begin
                $sformat(dmsg, "MARK %b on transfer %0d of %0d", hv[28], i + 1, ntr - ntr0); ck(1'b0, dmsg);
            end
        end
        ntr0 = ntr;
    end

    // 12. DMA-12: register reads, the first / last flip-flop
    part("first/last", "DMA-12, DMA-22, [C78] 12-104, 12-105");
    mode_set(8'h00);
    wr57(4'd2, 8'h34); wr57(4'd2, 8'h12); wr57(4'd3, 8'h78); wr57(4'd3, 8'h56);
    reg_is(4'd2, 16'h1234, "address low then high");
    reg_is(4'd3, 16'h5678, "count low then high");
    // an odd number of accesses before each sync point: a read or write pair alone would hide a wrong F/L
    wr57(4'd2, 8'hAA); mode_set(8'h00);                           // 12AAh; F/L reset by a mode write
    rd8(4'd2, v8);
    if (v8 !== 8'hAA) begin $sformat(dmsg, "read after a mode write %h, expected the low byte AA", v8); ck(1'b0, dmsg); end
    rd8(4'd2, v8);
    wr57(4'd2, 8'h66); mode_set(8'h00); wr57(4'd2, 8'h55); mode_set(8'h00);
    reg_is(4'd2, 16'h1255, "write after a mode write");
    wr57(4'd3, 8'h11);                                           // reads and writes toggle the same F/L
    rd8(4'd3, v8);
    if (v8 !== 8'h56) begin $sformat(dmsg, "read after one write %h, expected the high byte 56", v8); ck(1'b0, dmsg); end
    wr57(4'd3, 8'h22); wr57(4'd3, 8'h33);
    reg_is(4'd3, 16'h3322, "write after a read");
    wr57(4'd4, 8'h88); wr57(4'd4, 8'h99); wr57(4'd4, 8'h77);     // 9977h, F/L 1; F/L reset by RESET
    @(negedge clk) reset = 1'b1; repeat (10) @(negedge clk); reset = 1'b0; repeat (20) @(negedge clk);
    mode_tb = 8'h00;
    rd8(4'd4, v8);
    if (v8 !== 8'h77) begin $sformat(dmsg, "read after RESET %h, expected the low byte 77", v8); ck(1'b0, dmsg); end
    rd8(4'd4, v8);
    if (v8 !== 8'h99) begin $sformat(dmsg, "second read after RESET %h, expected the high byte 99", v8); ck(1'b0, dmsg); end

    // 13. DMA-13: RESET
    part("reset", "DMA-13, [C78] 12-101");
    mode_set(8'h02);
    prog(1, 16'hD000, 16'h4009);
    request(1, 10, 1'b0);
    wait (ntr == ntr0 + 3); repeat (24) @(negedge clk);          // rel 10 + about 5 ce16: S2, IOR low
    ck(!ior_n_o && !dack_n[1] && aen && hrq, "the third transfer not in S2");
    @(negedge clk) reset = 1'b1; repeat (4) @(negedge clk);
    ck(!aen && !hrq && !adstb && dack_n === 4'hF && memr_n && memw_n && ior_n_o && iow_n_o && !tc && !mark,
       "pins active in RESET");
    reset = 1'b0; repeat (20) @(negedge clk);
    mode_tb = 8'h00;
    wait_ce(500);                                                // DRQ1 still high: every channel disabled
    ck(quiet >= 500 && ntr - ntr0 == 3 && drq[1], "a channel enabled after RESET");
    status_is(8'h00, "after RESET");
    reg_is(4'd2, 16'hD002, "address kept");
    reg_is(4'd3, 16'h4007, "count kept");
    request(1, 0, 1'b0);

    // 14. DMA-14: CS ignored in master mode
    part("cs", "DMA-14, [C78] 12-101");
    mode_set(8'h01);
    prog(0, 16'hE000, 16'h4003);
    request(0, 4, 1'b0);
    wait (ntr == ntr0 + 2); wr57(4'd8, 8'h00);                   // a mode write in S2 / S3: ignored
    wait (ntr == ntr0 + 3); wr57(4'd0, 8'h55);                   // an address write: ignored
    a = 4'd8;
    wait_idle;
    run_ch(4, 0, 1'b1);
    reg_is(4'd0, 16'hE004, "address after slave writes in master mode");

    // 15. DMA-15: HLDA lost during a block
    part("hlda lost", "DMA-15, [C78] 12-104 Fig. 6, 12-105, 12-110");
    mode_set(8'h04);
    prog(2, 16'hF000, 16'h4003);
    request(2, 4, 1'b0);
    wait (ntr == ntr0 + 2); @(negedge clk) hlda_off = 1'b1;      // in S2 of the second transfer
    s = s1_of[ntr0 + 1];
    wait (n16 > s + 1 + 100);
    ck(ntr == ntr0 + 2, "S1 while HLDA is low");
    @(negedge clk) hlda_off = 1'b0;
    wait_idle;
    count_is(4);
    if (ntr - ntr0 == 4) begin
        xm(ntr0, 2, 0, 1'b1); xm(ntr0 + 1, 2, 0, 1'b0); xm(ntr0 + 2, 2, 0, 1'b1); xm(ntr0 + 3, 2, 0, 1'b0);
        t = s1_of[ntr0 + 2] - s;                                 // the next S1, rel of the second transfer
        bad = 16'h0000;
        for (r = 41; r <= t; r = r + 1) begin                    // xm checked rel 31-40
            hv = h(s, r);
            sig(10, hv[16] === (r >= 49), "hrq", r, ntr0 + 1);
            if (r >= 40) sig(0, hv[17] === (r == t), "aen", r, ntr0 + 1);
        end
        if (s1_of[ntr0 + 2] - hlda_up != 7) begin
            $sformat(dmsg, "S1 %0d after HLDA, expected 7", s1_of[ntr0 + 2] - hlda_up); ck(1'b0, dmsg);
        end
        if (s1_of[ntr0 + 3] - s1_of[ntr0 + 2] != 36) ck(1'b0, "the last two transfers not back to back");
    end

    // 16. DMA-16: S0 wait states
    part("s0 wait", "DMA-16, [C78] 12-105, Fig. 6");
    mode_set(8'h09);
    prog(0, 16'h0A00, 16'h4000);
    prog(3, 16'h3A00, 16'h4000);
    @(negedge clk) begin hlda_off = 1'b1; t = n16; end
    request(3, 1, 1'b0);
    wait (hrq_up > t);
    s = hrq_up;
    wait (n16 > s + 20); request(0, 1, 1'b0);                    // a higher priority DRQ in S0
    wait (n16 > s + 54); @(negedge clk) hlda_off = 1'b0;         // HLDA 5 Φ late: at f1 s + 61 instead of s + 16
    wait_idle;
    run_order(2, 8'h03, 1'b1);
    if (ntr - ntr0 >= 1) begin
        if (s1_of[ntr0] - s != 68) begin
            $sformat(dmsg, "S1 %0d after HRQ, expected 68 (5 extra S0)", s1_of[ntr0] - s); ck(1'b0, dmsg);
        end
        if (s1_of[ntr0] - hlda_up != 7) begin
            $sformat(dmsg, "S1 %0d after HLDA, expected 7", s1_of[ntr0] - hlda_up); ck(1'b0, dmsg);
        end
    end

    if (errors == 0) $display("PASS: vt57f (%0d transfers)", ntr);
    $finish;
end
endmodule
`default_nettype wire
