// The 8255A (КР580ВВ55А) to its data sheet ([C78] 12-76..12-90; Task 2 PPI-n): modes 0, 1, 2 with the
// port C handshakes, bit set / reset, every mode-set write clearing the output latches, the status
// flip-flops and INTE (no comparison with the old mode), the port C status words; the free port C bits
// by their group's direction bit, port C byte writes to the output bits only; RD / WR with CS and the
// port's A1 A0. Pins: *_i is the level the board drives, *_o / *_oe what the chip drives. A write
// completes on WR↑ with the address and data held while WR was low.
`default_nettype none
module k580vv55(
    input  wire       clk,
    input  wire       reset,
    input  wire       cs_n,
    input  wire       rd_n,
    input  wire       wr_n,
    input  wire [1:0] a,
    input  wire [7:0] d_i,
    output reg  [7:0] d_o,
    input  wire [7:0] pa_i,
    output wire [7:0] pa_o,
    output wire       pa_oe,
    input  wire [7:0] pb_i,
    output wire [7:0] pb_o,
    output wire       pb_oe,
    input  wire [7:0] pc_i,
    output wire [7:0] pc_o,
    output wire [7:0] pc_oe
);
reg [6:0] mode = 7'b0011011;                     // SILENT: reset = mode 0, every port an input
reg [7:0] la = 8'h00, lb = 8'h00, lc = 8'h00;    // output latches
reg [7:0] ia = 8'h00, ib = 8'h00;                // input latches (modes 1, 2)
reg ibfa = 1'b0, ibfb = 1'b0, obfa_n = 1'b1, obfb_n = 1'b1;
reg intea1 = 1'b0, intea2 = 1'b0, inteb = 1'b0;  // INTE A (mode 1) / INTE 1 (mode 2), INTE 2, INTE B
reg wr_q = 1'b1, wcs = 1'b0;
reg [1:0] wa = 2'd0;
reg [7:0] wd = 8'h00;
reg rda_q = 1'b0, rdb_q = 1'b0;
wire a_m2 = mode[6];
wire a_m1 = mode[6:5] == 2'b01;
wire a_m0 = mode[6:5] == 2'b00;
wire a_in = mode[4], cu_in = mode[3], b_m1 = mode[2], b_in = mode[1], cl_in = mode[0];
wire stba_n = pc_i[4], acka_n = pc_i[6], stbb_n = pc_i[2], ackb_n = pc_i[2];
wire rd_a = !cs_n && !rd_n && a == 2'd0;
wire rd_b = !cs_n && !rd_n && a == 2'd1;
wire wr_a = !cs_n && !wr_n && a == 2'd0;
wire wr_b = !cs_n && !wr_n && a == 2'd1;
// INTR ([C78] 12-84, 12-85, 12-87: INTR = IBF·INTE·STB·RD + OBF·INTE·ACK·WR, levels, OBF high = empty)
wire intra = a_m2 ? ((ibfa && intea2 && stba_n && !rd_a) || (obfa_n && intea1 && acka_n && !wr_a))
           : a_m1 ? (a_in ? (ibfa && intea1 && stba_n && !rd_a) : (obfa_n && intea1 && acka_n && !wr_a))
           : 1'b0;
wire intrb = b_m1 ? (b_in ? (ibfb && inteb && stbb_n && !rd_b) : (obfb_n && inteb && ackb_n && !wr_b)) : 1'b0;
// port C: the handshake positions ([C78] 12-89 Mode Definition Summary)
reg [7:0] ctl, ctl_out, ctl_val;
always @(*) begin
    ctl = 8'h00; ctl_out = 8'h00; ctl_val = 8'h00;
    if (a_m2) begin
        ctl[7:3] = 5'b11111; ctl_out[7] = 1'b1; ctl_out[5] = 1'b1; ctl_out[3] = 1'b1;
        ctl_val[7] = obfa_n; ctl_val[5] = ibfa; ctl_val[3] = intra;
    end else if (a_m1) begin
        ctl[3] = 1'b1; ctl_out[3] = 1'b1; ctl_val[3] = intra;
        if (a_in) begin ctl[5:4] = 2'b11; ctl_out[5] = 1'b1; ctl_val[5] = ibfa; end
        else begin ctl[7:6] = 2'b11; ctl_out[7] = 1'b1; ctl_val[7] = obfa_n; end
    end
    if (b_m1) begin
        ctl[2:0] = 3'b111; ctl_out[1:0] = 2'b11; ctl_val[0] = intrb; ctl_val[1] = b_in ? ibfb : obfb_n;
    end
end
wire [7:0] io_out = {{4{!cu_in}}, {4{!cl_in}}};    // PPI-24: by the group's direction bit (PC3: bit 0)
wire [7:0] pc_wmask = ~ctl & io_out;               // PPI-29: the bits a port C byte write changes
assign pc_oe = ctl_out | (~ctl & io_out);
assign pc_o = (ctl_out & ctl_val) | (~ctl & lc);
wire [7:0] pc_pin = (pc_oe & pc_o) | (~pc_oe & pc_i);
assign pa_o = la;
assign pa_oe = a_m2 ? !acka_n : !a_in;
assign pb_o = lb;
assign pb_oe = !b_in;
wire [7:0] pa_pin = pa_oe ? la : pa_i;
wire [7:0] pb_pin = pb_oe ? lb : pb_i;
// reads: the port C status words ([C78] 12-89 Fig. 15, 16)
reg [7:0] pc_rd;
always @(*) begin
    pc_rd = pc_pin;
    if (a_m2) begin pc_rd[7] = obfa_n; pc_rd[6] = intea1; pc_rd[5] = ibfa; pc_rd[4] = intea2; pc_rd[3] = intra; end
    else if (a_m1) begin
        pc_rd[3] = intra;
        if (a_in) begin pc_rd[5] = ibfa; pc_rd[4] = intea1; end
        else begin pc_rd[7] = obfa_n; pc_rd[6] = intea1; end
    end
    if (b_m1) begin pc_rd[2] = inteb; pc_rd[1] = b_in ? ibfb : obfb_n; pc_rd[0] = intrb; end
    case (a)
        2'd0: d_o = a_m0 ? pa_pin : (a_m2 || a_in) ? ia : la;    // SILENT: mode 1 output reads the latch
        2'd1: d_o = !b_m1 ? pb_pin : b_in ? ib : lb;
        2'd2: d_o = pc_rd;
        default: d_o = 8'hFF;                                    // SILENT: control register read
    endcase
end
always @(posedge clk) begin
    wr_q <= wr_n;
    if (!wr_n) begin wcs <= !cs_n; wa <= a; wd <= d_i; end
    rda_q <= rd_a; rdb_q <= rd_b;
    if (reset) begin
        mode <= 7'b0011011; la <= 8'h00; lb <= 8'h00; lc <= 8'h00;
        ibfa <= 1'b0; ibfb <= 1'b0; obfa_n <= 1'b1; obfb_n <= 1'b1;
        intea1 <= 1'b0; intea2 <= 1'b0; inteb <= 1'b0;
    end else begin
        // strobed input: the latch follows the port while STB is low; IBF set by STB low, reset by RD↑
        if ((a_m2 || (a_m1 && a_in)) && !stba_n) begin ia <= pa_i; ibfa <= 1'b1; end
        if (rda_q && !rd_a) ibfa <= 1'b0;
        if (b_m1 && b_in && !stbb_n) begin ib <= pb_i; ibfb <= 1'b1; end
        if (rdb_q && !rd_b) ibfb <= 1'b0;
        // strobed output: OBF (low = full) set by WR↑, reset by ACK low
        if (!acka_n) obfa_n <= 1'b1;
        if (!ackb_n) obfb_n <= 1'b1;
        if (wr_n && !wr_q && wcs) begin
            case (wa)
                2'd0: begin la <= wd; if (a_m2 || (a_m1 && !a_in)) obfa_n <= 1'b0; end
                2'd1: begin lb <= wd; if (b_m1 && !b_in) obfb_n <= 1'b0; end
                2'd2: lc <= (lc & ~pc_wmask) | (wd & pc_wmask);                    // only the output bits
                default:
                    if (wd[7]) begin                                                  // PPI-3, D14: every write
                        mode <= wd[6:0];
                        la <= 8'h00; lb <= 8'h00; lc <= 8'h00;
                        ibfa <= 1'b0; ibfb <= 1'b0; obfa_n <= 1'b1; obfb_n <= 1'b1;
                        intea1 <= 1'b0; intea2 <= 1'b0; inteb <= 1'b0;
                    end else begin
                        lc[wd[3:1]] <= wd[0];                                         // SILENT: handshake bits
                        if (a_m2 && wd[3:1] == 3'd6) intea1 <= wd[0];
                        if (a_m2 && wd[3:1] == 3'd4) intea2 <= wd[0];
                        if (a_m1 && a_in && wd[3:1] == 3'd4) intea1 <= wd[0];
                        if (a_m1 && !a_in && wd[3:1] == 3'd6) intea1 <= wd[0];
                        if (b_m1 && wd[3:1] == 3'd2) inteb <= wd[0];
                    end
            endcase
        end
    end
end
endmodule
`default_nettype wire
