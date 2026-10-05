-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mjpegzero_pkg is

    function clog2(n : positive) return natural;
    function imax(a, b : integer) return integer;
    -- Video input width: 24-bit RGB888 when RGB_INPUT=1, else 16-bit YUYV
    function vid_data_w(rgb_input : natural) return positive;

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

    function imax(a, b : integer) return integer is
    begin
        if a > b then
            return a;
        end if;
        return b;
    end function imax;

    function vid_data_w(rgb_input : natural) return positive is
    begin
        if rgb_input /= 0 then
            return 24;
        end if;
        return 16;
    end function vid_data_w;

end package body mjpegzero_pkg;
