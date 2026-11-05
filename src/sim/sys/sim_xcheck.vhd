-- X-check trigger for the VHDL sim copies: a global signal driven from sim_ctl.xcheck
-- (src/sim/sys/sim_ctl.v) through the bridge entity. The checkers inserted by gen_sim.py wait
-- on work.sim_xcheck_pkg.xcheck.
library ieee;
use ieee.std_logic_1164.all;

package sim_xcheck_pkg is
	signal xcheck : std_logic := '0';
end package;

library ieee;
use ieee.std_logic_1164.all;

entity sim_xcheck_bridge is
	port (x : in std_logic);
end entity;

architecture sim of sim_xcheck_bridge is
begin
	process (x)
	begin
		work.sim_xcheck_pkg.xcheck <= x;
	end process;
end architecture;
