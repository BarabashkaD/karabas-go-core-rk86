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
// INTR pulse watch ([C78] Fig. 7, 9, 13: INTR stays low from RD↓ / WR↓ until STB↑ / ACK↑): `arm` before a
// rd / wr starts the watch at its RD↑ / WR↑; every clk with INTR (PC[wbit]) high counts until `endw`
reg arm = 1'b0, watch = 1'b0; reg [2:0] wbit = 3'd3; integer pulses = 0;
always @(posedge clk) if (watch && pc_o[wbit]) pulses = pulses + 1;
task chk(input ok, input [8*48-1:0] what); begin
    if (!ok) begin $display("ERROR: vv55: %0s at %0t", what, $time); errors = errors + 1; end end endtask
task endw(input [8*48-1:0] what); begin chk(pulses == 0, what); watch = 1'b0; pulses = 0; end endtask
task wr(input [1:0] ad, input [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; d = dd; end
    @(negedge clk) wr_n = 1'b0;
    repeat (2) @(negedge clk); mid_pc = pc_o;
    repeat (2) @(negedge clk); wr_n = 1'b1; watch = arm; arm = 1'b0;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
task rd(input [1:0] ad, output [7:0] dd); begin
    @(negedge clk) begin cs_n = 1'b0; a = ad; end
    @(negedge clk) rd_n = 1'b0;
    repeat (2) @(negedge clk); mid_pc = pc_o;
    repeat (2) @(negedge clk); dd = d_o; rd_n = 1'b1; watch = arm; arm = 1'b0;
    @(negedge clk) cs_n = 1'b1;
    repeat (2) @(negedge clk);
end endtask
// a WR / RD pulse with CS high ([C78] 12-77: CS = 1 is no operation)
task wr_nocs(input [1:0] ad, input [7:0] dd); begin
    @(negedge clk) begin a = ad; d = dd; end
    @(negedge clk) wr_n = 1'b0;
    repeat (4) @(negedge clk); wr_n = 1'b1;
    repeat (3) @(negedge clk);
end endtask
task rd_nocs(input [1:0] ad); begin
    @(negedge clk) a = ad;
    @(negedge clk) rd_n = 1'b0;
    repeat (2) @(negedge clk); mid_pc = pc_o;
    repeat (2) @(negedge clk); rd_n = 1'b1;
    repeat (3) @(negedge clk);
end endtask
// a strobe (STB / ACK) of 4 clk on the port C pin `b`
task strobe(input [2:0] b); begin
    @(negedge clk) pc_i[b] = 1'b0;
    repeat (4) @(negedge clk); pc_i[b] = 1'b1;
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
    wbit = 3'd3; arm = 1'b1; rd(2'd0, v); chk(v == 8'h3C, "mode 1 input: latch");
    chk(mid_pc[5] == 1'b1 && mid_pc[3] == 1'b0, "mode 1 input: ibf / intr during rd");
    chk(pc_o[5] == 1'b0 && pc_o[3] == 1'b0, "mode 1 input: ibf after rd");
    endw("intr pulse after rd: mode 1 port A input");
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
    wbit = 3'd3; arm = 1'b1; wr(2'd0, 8'h5A);
    chk(mid_pc[3] == 1'b0, "mode 1 output: intr during wr");
    chk(pa_o == 8'h5A && pc_o[7] == 1'b0 && pc_o[3] == 1'b0, "mode 1 output: obf after wr");
    endw("intr pulse after wr: mode 1 port A output");
    @(negedge clk) pc_i[6] = 1'b0; repeat (3) @(negedge clk);
    chk(pc_o[7] == 1'b1 && pc_o[3] == 1'b0, "mode 1 output: obf after ack");
    pc_i[6] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[3] == 1'b1, "mode 1 output: intr after ack");
    rd(2'd2, v); chk(v[7:6] == 2'b11 && v[3] == 1'b1, "mode 1 output: status word");
    // PPI-7 mode 1, port B input (STB PC2, IBF PC1, INTR PC0) and output (OBF PC1, ACK PC2), INTE B by PC2
    pc_i = 8'hFF; wr(2'd3, 8'h86); wr(2'd3, 8'h05);
    pb_i = 8'h66; @(negedge clk) pc_i[2] = 1'b0; repeat (3) @(negedge clk); pc_i[2] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 input: port B ibf / intr");
    // status read first (Fig. 15: D2 INTE B, D1 IBF B, D0 INTR B); only the port B read clears IBF B (PPI-31)
    rd(2'd2, v); chk(v[2:0] == 3'b111 && pc_o[1] == 1'b1, "mode 1 input: port B status word");
    rd(2'd0, v); chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 input: port B ibf kept by other reads");
    wbit = 3'd0; arm = 1'b1; rd(2'd1, v); chk(v == 8'h66 && pc_o[1] == 1'b0, "mode 1 input: port B");
    endw("intr pulse after rd: mode 1 port B input");
    wr(2'd3, 8'h84); wr(2'd3, 8'h05); chk(pc_o[0] == 1'b1, "mode 1 output: port B intr with empty buffer");
    // only a port B write sets OBF B (PPI-31)
    wr(2'd0, 8'h11); wr(2'd2, 8'h00);
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 output: port B obf kept by other writes");
    wbit = 3'd0; arm = 1'b1; wr(2'd1, 8'h99);
    chk(pb_oe && pb_o == 8'h99 && pc_o[1] == 1'b0, "mode 1 output: port B obf");
    endw("intr pulse after wr: mode 1 port B output");
    rd(2'd2, v); chk(v[2:0] == 3'b100, "mode 1 output: port B status after wr");
    @(negedge clk) pc_i[2] = 1'b0; repeat (3) @(negedge clk); pc_i[2] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b1, "mode 1 output: port B ack");
    rd(2'd2, v); chk(v[2:0] == 3'b111, "mode 1 output: port B status after ack");
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
    // mode 2 INTR: low from WR↓ (INTE 1) / RD↓ (INTE 2) with no pulse after WR↑ / RD↑, high again at
    // ACK↑ / STB↑ with no delay ([C78] 12-87 Fig. 13)
    wr(2'd3, 8'hC0); wr(2'd3, 8'h0D); chk(pc_o[3] == 1'b1, "mode 2: intr by inte 1, empty buffer");
    wbit = 3'd3; arm = 1'b1; wr(2'd0, 8'h55); chk(pc_o[3] == 1'b0 && mid_pc[3] == 1'b0, "mode 2: intr after wr");
    endw("intr pulse after wr: mode 2");
    @(negedge clk) pc_i[6] = 1'b0; repeat (2) @(negedge clk); chk(pc_o[3] == 1'b0, "mode 2: intr during ack");
    pc_i[6] = 1'b1; @(posedge clk) chk(pc_o[3] == 1'b1, "mode 2: intr at ack end");
    wr(2'd3, 8'h0C); wr(2'd3, 8'h09); chk(pc_o[3] == 1'b0, "mode 2: intr without inte 1");
    pa_i = 8'h24; @(negedge clk) pc_i[4] = 1'b0; repeat (2) @(negedge clk); chk(pc_o[3] == 1'b0, "mode 2: intr during stb");
    pc_i[4] = 1'b1; @(posedge clk) chk(pc_o[3] == 1'b1, "mode 2: intr at stb end");
    wbit = 3'd3; arm = 1'b1; rd(2'd0, v); chk(v == 8'h24 && pc_o[3] == 1'b0 && mid_pc[3] == 1'b0, "mode 2: intr after rd");
    endw("intr pulse after rd: mode 2");
    // PPI-3 a mode-set write clears the status flip-flops and INTE ([C78] 12-79, 12-80): IBF A / B
    // (B6h: A and B mode 1 input), OBF A / B (A4h: A and B mode 1 output)
    pc_i = 8'hFF; wr(2'd3, 8'hB6); wr(2'd3, 8'h09); wr(2'd3, 8'h05);
    pa_i = 8'h11; pb_i = 8'h22; @(negedge clk) begin pc_i[4] = 1'b0; pc_i[2] = 1'b0; end
    repeat (4) @(negedge clk); pc_i[4] = 1'b1; pc_i[2] = 1'b1; repeat (2) @(negedge clk);
    chk(pc_o[5] && pc_o[3] && pc_o[1] && pc_o[0], "mode set: status setup (ibf a / b)");
    wr(2'd3, 8'hB6);
    chk(pc_o[5] == 1'b0 && pc_o[1] == 1'b0 && pc_o[3] == 1'b0 && pc_o[0] == 1'b0, "mode set: status ibf not cleared");
    rd(2'd2, v); chk(v[5:0] == 6'b000000, "mode set: status word (input)");
    wr(2'd3, 8'hA4); wr(2'd0, 8'h12); wr(2'd1, 8'h34);
    chk(pc_o[7] == 1'b0 && pc_o[1] == 1'b0, "mode set: status setup (obf a / b)");
    wr(2'd3, 8'hA4);
    chk(pc_o[7] == 1'b1 && pc_o[1] == 1'b1, "mode set: status obf not cleared");
    rd(2'd2, v); chk(v[7] && !v[6] && !v[2] && v[1], "mode set: status word (output)");
    // PPI-9, PPI-31 RD and WR act only with CS low ([C78] 12-77): A mode 1 output with INTE A, then input
    wr(2'd3, 8'hA0); wr(2'd3, 8'h0D);
    wr_nocs(2'd0, 8'h5A);
    chk(pa_o == 8'h00 && pc_o[7] == 1'b1 && pc_o[3] == 1'b1, "cs: wr without cs");
    wr(2'd3, 8'hB0); wr(2'd3, 8'h09);
    pa_i = 8'h5C; strobe(3'd4); pa_i = 8'h00;
    chk(pc_o[5] == 1'b1 && pc_o[3] == 1'b1, "cs: rd setup (ibf)");
    rd_nocs(2'd0);
    chk(pc_o[5] == 1'b1 && pc_o[3] == 1'b1 && mid_pc[3] == 1'b1, "cs: rd without cs");
    rd(2'd0, v); chk(v == 8'h5C && pc_o[5] == 1'b0, "cs: rd with cs");
    // PPI-32 (SILENT, accepted): the input latch follows the port while STB is low; a second STB overwrites
    pa_i = 8'h11; @(negedge clk) pc_i[4] = 1'b0; repeat (2) @(negedge clk); pa_i = 8'h22; repeat (2) @(negedge clk);
    pc_i[4] = 1'b1; pa_i = 8'h00; repeat (2) @(negedge clk);
    rd(2'd0, v); chk(v == 8'h22, "input latch: transparent while stb low");
    pa_i = 8'h44; strobe(3'd4); pa_i = 8'h55; strobe(3'd4); pa_i = 8'h00;
    rd(2'd0, v); chk(v == 8'h55, "input latch: second stb overwrites");
    // PPI-29 a port C byte write leaves INTE (ruling): B0h, INTE A = 1, data C7h with bit 4 = 0, then 10h
    wr(2'd3, 8'hB0); wr(2'd3, 8'h09);
    // outputs PC7, PC6, PC2-PC0; PC5 IBF = 0, PC4 STB (input), PC3 INTR = 0
    wr(2'd2, 8'hC7); chk(pc_o == 8'hC7, "byte write inte: pattern C7h");
    rd(2'd2, v); chk(v[4] == 1'b1, "byte write inte: inte cleared by C7h");
    wr(2'd2, 8'h10); chk(pc_o == 8'h00, "byte write inte: pattern 10h");
    rd(2'd2, v); chk(v[4] == 1'b1, "byte write inte: inte changed by 10h");
    // PPI-24, PPI-29 group A mode 0 with group B mode 1 (ruling): PC3 by D0, PC7-PC4 by D3
    wr(2'd3, 8'h8E); chk(pc_oe == 8'h0B, "pc3 mixed: 8Eh pins");
    wr(2'd2, 8'hFF); chk(pc_o[7:3] == 5'b00001, "pc3 mixed: 8Eh byte write");
    wr(2'd3, 8'h8C); chk(pc_oe == 8'h0B, "pc3 mixed: 8Ch pins");
    wr(2'd2, 8'hFF); chk(pc_o[7:3] == 5'b00001, "pc3 mixed: 8Ch byte write");
    wr(2'd3, 8'h87); chk(pc_oe == 8'hF3, "pc3 mixed: 87h pins");
    wr(2'd2, 8'hFF); chk(pc_o[7:3] == 5'b11110, "pc3 mixed: 87h byte write");
    // PPI-22 (SILENT, accepted): a control register read gives FFh
    rd(2'd3, v); chk(v == 8'hFF, "control register read");
    // PPI-25 mixed groups (B4h: A mode 1 input, B mode 1 output): D7-D3 of the input word, D2-D0 of the
    // output word
    wr(2'd3, 8'hB4); wr(2'd3, 8'h09); wr(2'd3, 8'h05);
    pa_i = 8'h0F; strobe(3'd4); pa_i = 8'h00;
    rd(2'd2, v); chk(v == 8'h3F, "status word: a input, b output empty");
    wr(2'd1, 8'h66);
    rd(2'd2, v); chk(v == 8'h3C, "status word: a input, b output full");
    // PPI-26 mode 2 with group B mode 1 input (C6h): PC7-PC3 group A, PC2-PC0 the group B handshake;
    // D2 is INTE B, not the STB B pin (high)
    wr(2'd3, 8'hC6); chk(pc_oe == 8'hAB && !pa_oe && !pb_oe, "mode 2 + b mode 1: pins");
    pb_i = 8'h5B; strobe(3'd2); pb_i = 8'h00;
    chk(pc_o[1] == 1'b1 && pc_o[0] == 1'b0 && pc_o[3] == 1'b0, "mode 2 + b mode 1: ibf b");
    rd(2'd2, v); chk(v == 8'h82, "mode 2 + b mode 1: status word, inte b 0");
    wr(2'd3, 8'h05); chk(pc_o[0] == 1'b1 && pc_o[3] == 1'b0, "mode 2 + b mode 1: intr b");
    rd(2'd2, v); chk(v == 8'h87, "mode 2 + b mode 1: status word");
    rd(2'd1, v); chk(v == 8'h5B && pc_o[1] == 1'b0, "mode 2 + b mode 1: port B");
    // PPI-1 RESET from a state that differs from it ([C78] 12-78 RESET: the control register cleared, every port an
    // input): C6h (mode 2, B mode 1 input) with INTE B, then OBF A (port A written) and INTE 1 (0Dh); a 2-clk pulse
    wr(2'd0, 8'h77); wr(2'd3, 8'h0D);
    chk(pc_oe == 8'hAB && pc_o[7] == 1'b0 && pa_o == 8'h77, "reset: setup (mode 2, obf a, latch a)");
    @(negedge clk) reset = 1'b1; repeat (2) @(negedge clk); reset = 1'b0; repeat (2) @(negedge clk);
    chk(!pa_oe && !pb_oe && pc_oe == 8'h00, "reset: ports not inputs after a RESET pulse");
    chk(pa_o == 8'h00 && pb_o == 8'h00 && pc_o == 8'h00, "reset: output latches not cleared");
    pa_i = 8'h3C; pb_i = 8'hC3; pc_i = 8'h5A;
    rd(2'd0, v); chk(v == 8'h3C, "reset: port A read not the pins (mode 0)");
    rd(2'd1, v); chk(v == 8'hC3, "reset: port B read not the pins (mode 0)");
    rd(2'd2, v); chk(v == 8'h5A, "reset: port C read not the pins (mode 0)");
    pc_i = 8'hFF;
    // PPI-10 the RK86 control words: 8Ah keyboard (A out, B in, C upper in, C lower out); 90h ROM disk
    wr(2'd3, 8'h8A); chk(pa_oe && !pb_oe && pc_oe == 8'h0F, "rk86 word 8Ah");
    wr(2'd3, 8'h90); chk(!pa_oe && pb_oe && pc_oe == 8'hFF, "rk86 word 90h");
    if (errors == 0) $display("PASS: vv55");
    $finish;
end
endmodule
`default_nettype wire
