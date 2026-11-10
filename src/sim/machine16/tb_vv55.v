// k580vv55 against the 8255A data sheet ([C78] 12-76..12-90, Task 2 PPI-n).
`default_nettype none
`timescale 1ns/1ns
module tb_vv55;
reg clk = 1'b0; always #1 clk = ~clk;
reg reset = 1'b1, cs_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1;
reg [1:0] a = 2'd0; reg [7:0] d = 8'h00;
reg [7:0] pa_i = 8'h00, pb_i = 8'h00, pc_i = 8'hFF;
wire [7:0] d_o, pa_o, pb_o, pc_o, pc_oe; wire pa_oe, pb_oe;
k580vv55 dut(.clk(clk), .reset(reset), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .a(a), .d_i(d), .d_o(d_o),
    .pa_i(pa_i), .pa_o(pa_o), .pa_oe(pa_oe), .pb_i(pb_i), .pb_o(pb_o), .pb_oe(pb_oe),
    .pc_i(pc_i), .pc_o(pc_o), .pc_oe(pc_oe));
integer errors = 0, k;
reg [7:0] v, cw, mid_pc;
task chk(input ok, input [8*48-1:0] what); begin
    if (!ok) begin $display("ERROR: vv55: %0s at %0t", what, $time); errors = errors + 1; end end endtask
task wr(input [1:0] ad, input [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; d = dd; end
    @(negedge clk) wr_n = 1'b0;
    repeat (2) @(negedge clk); mid_pc = pc_o;
    repeat (2) @(negedge clk); wr_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
task rd(input [1:0] ad, output [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; end
    @(negedge clk) rd_n = 1'b0;
    repeat (2) @(negedge clk); mid_pc = pc_o;
    repeat (2) @(negedge clk); dd = d_o; rd_n = 1'b1;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
initial begin
    repeat (4) @(negedge clk); reset = 1'b0; repeat (2) @(negedge clk);
    // PPI-1 reset: every port an input ([C78] 12-78 RESET)
    chk(!pa_oe && !pb_oe && pc_oe == 8'h00, "reset: ports not inputs");
    // PPI-2 mode 0, the 16 configurations of D4 D3 D1 D0 ([C78] 12-81); outputs latched, inputs not ([C78] 12-80)
    for (k = 0; k < 16; k = k + 1) begin
        cw = 8'h80 | (k[3] << 4) | (k[2] << 3) | (k[1] << 1) | k[0];
        wr(2'd3, cw);
        chk(pa_oe == !k[3] && pb_oe == !k[1] && pc_oe == {{4{!k[2]}}, {4{!k[0]}}}, "mode 0 directions");
        pa_i = 8'h3C ^ k; pb_i = 8'hC3 ^ k; pc_i = 8'h5A ^ k;
        wr(2'd0, 8'hA1); wr(2'd1, 8'hB2); wr(2'd2, 8'hC4);
        rd(2'd0, v); chk(v == (k[3] ? pa_i : 8'hA1), "mode 0 port A read");
        rd(2'd1, v); chk(v == (k[1] ? pb_i : 8'hB2), "mode 0 port B read");
        rd(2'd2, v); chk(v == {k[2] ? pc_i[7:4] : 4'hC, k[0] ? pc_i[3:0] : 4'h4}, "mode 0 port C read");
        pa_i = ~pa_i; rd(2'd0, v); chk(!k[3] || v == pa_i, "mode 0 input latched");
    end
    // PPI-3 a mode-set write clears the output latches ([C78] 12-79), also when it repeats the mode (D14)
    wr(2'd3, 8'h80); wr(2'd0, 8'hFF); wr(2'd1, 8'hFF); wr(2'd2, 8'hFF); wr(2'd3, 8'h80);
    chk(pa_o == 8'h00 && pb_o == 8'h00 && pc_o == 8'h00, "mode set: latches not cleared");
    // PPI-4 bit set / reset of each port C bit ([C78] 12-80 Fig. 5)
    for (k = 0; k < 8; k = k + 1) begin
        wr(2'd3, {4'b0000, k[2:0], 1'b1}); chk(pc_o == (8'd1 << k), "bsr set");
        wr(2'd3, {4'b0000, k[2:0], 1'b0}); chk(pc_o == 8'h00, "bsr reset");
    end
    // PPI-5 mode 1, port A input: STB PC4, IBF PC5, INTR PC3, INTE A by PC4 ([C78] 12-84)
    pc_i = 8'hFF; wr(2'd3, 8'hB0);
    chk(pc_oe[5] && pc_oe[3] && !pc_oe[4], "mode 1 input: pins");
    pa_i = 8'h3C; @(negedge clk) pc_i[4] = 1'b0; repeat (3) @(negedge clk);
    chk(pc_o[5] == 1'b1, "mode 1 input: ibf not set by stb");
    pc_i[4] = 1'b1; pa_i = 8'h00; repeat (2) @(negedge clk);
    chk(pc_o[3] == 1'b0, "mode 1 input: intr without inte");
    wr(2'd3, 8'h09); chk(pc_o[3] == 1'b1, "mode 1 input: intr");
    rd(2'd2, v); chk(v[5:3] == 3'b111, "mode 1 input: status word");
    rd(2'd0, v); chk(v == 8'h3C, "mode 1 input: latch");
    chk(mid_pc[5] == 1'b1 && mid_pc[3] == 1'b0, "mode 1 input: ibf / intr during rd");
    chk(pc_o[5] == 1'b0 && pc_o[3] == 1'b0, "mode 1 input: ibf after rd");
    // PPI-29 a port C byte write changes only the bits that are outputs (ruling): with B0h PC7, PC6
    // (control bit 3 = 0) and PC2-PC0 (bit 0 = 0) are outputs; IBF (PC5), PC4 and INTR (PC3) and INTE A stay
    v = pc_o; wr(2'd2, 8'hFF);
    chk(pc_o[7:6] == 2'b11 && pc_o[2:0] == 3'b111 && pc_o[5:3] == v[5:3], "port C byte write");
    rd(2'd2, v); chk(v[4] == 1'b1, "port C byte write: inte");
    // PPI-6 mode 1, port A output: OBF PC7, ACK PC6, INTR PC3, INTE A by PC6 ([C78] 12-85 Fig. 9; D14)
    pc_i = 8'hFF; wr(2'd3, 8'hA0);
    chk(pa_oe && pc_oe[7] && pc_oe[3] && !pc_oe[6], "mode 1 output: pins");
    wr(2'd3, 8'h0D);
    chk(pc_o[3] == 1'b1, "mode 1 output: intr with empty buffer");
    wr(2'd0, 8'h5A);
    chk(mid_pc[3] == 1'b0, "mode 1 output: intr during wr");
    chk(pa_o == 8'h5A && pc_o[7] == 1'b0 && pc_o[3] == 1'b0, "mode 1 output: obf after wr");
    @(negedge clk) pc_i[6] = 1'b0; repeat (3) @(negedge clk);
    chk(pc_o[7] == 1'b1 && pc_o[3] == 1'b0, "mode 1 output: obf after ack");
    pc_i[6] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[3] == 1'b1, "mode 1 output: intr after ack");
    rd(2'd2, v); chk(v[7:6] == 2'b11 && v[3] == 1'b1, "mode 1 output: status word");
    // PPI-7 mode 1, port B input (STB PC2, IBF PC1, INTR PC0) and output (OBF PC1, ACK PC2), INTE B by PC2
    pc_i = 8'hFF; wr(2'd3, 8'h86); wr(2'd3, 8'h05);
    pb_i = 8'h66; @(negedge clk) pc_i[2] = 1'b0; repeat (3) @(negedge clk); pc_i[2] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 input: port B ibf / intr");
    rd(2'd1, v); chk(v == 8'h66 && pc_o[1] == 1'b0, "mode 1 input: port B");
    wr(2'd3, 8'h84); wr(2'd3, 8'h05); wr(2'd1, 8'h99);
    chk(pb_oe && pb_o == 8'h99 && pc_o[1] == 1'b0, "mode 1 output: port B obf");
    @(negedge clk) pc_i[2] = 1'b0; repeat (3) @(negedge clk); pc_i[2] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 output: port B ack");
    // PPI-8 mode 2: port A bidirectional, its buffer enabled by ACK; IBF PC5, STB PC4, OBF PC7, ACK PC6,
    // INTR PC3; INTE 1 by PC6, INTE 2 by PC4 ([C78] 12-86, 12-87)
    pc_i = 8'hFF; wr(2'd3, 8'hC0);
    chk(!pa_oe, "mode 2: port A buffer enabled without ack");
    wr(2'd0, 8'h77); chk(pc_o[7] == 1'b0 && !pa_oe, "mode 2: obf");
    @(negedge clk) pc_i[6] = 1'b0; repeat (2) @(negedge clk);
    chk(pa_oe && pa_o == 8'h77, "mode 2: port A buffer with ack");
    pc_i[6] = 1'b1; repeat (2) @(negedge clk); chk(!pa_oe && pc_o[7] == 1'b1, "mode 2: ack end");
    pa_i = 8'h42; @(negedge clk) pc_i[4] = 1'b0; repeat (2) @(negedge clk); pc_i[4] = 1'b1; pa_i = 8'h00; repeat (2) @(negedge clk);
    chk(pc_o[5] == 1'b1 && pc_o[3] == 1'b0, "mode 2: ibf, no intr without inte 2");
    wr(2'd3, 8'h09); chk(pc_o[3] == 1'b1, "mode 2: intr by inte 2");
    rd(2'd2, v); chk(v[7:3] == 5'b10111, "mode 2: status word");
    rd(2'd0, v); chk(v == 8'h42 && pc_o[5] == 1'b0, "mode 2: input latch");
    // PPI-10 the RK86 control words: 8Ah keyboard (A out, B in, C upper in, C lower out); 90h ROM disk
    wr(2'd3, 8'h8A); chk(pa_oe && !pb_oe && pc_oe == 8'h0F, "rk86 word 8Ah");
    wr(2'd3, 8'h90); chk(!pa_oe && pb_oe && pc_oe == 8'hFF, "rk86 word 90h");
    if (errors == 0) $display("PASS: vv55");
    $finish;
end
endmodule
