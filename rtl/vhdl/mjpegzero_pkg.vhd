-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mjpegzero_pkg is

    function clog2(n : positive) return natural;

end package mjpegzero_pkg;

package body mjpegzero_pkg is

    function clog2(n : positive) return natural is
        variable value  : natural := n - 1;
        variable result : natural := 0;
    begin
        while value > 0 loop
            value  := value / 2;
            result := result + 1;
        end loop;
        return result;
    end function clog2;

end package body mjpegzero_pkg;
