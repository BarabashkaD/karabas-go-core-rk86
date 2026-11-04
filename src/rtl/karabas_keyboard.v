// The keyboard of the Karabas boards: HID reports and joysticks from the MCU to the
// Radio-86RK keyboard matrix, and the autorun macros. Its interface, as agreed in
// docs/contract.md; the body comes with the extraction from the board tops.
`default_nettype none

module karabas_keyboard(
	input         clk,
	input         areset,
	input         osd_act,          // the OSD is open: keys go to the OSD
	input   [7:0] hid_kb_status,
	input   [7:0] hid_kb_dat0,
	input   [7:0] hid_kb_dat1,
	input   [7:0] hid_kb_dat2,
	input   [7:0] hid_kb_dat3,
	input   [7:0] hid_kb_dat4,
	input   [7:0] hid_kb_dat5,
	input  [12:0] joy_l,
	input  [12:0] joy_r,
	input   [7:0] ppa_pa,           // rows from the machine (PPI port A)
	input         loading,
	input         loaded_done,
	input         enable_autorun,
	output  [7:0] kbd_cols,         // columns to the machine (PPI port B)
	output  [2:0] kbd_shift,        // PC7..PC5, active low: right Ctrl, left Ctrl, Shift
	output        joy_rst
);

endmodule

`default_nettype wire
