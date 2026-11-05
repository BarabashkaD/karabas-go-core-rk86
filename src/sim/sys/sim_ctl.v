`timescale 1ns / 1ps
// Simulation control, a second top (fuse -top work.sim_ctl), like glbl: the module-local
// X-checkers of the sim copies refer to it by its absolute name, so the TB and the checkers
// need no hierarchical path into the DUT.
//   sim_ctl.xcheck  the TB raises it after the prologue (and again at any later check point);
//                   every rising edge runs all X-checkers (Verilog: always @(posedge sim_ctl.xcheck),
//                   VHDL: wait until work.sim_xcheck_pkg.xcheck = '1' through sim_xcheck_bridge).
//   sim_ctl.xcount  Verilog checkers count the registers found X; VHDL checkers only report
//                   ("XCHECK <path>" notes in the log).
module sim_ctl;
reg xcheck = 1'b0;
integer xcount = 0;
sim_xcheck_bridge bridge(.x(xcheck));
endmodule
