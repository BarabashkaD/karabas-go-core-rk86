// k580vt57: the states on both clock edges and the RK86 DMA write cycle against the 8257 data sheet
// ([C78] 12-104 Fig. 6, 12-105, 12-109, 12-110) and docs/radio86rk-ics.md b. A sample at a ce16 shows
// what the edges up to the previous ce16 made, so rel = sample - S1 - 1 is the edge number of the table.
`default_nettype none
`timescale 1ns/1ns
module tb_vt57;
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
reg reset = 1'b1, cs_n = 1'b1, ior_n = 1'b1, iow_n = 1'b1;
reg [3:0] a = 4'd0;
reg [7:0] d = 8'h00;
reg drq2 = 1'b0, hold_s = 1'b0, hlda = 1'b0;
wire [7:0] d_o;
wire [3:0] dack_n;
wire [15:0] a_o;
wire hrq, aen, adstb, memr_n, memw_n, ior_n_o, iow_n_o, tc, mark;
k580vt57 dut(.clk(clk), .th_up(f2), .th_dn(f2_fall), .reset(reset), .cs_n(cs_n), .ior_n_i(ior_n), .iow_n_i(iow_n),
    .a_i(a), .d_i(d), .d_o(d_o), .drq({1'b0, drq2, 2'b00}), .hlda(hlda), .ready(1'b1), .hrq(hrq), .dack_n(dack_n),
    .a_o(a_o), .aen(aen), .adstb(adstb), .memr_n(memr_n), .memw_n(memw_n), .ior_n_o(ior_n_o), .iow_n_o(iow_n_o),
    .tc(tc), .mark(mark));
// the 8080 ([C78] 11-12, 11-15; [UM83] 4-13): HOLD sampled at Φ2↑, HLDA follows at the next Φ1↑
always @(posedge clk) begin
    if (f2) hold_s <= hrq;
    if (f1) hlda <= hold_s;
end
// the 8275 (D9; [D79] Fig. 30): DRQ falls at WR↓ with DACK, rises after WR↑ while the burst has characters left;
// with hold_drq a burst-mode requester ([C78] 12-100, 12-105): DRQ held high until the DACK of the last cycle
integer bleft = 0;
reg ior_q = 1'b1, dack_q = 1'b1, hold_drq = 1'b0;
always @(posedge clk) begin
    ior_q <= ior_n_o; dack_q <= dack_n[2];
    if (!ior_n_o && ior_q && !dack_n[2] && !hold_drq) drq2 <= 1'b0;
    if (hold_drq && !dack_n[2] && dack_q && bleft == 1) drq2 <= 1'b0;
    if (ior_n_o && !ior_q && !dack_q) begin bleft = bleft - 1; if (bleft > 0 && !hold_drq) drq2 <= 1'b1; end
end
integer n16 = 0, s1 = -1000, rel = -1000, transfers = 0, holds = 0, aen_n = 0, errors = 0, samp = -1000, last_s1 = -1000;
integer conts = 0;
reg ext = 1'b1, first = 1'b1, adstb_q = 1'b0, hrq_q = 1'b0, aen_q = 1'b0, open = 1'b0;
reg cont_exp = 1'b0;               // the S4 decision of the data sheet: DRQ and HLDA at the θ↓ that starts S4 (rel 27)
reg [4:0] aen_h = 5'd0;            // AEN of the last five samples, [0] the newest
reg [15:0] exp_a = 16'h76D0;
reg [7:0] v;
task err(input [8*32-1:0] what, input integer x); begin
    $display("ERROR: vt57: %0s %0d (transfer %0d)", what, x, transfers); errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: vt57: too many errors"); $finish; end
end endtask
task finish_transfer; begin
    open = 1'b0;
    transfers = transfers + 1;
    exp_a = transfers == 2340 ? 16'h76D0 : exp_a + 16'd1;   // autoload from channel 3
end endtask
always @(posedge clk) if (ce16) begin
    if (f2_fall && drq2 && !hrq && !aen) samp = n16;           // the DRQ sample in SI
    if (adstb && !adstb_q) begin                               // ADSTB rose at θ↑(S1) = edge 4
        if (open) finish_transfer;                             // the previous transfer ended with S4 → S1
        s1 = n16 - 5;
        // AEN at rel 0-3 (the last four samples) and rel -1: rises at θ↓(S1), stays high from a previous S4
        if (aen_h[3:0] !== 4'hF || aen_h[4] !== cont_exp) err("aen rise", aen_h);
        if (cont_exp) begin
            if (s1 - last_s1 != 36) err("burst period", s1 - last_s1);
            conts = conts + 1;
        end else begin
            if (s1 - samp != 27) err("latency", s1 - samp);
            if (!first && s1 - last_s1 != 72) err("period", s1 - last_s1);
        end
        first = 1'b0; last_s1 = s1; open = 1'b1;
    end
    rel = n16 - s1 - 1;
    if (rel == 26) cont_exp = drq2 && hlda;                   // this sample holds the inputs of the θ↓ at edge 27
    if (rel >= 0 && rel <= 39) begin
        if (aen !== 1'b1) err("aen at", rel);
        if (adstb !== (rel >= 4 && rel <= 12)) err("adstb at", rel);
        if (!dack_n[2] !== (rel >= 9 && rel <= 35)) err("dack at", rel);
        if (!ior_n_o !== (rel >= 13 && rel <= 35)) err("ior at", rel);
        if (!memw_n !== (rel >= (ext ? 13 : 22) && rel <= 30)) err("memw at", rel);
        if (!memr_n || !iow_n_o) err("strobe at", rel);
        if (hrq !== (rel <= 30 || cont_exp)) err("hrq at", rel);
        if (tc !== (transfers == 2339 && rel >= 22 && rel <= 30)) err("tc at", rel);
        if (a_o !== exp_a) err("address at", rel);
    end
    if (rel >= 40 && rel <= 44) begin                          // reached only without a following S1
        if (cont_exp) begin
            if (rel == 40) err("no S1 after S4 at", rel);
        end else begin
            if (aen !== 1'b0) err("aen at", rel);
            if (adstb !== 1'b0) err("adstb at", rel);
            if (dack_n[2] !== 1'b1) err("dack at", rel);
            if (ior_n_o !== 1'b1) err("ior at", rel);
            if (memw_n !== 1'b1) err("memw at", rel);
            if (!memr_n || !iow_n_o) err("strobe at", rel);
            if (hrq !== 1'b0) err("hrq at", rel);
            if (tc !== 1'b0) err("tc at", rel);
            if (transfers != 2339 && a_o !== exp_a + 16'd1) err("address update at", rel);
        end
        if (rel == 44 && open) finish_transfer;
    end
    if (aen_q && !aen && rel != 40) err("aen fall at", rel); // AEN falls only at θ↑ in the SI after the last S4
    if (hrq && !hrq_q) holds = holds + 1;
    if (aen) aen_n = aen_n + 1;
    adstb_q = adstb; hrq_q = hrq; aen_q = aen; aen_h = {aen_h[3:0], aen};
    n16 = n16 + 1;
end
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
task run_to(input integer target); begin
    while (transfers < target) begin
        @(negedge clk) begin first = 1'b1; bleft = target - transfers > 8 ? 8 : target - transfers; drq2 = 1'b1; end
        wait (bleft <= 0);
        wait (!hrq && !aen);
        repeat (300) @(negedge clk);
    end
end endtask
initial begin
    #(20000000) $display("FATAL: vt57: timeout"); $finish;
end
initial begin
    repeat (40) @(negedge clk); reset = 1'b0; repeat (20) @(negedge clk);
    // the monitor (BIOS 0x2E7-0x2FA): mode 80h, channel 2 address 76D0h, count 4923h, mode A4h
    wr57(4'd8, 8'h80); wr57(4'd4, 8'hD0); wr57(4'd4, 8'h76); wr57(4'd5, 8'h23); wr57(4'd5, 8'h49); wr57(4'd8, 8'hA4);
    run_to(2340);
    rd57(4'd8, v); if (v[2] !== 1'b1 || v[4] !== 1'b1) err("status after TC", v);
    rd57(4'd8, v); if (v[2] !== 1'b0 || v[4] !== 1'b1) err("status read twice", v);
    run_to(2341);
    rd57(4'd8, v); if (v[4] !== 1'b0) err("update flag after the reload", v);
    wr57(4'd8, 8'h84); ext = 1'b0;
    run_to(2357);
    if (holds != transfers) err("hold periods", holds);
    // burst mode ([C78] 12-100, Fig. 6 S4 → S1 on HRQ · HLDA): three requests of 8 cycles, each one HOLD period
    hold_drq = 1'b1;
    run_to(2381);
    if (conts != 21) err("back-to-back transfers", conts);
    if (holds != transfers - conts) err("hold periods with bursts", holds);
    // AEN: rel 0-35 of every transfer and rel 36-39 once per HOLD period (AEN↓ at θ↑ of the SI after the last S4)
    if (aen_n != 36 * transfers + 4 * (transfers - conts)) err("aen total", aen_n);
    if (errors == 0) $display("PASS: vt57 (%0d transfers, %0d back-to-back, %0d HOLD periods, %0d ce16 with AEN)",
        transfers, conts, holds, aen_n);
    $finish;
end
endmodule
