-- X-check trigger and count for the VHDL sim copies (src/sim/sys/sim_ctl.v).
-- sim_xcheck_pkg.xcheck: a global signal driven from sim_ctl.xcheck through the bridge; the
-- checkers inserted by gen_sim.py wait on it, report every register found X and increment the
-- shared variable sim_xcheck_pkg.xcount. The bridge copies xcount to its port n 1 ps after every
-- rising edge of x (the checkers run in the delta cycles of the edge); sim_ctl adds it to the
-- Verilog count (sim_ctl.xtotal).
library ieee;
use ieee.std_logic_1164.all;

package sim_xcheck_pkg is
	signal xcheck : std_logic := '0';
	shared variable xcount : integer := 0;
end package;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sim_xcheck_bridge is
	port (
		x : in std_logic;
		n : out std_logic_vector(31 downto 0) := (others => '0')
	);
end entity;

architecture sim of sim_xcheck_bridge is
begin
	process (x)
	begin
		work.sim_xcheck_pkg.xcheck <= x;
	end process;

	process
	begin
		wait until x = '1';
		wait for 1 ps;
		n <= std_logic_vector(to_unsigned(work.sim_xcheck_pkg.xcount, 32));
	end process;
end architecture;
