// rk86_video16 against the board's video path (Task 2 VID-n): the font address, the ИР13 load and shift,
// VSP to the ROM select, LTEN through the ТМ2, RVV at the output.
`default_nettype none
`timescale 1ns/1ns
module tb_video16;
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
reg [3:0] cnt = 4'd0;
always @(posedge clk) if (ce16) cnt <= cnt == 4'd11 ? 4'd0 : cnt + 4'd1;
wire dot_ce = ce16 && !cnt[0];
wire cclk_fall = ce16 && cnt == 4'd11;
reg [6:0] cc = 7'd0;
reg [3:0] lc = 4'd0;
reg vsp = 1'b0, lten = 1'b0, rvv = 1'b0;
wire [9:0] font_addr;
reg [7:0] font_data = 8'h00;
wire pix;
always @(posedge clk) font_data <= font_addr[7:0] ^ 8'h2D;          // a font ROM with latency 1 clk
rk86_video16 dut(.clk(clk), .dot_ce(dot_ce), .cnt12(cnt), .cc(cc), .lc(lc), .vsp(vsp), .lten(lten), .rvv(rvv),
    .font_addr(font_addr), .font_data(font_data), .pix(pix));
integer errors = 0, chars = 0, j = 6;
integer loads = 0, dots = 0, lit_dots = 0, dark_dots = 0, vsp_chars = 0, vsp_visible = 0, lten_chars = 0, lten_moved = 0;
integer rvv_dots = 0, rvv_moved = 0;
reg [5:0] exp = 6'd0, expf = 6'd0;                                   // the dots as loaded; the dots without VSP
reg exp_l = 1'b0, exp_v = 1'b0, rvv_prev = 1'b0;
reg [31:0] rnd = 32'h1234_5678;
always @(posedge clk) begin
    if (cclk_fall) begin                                             // the 8275 outputs change at CCLK↓
        rnd = rnd * 32'd1103515245 + 32'd12345;
        cc <= rnd[22:16]; lc <= rnd[27:24];
        vsp <= rnd[29] & rnd[28]; lten <= rnd[30] & rnd[31] & rnd[8]; rvv <= rnd[9] & rnd[10];
        chars = chars + 1;
    end
    if (dot_ce) begin
        if (j < 6) begin
            dots = dots + 1;
            if (pix) lit_dots = lit_dots + 1; else dark_dots = dark_dots + 1;
            if (rvv) rvv_dots = rvv_dots + 1;
            if (rvv !== rvv_prev) rvv_moved = rvv_moved + 1;         // RVV changed between two dots (not re-timed)
            rvv_prev = rvv;
            if (pix !== ((exp_l | exp[5 - j]) ^ rvv)) begin
                // name the first difference: the live LTEN instead of the latched one, VSP not applied, or the dot
                if (exp_l !== lten && pix === ((lten | exp[5 - j]) ^ rvv))
                    $display("ERROR: video16: lten at dot %0d of character %0d", j, chars);
                else if (exp_v && pix === ((exp_l | expf[5 - j]) ^ rvv))
                    $display("ERROR: video16: vsp at dot %0d of character %0d", j, chars);
                else $display("ERROR: video16: dot %0d of character %0d", j, chars);
                errors = errors + 1;
            end
            j = j + 1;
        end
        if (cnt == 4'd10) begin                                       // VID-2: the load, at QA↑ before CCLK↓
            if (font_addr !== {cc, lc[2:0]}) begin $display("ERROR: video16: font address"); errors = errors + 1; end
            expf = {cc[2:0], lc[2:0]} ^ 6'h2D;
            exp = vsp ? 6'd0 : expf;                                  // VID-3: VSP selects the ROM off
            exp_v = vsp; exp_l = lten;                                // VID-4: LTEN through the ТМ2
            loads = loads + 1;
            if (vsp) begin vsp_chars = vsp_chars + 1; if (expf != 6'd0) vsp_visible = vsp_visible + 1; end
            if (lten) lten_chars = lten_chars + 1;
            j = 0;
        end
    end
    // LTEN moves right after each load (at CCLK↓): count the characters whose LTEN differs from the next one's
    if (cclk_fall && lten !== (rnd[30] & rnd[31] & rnd[8])) lten_moved = lten_moved + 1;
end
initial begin
    wait (chars == 3000);
    if (loads < 2900 || dots < 6 * (loads - 1) || lit_dots == 0 || dark_dots == 0
        || vsp_visible == 0 || lten_chars == 0 || lten_moved == 0 || rvv_dots == 0 || rvv_moved == 0) begin
        $display("ERROR: video16: too few samples: loads %0d dots %0d lit %0d dark %0d vsp %0d/%0d lten %0d/%0d rvv %0d/%0d",
                 loads, dots, lit_dots, dark_dots, vsp_visible, vsp_chars, lten_chars, lten_moved, rvv_dots, rvv_moved);
        errors = errors + 1;
    end
    if (errors == 0) $display("PASS: video16 (%0d characters)", chars);
    $finish;
end
endmodule
