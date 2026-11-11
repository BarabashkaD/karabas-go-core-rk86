// The clock enables of the Radio-86RK 16 MHz machine (rk86_16/README.md): the 8224 (КР580ГФ24) and
// the 7492 (К155ИЕ4) on the 16 MHz crystal. ce16 is one oscillator period; every enable is high for
// one clk, on a clk with ce16 high. The dividers have no reset (they run freely on the board).
// 8224 ([C78] 11-24..11-27, [D8224] 1-50..1-54; Task 2 CLK-n):
//   f1       Φ1 rises: step 0 of 9; Φ1 high p0-p1                      1.778 MHz
//   f2       Φ2 rises: step F2_STEP (2); Φ2 high p2-p6; the 8257 θ↑
//   f2_fall  Φ2 falls: step F2_FALL_STEP (7); the 8257 θ↓
//   reset, ready: the RESIN / RDYIN flip-flops, clocked at p3 by the internal "Φ2 D", one period after
//            Φ2↑ (tDRS / tDRH from STSTB↓, tDR to Φ2↓; [R86] p. 31 "on the leading edge of Φ2")
//   ststb_n  NOR (SYNC at p8, RESET): low for the period p8 when SYNC is high (tDSS = 6tcy/9 after Φ2↑,
//            tPW = tcy/9) and, without a clock lag, while RESET is high (Fig. 1)
// 7492 in divide-by-12 (QA to input B), Task 2 IE4-n:
//   dot_ce   QA rises: every 2 periods, the 8 MHz dot clock of the ИР13
//   cclk_fall, cclk_rise: QD (the 8275 CCLK, 1.333 MHz) falls / rises
//   cnt12    the count 0..11 before this ce16; ie4 = QD QC QB QA of that count
// New for the 16 MHz machine (karabas-go-core-rk86, rk86_16/); modified BSD license, see ../../LICENSE.TXT.
`default_nettype none
module rk86_clocks16 #(parameter F2_STEP = 2, parameter F2_FALL_STEP = 7) (
    input  wire       clk,
    input  wire       ce16,
    input  wire       resin_n,
    input  wire       rdyin,
    input  wire       sync,
    output wire       f1,
    output wire       f2,
    output wire       f2_fall,
    output reg        phi1 = 1'b0,
    output reg        phi2 = 1'b0,
    output reg        reset = 1'b1,
    output reg        ready = 1'b1,
    output wire       ststb_n,
    output wire [3:0] ie4,
    output wire [3:0] cnt12,
    output wire       dot_ce,
    output wire       cclk_fall,
    output wire       cclk_rise
);
reg [3:0] step = 4'd0;      // SILENT: the power-up phase of the 8224 against the ИЕ4 (both 0 here)
reg [3:0] cnt = 4'd0;
reg       ststb_sync = 1'b0;    // SYNC sampled at p8: the strobe term of the NOR, low for one period
always @(posedge clk)
    if (ce16) begin
        step <= step == 4'd8 ? 4'd0 : step + 4'd1;
        cnt <= cnt == 4'd11 ? 4'd0 : cnt + 4'd1;
        phi1 <= step == 4'd0 || step == 4'd1;
        phi2 <= step >= F2_STEP && step <= F2_STEP + 4;
        ststb_sync <= sync && step == 4'd8;
        if (step == F2_STEP + 1) begin          // p3: "Φ2 D" (SILENT: one period after Φ2↑)
            reset <= !resin_n;
            ready <= rdyin;
        end
    end
assign ststb_n = !(ststb_sync || reset);    // the NOR: RESET reaches STSTB without a clock lag
assign f1 = ce16 && step == 4'd0;
assign f2 = ce16 && step == F2_STEP;
assign f2_fall = ce16 && step == F2_FALL_STEP;
// 7492: QA = count bit 0; QB QC divide by 3, QD by 2 (counts 0..5 = 0000..0101, 6..11 = 1000..1101)
wire [2:0] half = cnt[3:1];
assign ie4 = {half >= 3'd3, half == 3'd2 || half == 3'd5, half == 3'd1 || half == 3'd4, cnt[0]};
assign cnt12 = cnt;
assign dot_ce = ce16 && !cnt[0];
assign cclk_fall = ce16 && cnt == 4'd11;
assign cclk_rise = ce16 && cnt == 4'd5;
endmodule
`default_nettype wire
