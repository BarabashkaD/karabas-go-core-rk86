// rk86_clocks16 against the 8224 data sheet ([C78] 11-24..11-27, [D8224]) and the 7492 / К155ИЕ4 count
// sequence (Task 2, CLK-n, IE4-n). Each check names its data sheet item.
`default_nettype none
`timescale 1ns/1ns
module tb_clocks16;
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
reg resin_n = 1'b0, rdyin = 1'b1, sync = 1'b0;
wire f1, f2, f2_fall, phi1, phi2, reset, ready, ststb_n, dot_ce, cclk_fall, cclk_rise;
wire [3:0] ie4, cnt12;
rk86_clocks16 dut(.clk(clk), .ce16(ce16), .resin_n(resin_n), .rdyin(rdyin), .sync(sync),
    .f1(f1), .f2(f2), .f2_fall(f2_fall), .phi1(phi1), .phi2(phi2), .reset(reset), .ready(ready),
    .ststb_n(ststb_n), .ie4(ie4), .cnt12(cnt12), .dot_ce(dot_ce), .cclk_fall(cclk_fall), .cclk_rise(cclk_rise));
// the 7492 divide-by-12 sequence QD QC QB QA (QA to input B)
function [3:0] ie4_of(input [3:0] c);
    case (c)
        4'd0: ie4_of = 4'b0000;  4'd1: ie4_of = 4'b0001;  4'd2: ie4_of = 4'b0010;  4'd3: ie4_of = 4'b0011;
        4'd4: ie4_of = 4'b0100;  4'd5: ie4_of = 4'b0101;  4'd6: ie4_of = 4'b1000;  4'd7: ie4_of = 4'b1001;
        4'd8: ie4_of = 4'b1010;  4'd9: ie4_of = 4'b1011;  4'd10: ie4_of = 4'b1100; default: ie4_of = 4'b1101;
    endcase
endfunction
integer n16 = 0, errors = 0, k, p, last_f1 = -1, last_dot = -1, last_cf = -1, f1_in_reset = 0;
integer prev_p = -1;
reg prev_p3 = 1'b0, prev_sync = 1'b0, resin_s = 1'b0, rdyin_s = 1'b1, reset_q = 1'b1, ready_q = 1'b1;
reg [3:0] cnt_q = 4'd0;
task err(input [8*40-1:0] what, input integer v); begin
    $display("ERROR: clocks16: %0s %0d at ce16 %0d", what, v, n16); errors = errors + 1; end endtask
// RESIN and RDYIN change at clk edges unrelated to the phases
always begin
    repeat (1013) @(negedge clk); resin_n = ~resin_n | (n16 > 64 * 400);
    repeat (777) @(negedge clk); rdyin = ~rdyin;
    repeat (301) @(negedge clk); sync = ~sync;
end
initial begin
    for (k = 0; k < 297 * 900; k = k + 1) begin
        @(posedge clk);
        if ((f1 || f2 || f2_fall || dot_ce || cclk_fall || cclk_rise) && !ce16) err("an enable without ce16", 0);
        if (ce16) begin
            // CLK-1: Φ1 every 9 oscillator periods ([C78] 11-26 tCY = 9 tOSC)
            p = f1 ? 0 : (last_f1 >= 0 ? n16 - last_f1 : -1);
            if (f1) begin if (last_f1 >= 0 && n16 - last_f1 != 9) err("f1 period", n16 - last_f1); last_f1 = n16; end
            // CLK-2, CLK-3: Φ2 rises 2 periods after Φ1, falls 5 periods later ([C78] 11-26 tD3, tΦ2)
            if (f2 && p >= 0 && p != 2) err("f2 at step", p);
            if (f2_fall && p >= 0 && p != 7) err("f2_fall at step", p);
            // CLK-4: Φ1 high p0-p1, Φ2 high p2-p6 ([C78] 11-26, 11-27); this sample shows the last period
            if (prev_p >= 0 && phi1 !== (prev_p <= 1)) err("phi1 at period", prev_p);
            if (prev_p >= 0 && phi2 !== (prev_p >= 2 && prev_p <= 6)) err("phi2 at period", prev_p);
            // CLK-5, CLK-6: RESET and READY change only at p3 (the 8224's internal "Φ2 D", one period after
            // Φ2↑) and take RESIN / RDYIN of that edge ([D8224] 1-52, 1-54 tDRS, tDRH, tDR; [R86] p. 31)
            if (reset !== reset_q && !prev_p3) err("reset changed off p3", 0);
            if (prev_p3 && reset !== !resin_s) err("reset", reset);
            if (ready !== ready_q && !prev_p3) err("ready changed off p3", 0);
            if (prev_p3 && ready !== rdyin_s) err("ready", ready);
            // CLK-7, CLK-8: STSTB = NOR (SYNC at p8, RESET): low for the period p8 when SYNC is high, and
            // while RESET is high ([D8224] 1-50 Fig. 1, 1-52 tDSS, tPW; [C78] 11-26)
            if (prev_p >= 0 && ststb_n !== !((prev_p == 8 && prev_sync) || reset_q)) err("ststb at period", prev_p);
            // IE4-1: the 7492 sequence; QA↑ every 2, QD↓ every 12, QD↑ 6 after QD↓
            if (ie4 !== ie4_of(cnt12)) err("ie4 sequence at count", cnt12);
            if (n16 > 0 && cnt12 !== (cnt_q == 4'd11 ? 4'd0 : cnt_q + 4'd1)) err("ie4 count", cnt12);
            if (dot_ce) begin if (last_dot >= 0 && n16 - last_dot != 2) err("dot_ce period", n16 - last_dot); last_dot = n16; end
            if (cclk_fall) begin if (last_cf >= 0 && n16 - last_cf != 12) err("cclk period", n16 - last_cf); last_cf = n16; end
            if (cclk_rise && last_cf >= 0 && n16 - last_cf != 6) err("cclk_rise after fall", n16 - last_cf);
            // §4.2: the dividers run in reset
            if (f1 && !resin_n) f1_in_reset = f1_in_reset + 1;
            if (p == 3) begin resin_s = resin_n; rdyin_s = rdyin; end
            prev_p3 = p == 3; prev_sync = sync; prev_p = p; reset_q = reset; ready_q = ready; cnt_q = cnt12;
            n16 = n16 + 1;
        end
    end
    if (n16 != 64 * 900) err("ce16 count", n16);
    if (f1_in_reset == 0) err("enables stopped in reset", 0);
    if (errors == 0) $display("PASS: clocks16 (%0d ce16)", n16);
    $finish;
end
endmodule
`default_nettype wire
