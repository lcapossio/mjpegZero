-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

entity bram_sdp is
    generic (
        DEPTH : natural := 8192;
        WIDTH : natural := 8
    );
    port (
        clk   : in  std_logic;
        we    : in  std_logic;
        waddr : in  std_logic_vector(clog2(DEPTH)-1 downto 0);
        wdata : in  std_logic_vector(WIDTH-1 downto 0);
        raddr : in  std_logic_vector(clog2(DEPTH)-1 downto 0);
        rdata : out std_logic_vector(WIDTH-1 downto 0)
    );
end entity bram_sdp;

architecture rtl of bram_sdp is
    type mem_t is array (0 to DEPTH-1) of std_logic_vector(WIDTH-1 downto 0);
    signal mem     : mem_t;
    signal rdata_r : std_logic_vector(WIDTH-1 downto 0);

    attribute ram_style : string;
    attribute ramstyle : string;
    attribute syn_ramstyle : string;
    attribute ram_style of mem : signal is "block";
    attribute ramstyle of mem : signal is "no_rw_check";
    attribute syn_ramstyle of mem : signal is "block_ram";
begin

    assert DEPTH > 0 report "DEPTH must be positive" severity failure;
    assert WIDTH > 0 report "WIDTH must be positive" severity failure;

    process (clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                mem(to_integer(unsigned(waddr))) <= wdata;
            end if;

            rdata_r <= mem(to_integer(unsigned(raddr)));
            rdata <= rdata_r;
        end if;
    end process;

end architecture rtl;
