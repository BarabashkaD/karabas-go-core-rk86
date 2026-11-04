// The keyboard of the Karabas boards: HID reports and joysticks from the MCU to the
// Radio-86RK keyboard matrix, and the autorun macros (docs/contract.md). The code is
// the one of the board tops, moved without changes.
`default_nettype none

module karabas_keyboard(
	input  wire        clk,
	input  wire        areset,
	input  wire        osd_act,          // the OSD is open: keys go to the OSD
	input  wire  [7:0] hid_kb_status,
	input  wire  [7:0] hid_kb_dat0,
	input  wire  [7:0] hid_kb_dat1,
	input  wire  [7:0] hid_kb_dat2,
	input  wire  [7:0] hid_kb_dat3,
	input  wire  [7:0] hid_kb_dat4,
	input  wire  [7:0] hid_kb_dat5,
	input  wire [12:0] joy_l,
	input  wire [12:0] joy_r,
	input  wire  [7:0] ppa_pa,           // rows from the machine (PPI port A)
	input  wire        loading,
	input  wire        loaded_done,
	input  wire        enable_autorun,
	output wire  [7:0] kbd_cols,         // columns to the machine (PPI port B)
	output wire  [2:0] kbd_shift,        // PC7..PC5, active low: right Ctrl, left Ctrl, Shift
	output wire        joy_rst
);

// Not driven, as in the board tops before the extraction: implicit 1-bit nets into
// the 3-bit JOY_TYPE inputs of hid_parser, and the 8-bit JOY_DO into a 1-bit net.
wire kb_joy_type_l;
wire kb_joy_type_r;
wire joy_bus;

wire[7:0] symbol;
wire macros_act;

hid_parser hid_parser(
	.CLK(clk),
	.RESET(areset),
	.OSD_ACT(osd_act),

	.KB_STATUS(hid_kb_status),
	.KB_DAT0((macros_act & loaded_done)? symbol : hid_kb_dat0),
	.KB_DAT1(hid_kb_dat1),
	.KB_DAT2(hid_kb_dat2),
	.KB_DAT3(hid_kb_dat3),
	.KB_DAT4(hid_kb_dat4),
	.KB_DAT5(hid_kb_dat5),

	.JOY_TYPE_L(kb_joy_type_l),
	.JOY_TYPE_R(kb_joy_type_r),
	.JOY_L(joy_l),
	.JOY_R(joy_r),
	.JOY_RST(joy_rst),

	.KB_TYPE(1'b1),
	.A (ppa_pa),

	.JOY_DO(joy_bus),
	.KB_DO(kbd_cols),
	.SHIFTS(kbd_shift)
);

//---------- Macros -------------------
macros macros (.clk50(clk),
					.loading(loading),
					.sym(symbol),
					.macros_act(macros_act),
					.enable(enable_autorun)
);

endmodule

`default_nettype wire
