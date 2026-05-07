-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

-- Vendor-neutral inferred simple dual-port RAM.
-- Read latency is two clocks to match the vendor RAM shims used by optimized
-- synthesis flows.
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
    subtype data_t is std_logic_vector(WIDTH-1 downto 0);
    type ram_t is array (0 to DEPTH-1) of data_t;

    signal mem : ram_t;
    signal rdata_r : data_t := (others => '0');
    signal rdata_q : data_t := (others => '0');
begin

    assert DEPTH > 0 report "DEPTH must be positive" severity failure;
    assert WIDTH > 0 report "WIDTH must be positive" severity failure;

    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                mem(to_integer(unsigned(waddr))) <= wdata;
            end if;
            rdata_r <= mem(to_integer(unsigned(raddr)));
            rdata_q <= rdata_r;
        end if;
    end process;

    rdata <= rdata_q;

end architecture rtl;
