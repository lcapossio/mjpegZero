-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

entity input_buffer is
    generic (
        IMG_WIDTH : natural := 1280
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;

        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tuser  : in  std_logic;

        blk_valid     : out std_logic;
        blk_data      : out std_logic_vector(7 downto 0);
        blk_sof       : out std_logic;
        blk_sob       : out std_logic;
        blk_comp      : out std_logic_vector(1 downto 0);
        blk_ready     : in  std_logic;
        -- May begin a new block (checked at each block's first sample)
        blk_start     : in  std_logic;

        -- Lines-done pulse (8 lines written, blocks ready to read)
        lines_done    : out std_logic;
        -- A strip is buffered and the read side is waiting to issue / issuing it
        blk_avail     : out std_logic
    );
end entity input_buffer;

architecture rtl of input_buffer is

    constant MCU_COLS     : natural := IMG_WIDTH / 16;
    constant Y_BANK_SIZE  : natural := 8 * IMG_WIDTH;
    constant CB_BANK_SIZE : natural := 8 * (IMG_WIDTH / 2);
    constant CR_BANK_SIZE : natural := 8 * (IMG_WIDTH / 2);
    constant CHROMA_WIDTH : natural := IMG_WIDTH / 2;
    -- Counter widths follow IMG_WIDTH (fixed 11-bit x / 7-bit MCU column
    -- counters silently wrapped above 2048 pixels and hung the encoder).
    constant X_W   : natural := imax(clog2(IMG_WIDTH), 1);
    constant COL_W : natural := imax(clog2(MCU_COLS), 1);

    constant Y_ADDR_W  : natural := clog2(2 * Y_BANK_SIZE);
    constant CB_ADDR_W : natural := clog2(2 * CB_BANK_SIZE);
    constant CR_ADDR_W : natural := clog2(2 * CR_BANK_SIZE);

    component bram_sdp is
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
    end component;

    signal y_buf_we    : std_logic := '0';
    signal y_buf_waddr : std_logic_vector(Y_ADDR_W-1 downto 0) := (others => '0');
    signal y_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal y_buf_raddr : std_logic_vector(Y_ADDR_W-1 downto 0) := (others => '0');
    signal y_buf_rdata : std_logic_vector(7 downto 0);

    signal cb_buf_we    : std_logic := '0';
    signal cb_buf_waddr : std_logic_vector(CB_ADDR_W-1 downto 0) := (others => '0');
    signal cb_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal cb_buf_raddr : std_logic_vector(CB_ADDR_W-1 downto 0) := (others => '0');
    signal cb_buf_rdata : std_logic_vector(7 downto 0);

    signal cr_buf_we    : std_logic := '0';
    signal cr_buf_waddr : std_logic_vector(CR_ADDR_W-1 downto 0) := (others => '0');
    signal cr_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal cr_buf_raddr : std_logic_vector(CR_ADDR_W-1 downto 0) := (others => '0');
    signal cr_buf_rdata : std_logic_vector(7 downto 0);

    signal rd_bank            : std_logic := '0';
    signal rd_active          : std_logic := '0';
    signal lines_done_pending : std_logic := '0';
    signal rd_bank_pending    : std_logic := '0';
    signal rd_first_pending   : std_logic := '0';  -- pending strip is a frame's first

    signal wr_bank         : std_logic := '0';
    signal wr_x            : unsigned(X_W-1 downto 0) := (others => '0');
    signal wr_line         : unsigned(2 downto 0) := (others => '0');
    signal wr_phase        : std_logic := '0';
    signal wr_frame_active : std_logic := '0';
    signal wr_strip_first  : std_logic := '0';  -- strip being written is a frame's first
    signal wr_8lines_done  : std_logic := '0';
    signal wr_done_first   : std_logic := '0';  -- qualifies wr_8lines_done

    signal s_axis_tready_i : std_logic;
    signal wr_accept : std_logic;
    signal wr_sof    : std_logic;
    signal wr_take   : std_logic;
    signal px_x      : unsigned(X_W-1 downto 0);
    signal px_line   : unsigned(2 downto 0);
    signal px_phase  : std_logic;
    signal px_first  : std_logic;

    type rd_state_t is (RD_IDLE, RD_READ);
    signal rd_state       : rd_state_t := RD_IDLE;
    signal rd_mcu_col     : unsigned(COL_W-1 downto 0) := (others => '0');
    signal rd_comp        : unsigned(1 downto 0) := (others => '0');
    signal rd_row         : unsigned(2 downto 0) := (others => '0');
    signal rd_col         : unsigned(2 downto 0) := (others => '0');
    signal rd_sof_pending : std_logic := '0';
    signal rd_blk_first   : std_logic;
    signal rd_issue       : std_logic;

    signal rd_valid_pipe : std_logic := '0';
    signal rd_sob_pipe   : std_logic := '0';
    signal rd_comp_pipe  : unsigned(1 downto 0) := (others => '0');
    signal rd_sof_pipe   : std_logic := '0';

    signal blk_valid_r : std_logic := '0';
    signal blk_data_r  : std_logic_vector(7 downto 0) := (others => '0');
    signal blk_sof_r   : std_logic := '0';
    signal blk_sob_r   : std_logic := '0';
    signal blk_comp_r  : unsigned(1 downto 0) := (others => '0');

    signal out_valid_d1 : std_logic := '0';
    signal out_valid_d2 : std_logic := '0';
    signal out_sob_d1   : std_logic := '0';
    signal out_sob_d2   : std_logic := '0';
    signal out_sof_d1   : std_logic := '0';
    signal out_sof_d2   : std_logic := '0';
    signal out_comp_d1  : unsigned(1 downto 0) := (others => '0');
    signal out_comp_d2  : unsigned(1 downto 0) := (others => '0');

begin

    assert IMG_WIDTH > 0 report "IMG_WIDTH must be positive" severity failure;
    assert (IMG_WIDTH mod 16) = 0 report "IMG_WIDTH must be a multiple of 16" severity failure;

    u_y_mem : bram_sdp
        generic map (DEPTH => 2 * Y_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => y_buf_we, waddr => y_buf_waddr,
            wdata => y_buf_wdata, raddr => y_buf_raddr, rdata => y_buf_rdata
        );

    u_cb_mem : bram_sdp
        generic map (DEPTH => 2 * CB_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => cb_buf_we, waddr => cb_buf_waddr,
            wdata => cb_buf_wdata, raddr => cb_buf_raddr, rdata => cb_buf_rdata
        );

    u_cr_mem : bram_sdp
        generic map (DEPTH => 2 * CR_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => cr_buf_we, waddr => cr_buf_waddr,
            wdata => cr_buf_wdata, raddr => cr_buf_raddr, rdata => cr_buf_rdata
        );

    -- Write-side ready: the write bank is not being read (double-buffer
    -- protection). Before the first start-of-frame, words are accepted and
    -- discarded so a source that starts mid-frame cannot stall forever.
    s_axis_tready_i <= '1' when (wr_bank /= rd_bank or rd_active = '0') else '0';
    s_axis_tready <= s_axis_tready_i;
    wr_accept <= s_axis_tvalid and s_axis_tready_i;
    lines_done <= wr_8lines_done;

    -- A start-of-frame word is the frame's pixel (0,0) on line 0 of the current
    -- write bank. The bank is NOT reset: ping-pong continues across frames, so a
    -- new frame never overwrites the previous frame's last strip while it is
    -- still being read out.
    wr_sof   <= wr_accept and s_axis_tuser;
    wr_take  <= wr_accept and (wr_frame_active or s_axis_tuser);
    px_x     <= (others => '0') when wr_sof = '1' else wr_x;
    px_line  <= (others => '0') when wr_sof = '1' else wr_line;
    px_phase <= '0' when wr_sof = '1' else wr_phase;
    px_first <= '1' when wr_sof = '1' else wr_strip_first;

    blk_avail <= '1' when rd_state = RD_READ else '0';

    -- Issue a sample when downstream is ready; a block's first sample also
    -- needs blk_start, so admission is decided on block boundaries only and a
    -- block, once started, is never cut short by the admission gate.
    rd_blk_first <= '1' when rd_row = 0 and rd_col = 0 else '0';
    rd_issue     <= blk_ready and (not rd_blk_first or blk_start);

    blk_valid <= blk_valid_r;
    blk_data <= blk_data_r;
    blk_sof <= blk_sof_r;
    blk_sob <= blk_sob_r;
    blk_comp <= std_logic_vector(blk_comp_r);

    process (clk)
        variable y_addr  : natural;
        variable cb_addr : natural;
        variable cr_addr : natural;
        variable bank_base_y  : natural;
        variable bank_base_cb : natural;
        variable bank_base_cr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                wr_bank <= '0';
                wr_x <= (others => '0');
                wr_line <= (others => '0');
                wr_phase <= '0';
                wr_frame_active <= '0';
                wr_strip_first <= '0';
                wr_8lines_done <= '0';
                wr_done_first <= '0';
                y_buf_we <= '0';
                cb_buf_we <= '0';
                cr_buf_we <= '0';
            else
                y_buf_we <= '0';
                cb_buf_we <= '0';
                cr_buf_we <= '0';
                wr_8lines_done <= '0';

                if wr_take = '1' then
                    wr_frame_active <= '1';
                    wr_strip_first <= px_first;

                    if wr_bank = '1' then
                        bank_base_y := Y_BANK_SIZE;
                        bank_base_cb := CB_BANK_SIZE;
                        bank_base_cr := CR_BANK_SIZE;
                    else
                        bank_base_y := 0;
                        bank_base_cb := 0;
                        bank_base_cr := 0;
                    end if;

                    y_addr := bank_base_y + to_integer(px_line) * IMG_WIDTH + to_integer(px_x);
                    y_buf_we <= '1';
                    y_buf_waddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                    y_buf_wdata <= s_axis_tdata(7 downto 0);

                    if px_phase = '0' then
                        cb_addr := bank_base_cb + to_integer(px_line) * CHROMA_WIDTH + to_integer(px_x) / 2;
                        cb_buf_we <= '1';
                        cb_buf_waddr <= std_logic_vector(to_unsigned(cb_addr, CB_ADDR_W));
                        cb_buf_wdata <= s_axis_tdata(15 downto 8);
                    else
                        cr_addr := bank_base_cr + to_integer(px_line) * CHROMA_WIDTH + to_integer(px_x) / 2;
                        cr_buf_we <= '1';
                        cr_buf_waddr <= std_logic_vector(to_unsigned(cr_addr, CR_ADDR_W));
                        cr_buf_wdata <= s_axis_tdata(15 downto 8);
                    end if;

                    wr_phase <= not px_phase;
                    wr_x <= px_x + 1;
                    wr_line <= px_line;

                    if px_x = to_unsigned(IMG_WIDTH - 1, X_W) or s_axis_tlast = '1' then
                        wr_x <= (others => '0');
                        wr_phase <= '0';
                        if px_line = to_unsigned(7, 3) then
                            wr_line <= (others => '0');
                            wr_8lines_done <= '1';
                            wr_done_first <= px_first;
                            wr_strip_first <= '0';
                            wr_bank <= not wr_bank;
                        else
                            wr_line <= px_line + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable y_addr  : natural;
        variable cb_addr : natural;
        variable cr_addr : natural;
        variable bank_base_y  : natural;
        variable bank_base_cb : natural;
        variable bank_base_cr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_bank <= '0';
                rd_mcu_col <= (others => '0');
                rd_comp <= (others => '0');
                rd_row <= (others => '0');
                rd_col <= (others => '0');
                rd_active <= '0';
                rd_sof_pending <= '0';
                rd_state <= RD_IDLE;
                rd_valid_pipe <= '0';
                rd_sob_pipe <= '0';
                rd_sof_pipe <= '0';
                rd_comp_pipe <= (others => '0');
                lines_done_pending <= '0';
                rd_bank_pending <= '0';
                rd_first_pending <= '0';
            else
                rd_valid_pipe <= '0';
                rd_sob_pipe <= '0';
                rd_sof_pipe <= '0';

                if wr_8lines_done = '1' and rd_state = RD_READ then
                    lines_done_pending <= '1';
                    rd_bank_pending <= not wr_bank;
                    rd_first_pending <= wr_done_first;
                end if;

                case rd_state is
                    when RD_IDLE =>
                        if wr_8lines_done = '1' or lines_done_pending = '1' then
                            rd_active <= '1';
                            if wr_8lines_done = '1' then
                                rd_bank <= not wr_bank;
                                rd_sof_pending <= wr_done_first;
                            else
                                rd_bank <= rd_bank_pending;
                                rd_sof_pending <= rd_first_pending;
                            end if;
                            rd_mcu_col <= (others => '0');
                            rd_comp <= (others => '0');
                            rd_row <= (others => '0');
                            rd_col <= (others => '0');
                            rd_state <= RD_READ;
                            lines_done_pending <= '0';
                        end if;

                    when RD_READ =>
                        if rd_issue = '1' then
                            rd_valid_pipe <= '1';
                            rd_comp_pipe <= rd_comp;

                            if rd_sof_pending = '1' and rd_row = 0 and rd_col = 0 then
                                rd_sof_pipe <= '1';
                                rd_sof_pending <= '0';
                            end if;

                            if rd_row = 0 and rd_col = 0 then
                                rd_sob_pipe <= '1';
                            end if;

                            if rd_bank = '1' then
                                bank_base_y := Y_BANK_SIZE;
                                bank_base_cb := CB_BANK_SIZE;
                                bank_base_cr := CR_BANK_SIZE;
                            else
                                bank_base_y := 0;
                                bank_base_cb := 0;
                                bank_base_cr := 0;
                            end if;

                            case to_integer(rd_comp) is
                                when 0 =>
                                    y_addr := bank_base_y + to_integer(rd_row) * IMG_WIDTH +
                                              to_integer(rd_mcu_col) * 16 + to_integer(rd_col);
                                    y_buf_raddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                                when 1 =>
                                    y_addr := bank_base_y + to_integer(rd_row) * IMG_WIDTH +
                                              to_integer(rd_mcu_col) * 16 + 8 + to_integer(rd_col);
                                    y_buf_raddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                                when 2 =>
                                    cb_addr := bank_base_cb + to_integer(rd_row) * CHROMA_WIDTH +
                                               to_integer(rd_mcu_col) * 8 + to_integer(rd_col);
                                    cb_buf_raddr <= std_logic_vector(to_unsigned(cb_addr, CB_ADDR_W));
                                when others =>
                                    cr_addr := bank_base_cr + to_integer(rd_row) * CHROMA_WIDTH +
                                               to_integer(rd_mcu_col) * 8 + to_integer(rd_col);
                                    cr_buf_raddr <= std_logic_vector(to_unsigned(cr_addr, CR_ADDR_W));
                            end case;

                            rd_col <= rd_col + 1;
                            if rd_col = 7 then
                                rd_col <= (others => '0');
                                rd_row <= rd_row + 1;
                                if rd_row = 7 then
                                    rd_row <= (others => '0');
                                    rd_comp <= rd_comp + 1;
                                    if rd_comp = 3 then
                                        rd_comp <= (others => '0');
                                        rd_mcu_col <= rd_mcu_col + 1;
                                        if rd_mcu_col = to_unsigned(MCU_COLS - 1, COL_W) then
                                            rd_state <= RD_IDLE;
                                            rd_active <= '0';
                                        end if;
                                    end if;
                                end if;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                blk_valid_r <= '0';
                blk_data_r <= (others => '0');
                blk_sof_r <= '0';
                blk_sob_r <= '0';
                blk_comp_r <= (others => '0');
                out_valid_d1 <= '0';
                out_sob_d1 <= '0';
                out_sof_d1 <= '0';
                out_comp_d1 <= (others => '0');
                out_valid_d2 <= '0';
                out_sob_d2 <= '0';
                out_sof_d2 <= '0';
                out_comp_d2 <= (others => '0');
            else
                out_valid_d1 <= rd_valid_pipe;
                out_sob_d1 <= rd_sob_pipe;
                out_sof_d1 <= rd_sof_pipe;
                out_comp_d1 <= rd_comp_pipe;

                out_valid_d2 <= out_valid_d1;
                out_sob_d2 <= out_sob_d1;
                out_sof_d2 <= out_sof_d1;
                out_comp_d2 <= out_comp_d1;

                blk_valid_r <= out_valid_d2;
                blk_sob_r <= out_sob_d2;
                blk_sof_r <= out_sof_d2;
                blk_comp_r <= out_comp_d2;

                if out_comp_d2 <= 1 then
                    blk_data_r <= y_buf_rdata;
                elsif out_comp_d2 = 2 then
                    blk_data_r <= cb_buf_rdata;
                else
                    blk_data_r <= cr_buf_rdata;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
