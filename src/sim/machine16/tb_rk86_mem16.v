// The memory of tb_rk86_machine16: one port at bus_a, read latency 1 clk (as pocket_memory); the output
// follows bus_a, not mem_rd (spec 4.3, 4.5: the 8275 takes the DMA byte at WR↑, after ЧТЕНИЕ has ended);
// written on the falling edge of cpu_wr_n below 8000 unless rom; rom selects the monitor (bios), at every
// address during start-up, when the RAM is off (GLUE-11). A platform gives
// run_machine16_sim.py --mem <files> with a module of the same name and ports.
`default_nettype none
module tb_rk86_mem16(
    input  wire        clk,
    input  wire [15:0] bus_a,
    input  wire  [7:0] cpu_do,
    input  wire        cpu_wr_n,
    input  wire        rom,
    input  wire        aen,
    input  wire        mem_rd,
    output wire  [7:0] mem_di
);
reg [7:0] ram [0:32767];
reg [7:0] bios [0:2047];
reg [7:0] q = 8'h00;
reg wr_q = 1'b1;
integer k;
initial for (k = 0; k < 32768; k = k + 1) ram[k] = 8'h00;
always @(posedge clk) begin
    wr_q <= cpu_wr_n;
    if (wr_q && !cpu_wr_n && !aen && !rom && !bus_a[15]) ram[bus_a[14:0]] <= cpu_do;
    q <= rom ? bios[bus_a[10:0]] : ram[bus_a[14:0]];
end
assign mem_di = q;
endmodule
`default_nettype wire
