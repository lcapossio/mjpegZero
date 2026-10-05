-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

-- Native VHDL structural top for mjpegzero_enc_top.
--
-- This is the translated structural encoder top. The VHDL top-level
-- regression reuses the existing SystemVerilog testbench as the golden
-- driver/checker.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

entity mjpegzero_enc_top is
    generic (
        LITE_MODE     : natural := 1;
        LITE_QUALITY  : natural := 95;
        IMG_WIDTH     : natural := 1280;
        IMG_HEIGHT    : natural := 720;
        EXIF_ENABLE   : natural := 0;
        EXIF_X_RES    : natural := 72;
        EXIF_Y_RES    : natural := 72;
        EXIF_RES_UNIT : natural := 2;
        RGB_INPUT     : natural := 0;
        HUFF_BANKS    : natural := 8
    );
    port (
        clk   : in  std_logic;
        rst_n : in  std_logic;

        -- 24-bit {R,G,B} when RGB_INPUT=1, else 16-bit YUYV (derived)
        s_axis_vid_tdata  : in  std_logic_vector(vid_data_w(RGB_INPUT) - 1 downto 0);
        s_axis_vid_tvalid : in  std_logic;
        s_axis_vid_tready : out std_logic;
        s_axis_vid_tlast  : in  std_logic;
        s_axis_vid_tuser  : in  std_logic;

        m_axis_jpg_tvalid : out std_logic;
        m_axis_jpg_tdata  : out std_logic_vector(7 downto 0);
        m_axis_jpg_tlast  : out std_logic;

        s_axi_awaddr  : in  std_logic_vector(4 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(4 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic
    );
end entity mjpegzero_enc_top;

architecture rtl of mjpegzero_enc_top is

    component axi4_lite_regs is
        generic (LITE_MODE : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axi_awaddr : in std_logic_vector(4 downto 0);
            s_axi_awvalid : in std_logic; s_axi_awready : out std_logic;
            s_axi_wdata : in std_logic_vector(31 downto 0);
            s_axi_wstrb : in std_logic_vector(3 downto 0);
            s_axi_wvalid : in std_logic; s_axi_wready : out std_logic;
            s_axi_bresp : out std_logic_vector(1 downto 0);
            s_axi_bvalid : out std_logic; s_axi_bready : in std_logic;
            s_axi_araddr : in std_logic_vector(4 downto 0);
            s_axi_arvalid : in std_logic; s_axi_arready : out std_logic;
            s_axi_rdata : out std_logic_vector(31 downto 0);
            s_axi_rresp : out std_logic_vector(1 downto 0);
            s_axi_rvalid : out std_logic; s_axi_rready : in std_logic;
            ctrl_enable : out std_logic; ctrl_soft_reset : out std_logic;
            ctrl_quality : out std_logic_vector(6 downto 0);
            ctrl_restart_interval : out std_logic_vector(15 downto 0);
            sts_busy : in std_logic; sts_frame_done_pulse : in std_logic;
            sts_frame_cnt : in std_logic_vector(31 downto 0);
            sts_frame_size : in std_logic_vector(31 downto 0)
        );
    end component;

    component input_buffer is
        generic (IMG_WIDTH : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axis_tdata : in std_logic_vector(15 downto 0);
            s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
            s_axis_tlast : in std_logic; s_axis_tuser : in std_logic;
            blk_valid : out std_logic; blk_data : out std_logic_vector(7 downto 0);
            blk_sof : out std_logic; blk_sob : out std_logic;
            blk_comp : out std_logic_vector(1 downto 0);
            blk_ready : in std_logic; blk_start : in std_logic;
            lines_done : out std_logic; blk_avail : out std_logic
        );
    end component;

    component dct_2d is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(11 downto 0);
            in_sof : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sof : out std_logic
        );
    end component;

    component quantizer is
        generic (LITE_MODE : natural; LITE_QUALITY : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            comp_id : in std_logic_vector(1 downto 0);
            quality : in std_logic_vector(6 downto 0);
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sof : in std_logic; in_sob : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sof : out std_logic; out_sob : out std_logic;
            qt_rd_addr : in std_logic_vector(5 downto 0);
            qt_rd_is_chroma : in std_logic; qt_rd_data : out std_logic_vector(7 downto 0);
            tables_busy : out std_logic
        );
    end component;

    component zigzag_reorder is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sob : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sob : out std_logic
        );
    end component;

    component huffman_encoder is
        generic (HUFF_BANKS : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            comp_id : in std_logic_vector(1 downto 0); restart : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sob : in std_logic;
            out_valid : out std_logic; out_bits : out std_logic_vector(31 downto 0);
            out_len : out std_logic_vector(5 downto 0);
            out_sob : out std_logic; out_eob : out std_logic;
            out_ready : in std_logic
        );
    end component;

    component bitstream_packer is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_bits : in std_logic_vector(31 downto 0);
            in_len : in std_logic_vector(5 downto 0);
            in_flush : in std_logic; in_restart : in std_logic;
            bp_ready : out std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(7 downto 0);
            out_last : out std_logic; out_ready : in std_logic;
            byte_count : out std_logic_vector(31 downto 0)
        );
    end component;

    component jfif_writer is
        generic (
            IMG_WIDTH : natural; IMG_HEIGHT : natural;
            LITE_MODE : natural; LITE_QUALITY : natural;
            EXIF_ENABLE : natural; EXIF_X_RES : natural;
            EXIF_Y_RES : natural; EXIF_RES_UNIT : natural
        );
        port (
            clk : in std_logic; rst_n : in std_logic;
            frame_start : in std_logic; frame_done : in std_logic;
            restart_interval : in std_logic_vector(15 downto 0);
            qt_rd_addr : out std_logic_vector(5 downto 0);
            qt_rd_is_chroma : out std_logic;
            qt_rd_data : in std_logic_vector(7 downto 0);
            scan_valid : in std_logic; scan_data : in std_logic_vector(7 downto 0);
            scan_last : in std_logic; scan_ready : out std_logic;
            m_axis_tvalid : out std_logic; m_axis_tdata : out std_logic_vector(7 downto 0);
            m_axis_tlast : out std_logic; headers_done : out std_logic
        );
    end component;

    component rgb_to_ycbcr is
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axis_tdata : in std_logic_vector(23 downto 0);
            s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
            s_axis_tlast : in std_logic; s_axis_tuser : in std_logic;
            m_axis_tdata : out std_logic_vector(15 downto 0);
            m_axis_tvalid : out std_logic; m_axis_tready : in std_logic;
            m_axis_tlast : out std_logic; m_axis_tuser : out std_logic
        );
    end component;

    -- Frame control (see p_frame_control)
    constant TOTAL_BLOCKS : natural := (IMG_WIDTH / 16) * (IMG_HEIGHT / 8) * 4;
    constant BLK_W        : natural := clog2(TOTAL_BLOCKS + 1);
    constant LAST_BLOCK   : unsigned(BLK_W-1 downto 0) := to_unsigned(TOTAL_BLOCKS - 1, BLK_W);

    type fstate_t is (F_IDLE, F_QWAIT, F_RUN, F_DRAIN);

    signal ctrl_enable : std_logic;
    signal ctrl_soft_reset : std_logic;
    signal ctrl_quality : std_logic_vector(6 downto 0);
    signal ctrl_restart_interval : std_logic_vector(15 downto 0);
    signal sts_busy : std_logic;
    signal sts_frame_done_pulse : std_logic;
    signal frame_cnt : unsigned(31 downto 0) := (others => '0');
    signal rst_int_n : std_logic;

    signal ibuf_blk_valid : std_logic;
    signal ibuf_blk_data : std_logic_vector(7 downto 0);
    signal ibuf_blk_sof : std_logic;
    signal ibuf_blk_sob : std_logic;
    signal ibuf_blk_comp : std_logic_vector(1 downto 0);
    signal ibuf_blk_ready : std_logic;
    signal ibuf_blk_start : std_logic;
    signal ibuf_blk_avail : std_logic;
    signal ibuf_lines_done_unused : std_logic;
    signal q_tables_busy : std_logic;

    signal dct_in_data : std_logic_vector(11 downto 0);
    signal dct_in_valid : std_logic;
    signal dct_in_sof : std_logic;
    signal dct_out_valid : std_logic;
    signal dct_out_data : std_logic_vector(15 downto 0);
    signal dct_out_sof : std_logic;

    signal quant_out_valid : std_logic;
    signal quant_out_data : std_logic_vector(15 downto 0);
    signal quant_out_sob : std_logic;
    signal zz_out_valid : std_logic;
    signal zz_out_data : std_logic_vector(15 downto 0);
    signal zz_out_sob : std_logic;

    signal huff_out_valid : std_logic;
    signal huff_out_bits : std_logic_vector(31 downto 0);
    signal huff_out_len : std_logic_vector(5 downto 0);
    signal huff_out_eob : std_logic;
    signal huff_bp_ready : std_logic;

    signal bs_out_valid : std_logic;
    signal bs_out_data : std_logic_vector(7 downto 0);
    signal bs_out_last : std_logic;
    signal bs_out_ready : std_logic;
    signal bs_byte_count_unused : std_logic_vector(31 downto 0);

    signal qt_rd_addr : std_logic_vector(5 downto 0);
    signal qt_rd_is_chroma : std_logic;
    signal qt_rd_data : std_logic_vector(7 downto 0);
    signal jfif_headers_done : std_logic;

    type comp_fifo_q_t is array (0 to 3) of std_logic_vector(1 downto 0);
    type comp_fifo_h_t is array (0 to 7) of std_logic_vector(1 downto 0);
    signal comp_fifo_q : comp_fifo_q_t := (others => (others => '0'));
    signal comp_fifo_h : comp_fifo_h_t := (others => (others => '0'));
    signal comp_fifo_q_wr : unsigned(2 downto 0) := (others => '0');
    signal comp_fifo_q_rd : unsigned(2 downto 0) := (others => '0');
    signal comp_fifo_h_wr : unsigned(3 downto 0) := (others => '0');
    signal comp_fifo_h_rd : unsigned(3 downto 0) := (others => '0');
    signal quant_comp_id : std_logic_vector(1 downto 0);
    signal huff_comp_id : std_logic_vector(1 downto 0);

    signal fstate : fstate_t := F_IDLE;
    signal done_seen : std_logic := '0';
    signal frame_active : std_logic := '0';
    signal frame_start_pulse : std_logic := '0';
    signal frame_done_pulse : std_logic := '0';
    signal mcu_count : unsigned(BLK_W-1 downto 0) := (others => '0');  -- blocks completed (EOB)
    signal adm_count : unsigned(BLK_W-1 downto 0) := (others => '0');  -- blocks admitted
    signal mcu_in_segment : unsigned(15 downto 0) := (others => '0');
    signal restart_trigger : std_logic := '0';
    signal huff_restart    : std_logic := '0';
    signal pipeline_depth : unsigned(3 downto 0) := (others => '0');
    signal blk_emerge : std_logic;  -- a block enters the DCT
    signal blk_done   : std_logic;  -- a block leaves the Huffman (EOB accepted)

    -- Per-frame control snapshot
    signal frame_quality   : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(95, 7));
    signal frame_restart   : std_logic_vector(15 downto 0) := (others => '0');
    signal quality_clamped : std_logic_vector(6 downto 0);

    -- FRAME_SIZE: total JPEG bytes (SOI..EOI) of the last completed frame
    signal jpg_byte_cnt    : unsigned(31 downto 0) := (others => '0');
    signal last_frame_size : unsigned(31 downto 0) := (others => '0');
    signal last_frame_size_slv : std_logic_vector(31 downto 0);
    signal m_axis_jpg_tvalid_i : std_logic;
    signal m_axis_jpg_tlast_i  : std_logic;
    signal vid_tready_i        : std_logic;

    signal vid_yuyv_tdata : std_logic_vector(15 downto 0);
    signal vid_yuyv_tvalid : std_logic;
    signal vid_yuyv_tready : std_logic;
    signal vid_yuyv_tlast : std_logic;
    signal vid_yuyv_tuser : std_logic;
    signal s_axis_vid_tvalid_gated : std_logic;
    signal frame_cnt_slv : std_logic_vector(31 downto 0);
    signal quant_out_sof_unused : std_logic;
    signal huff_out_sob_unused : std_logic;

begin

    assert IMG_WIDTH > 0 and IMG_HEIGHT > 0
        report "IMG_WIDTH and IMG_HEIGHT must be positive" severity failure;
    assert (IMG_WIDTH mod 16) = 0
        report "IMG_WIDTH must be a multiple of 16 for 4:2:2 MCUs" severity failure;
    assert (IMG_HEIGHT mod 8) = 0
        report "IMG_HEIGHT must be a multiple of 8" severity failure;
    assert LITE_QUALITY >= 1 and LITE_QUALITY <= 100
        report "LITE_QUALITY must be in the range 1..100" severity failure;
    assert EXIF_RES_UNIT >= 1 and EXIF_RES_UNIT <= 3
        report "EXIF_RES_UNIT must be 1, 2, or 3" severity failure;
    assert HUFF_BANKS = 2 or HUFF_BANKS = 4 or HUFF_BANKS = 8
        report "HUFF_BANKS must be 2, 4, or 8" severity failure;

    rst_int_n <= rst_n and not ctrl_soft_reset;
    dct_in_data <= std_logic_vector(signed(std_logic_vector(resize(unsigned(ibuf_blk_data), 12))) - to_signed(128, 12));
    dct_in_valid <= ibuf_blk_valid;
    dct_in_sof <= ibuf_blk_sob;
    quant_comp_id <= comp_fifo_q(to_integer(comp_fifo_q_rd(1 downto 0)));
    huff_comp_id <= comp_fifo_h(to_integer(comp_fifo_h_rd(2 downto 0)));
    sts_busy <= frame_active;
    sts_frame_done_pulse <= frame_done_pulse;
    blk_emerge <= ibuf_blk_valid and ibuf_blk_sob;
    blk_done <= huff_out_eob and huff_out_valid and huff_bp_ready;

    -- Admit blocks until HUFF_BANKS are in flight. This MUST match the Huffman's
    -- input-ring depth so the ring (which zigzag cannot backpressure) never
    -- overflows. A started block always runs to completion (block-granular
    -- admission via blk_start), so the DCT never sees a partial block.
    ibuf_blk_ready <= '1';
    ibuf_blk_start <= '1' when ctrl_enable = '1' and fstate = F_RUN and
                               jfif_headers_done = '1' and
                               pipeline_depth < to_unsigned(HUFF_BANKS, pipeline_depth'length)
                      else '0';

    -- ENABLE=0 stalls the video stream (tready low) rather than accepting
    -- and dropping pixels.
    s_axis_vid_tvalid_gated <= s_axis_vid_tvalid and ctrl_enable;
    s_axis_vid_tready <= vid_tready_i and ctrl_enable;
    frame_cnt_slv <= std_logic_vector(frame_cnt);

    quality_clamped <= std_logic_vector(to_unsigned(1, 7)) when unsigned(ctrl_quality) = 0 else
                       std_logic_vector(to_unsigned(100, 7)) when unsigned(ctrl_quality) > 100 else
                       ctrl_quality;

    m_axis_jpg_tvalid <= m_axis_jpg_tvalid_i;
    m_axis_jpg_tlast <= m_axis_jpg_tlast_i;
    last_frame_size_slv <= std_logic_vector(last_frame_size);

    p_frame_size : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                jpg_byte_cnt <= (others => '0');
                last_frame_size <= (others => '0');
            elsif m_axis_jpg_tvalid_i = '1' then
                if m_axis_jpg_tlast_i = '1' then
                    last_frame_size <= jpg_byte_cnt + 1;
                    jpg_byte_cnt <= (others => '0');
                else
                    jpg_byte_cnt <= jpg_byte_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    p_comp_fifo_q : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                comp_fifo_q_wr <= (others => '0');
                comp_fifo_q_rd <= (others => '0');
            else
                if ibuf_blk_valid = '1' and ibuf_blk_sob = '1' then
                    comp_fifo_q(to_integer(comp_fifo_q_wr(1 downto 0))) <= ibuf_blk_comp;
                    comp_fifo_q_wr <= comp_fifo_q_wr + 1;
                end if;
                if dct_out_valid = '1' and dct_out_sof = '1' then
                    comp_fifo_q_rd <= comp_fifo_q_rd + 1;
                end if;
            end if;
        end if;
    end process;

    p_comp_fifo_h : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                comp_fifo_h_wr <= (others => '0');
                comp_fifo_h_rd <= (others => '0');
            else
                if ibuf_blk_valid = '1' and ibuf_blk_sob = '1' then
                    comp_fifo_h(to_integer(comp_fifo_h_wr(2 downto 0))) <= ibuf_blk_comp;
                    comp_fifo_h_wr <= comp_fifo_h_wr + 1;
                end if;
                if zz_out_valid = '1' and zz_out_sob = '1' then
                    comp_fifo_h_rd <= comp_fifo_h_rd + 1;
                end if;
            end if;
        end if;
    end process;

    -- One frame at a time through the pipeline:
    --   F_IDLE : wait until a strip is buffered (and ENABLE), then latch the
    --            frame's QUALITY/RESTART so a register write mid-frame cannot
    --            desync the tables from the header already sent
    --   F_QWAIT: wait for the quantizer to rebuild its Q tables, then start
    --            the JFIF headers
    --   F_RUN  : admit exactly TOTAL_BLOCKS blocks (block-granular)
    --   F_DRAIN: wait for the last EOB (frame_done) and for the JFIF writer to
    --            finish EOI and return to idle, then take the next frame
    -- Admitting by count keeps every JPEG well formed even when the next
    -- frame's strips are already buffered (back-to-back input).
    p_frame_control : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                fstate <= F_IDLE;
                done_seen <= '0';
                frame_active <= '0';
                frame_start_pulse <= '0';
                frame_done_pulse <= '0';
                frame_cnt <= (others => '0');
                mcu_count <= (others => '0');
                adm_count <= (others => '0');
                mcu_in_segment <= (others => '0');
                restart_trigger <= '0';
                frame_quality <= std_logic_vector(to_unsigned(95, 7));
                frame_restart <= (others => '0');
            else
                frame_start_pulse <= '0';
                frame_done_pulse <= '0';
                restart_trigger <= '0';

                case fstate is
                    when F_IDLE =>
                        if ctrl_enable = '1' and ibuf_blk_avail = '1' then
                            frame_quality <= quality_clamped;
                            frame_restart <= ctrl_restart_interval;
                            fstate <= F_QWAIT;
                        end if;
                    when F_QWAIT =>
                        -- tables_busy sees frame_quality this cycle (registered above)
                        if q_tables_busy = '0' then
                            frame_start_pulse <= '1';
                            frame_active <= '1';
                            adm_count <= (others => '0');
                            fstate <= F_RUN;
                        end if;
                    when F_RUN =>
                        if blk_emerge = '1' then
                            adm_count <= adm_count + 1;
                            if adm_count = LAST_BLOCK then
                                fstate <= F_DRAIN;
                            end if;
                        end if;
                    when F_DRAIN =>
                        if frame_done_pulse = '1' then
                            done_seen <= '1';
                        end if;
                        -- headers_done drops only when the writer is back in
                        -- idle, i.e. after this frame's EOI
                        if done_seen = '1' and jfif_headers_done = '0' then
                            done_seen <= '0';
                            fstate <= F_IDLE;
                        end if;
                end case;

                -- Count completed blocks via Huffman EOB (qualified by
                -- bp_ready: the Huffman holds out_valid/out_eob while the
                -- packer drains)
                if blk_done = '1' then
                    mcu_count <= mcu_count + 1;

                    -- Every 4 blocks = 1 MCU; skip the restart check on the
                    -- last MCU so RST never collides with the EOI flush
                    if mcu_count(1 downto 0) = "11" then
                        if frame_restart /= x"0000" and mcu_count /= LAST_BLOCK then
                            if mcu_in_segment + 1 >= unsigned(frame_restart) then
                                restart_trigger <= '1';
                                mcu_in_segment <= (others => '0');
                            else
                                mcu_in_segment <= mcu_in_segment + 1;
                            end if;
                        end if;
                    end if;

                    if mcu_count = LAST_BLOCK then
                        mcu_count <= (others => '0');
                        mcu_in_segment <= (others => '0');
                        frame_active <= '0';
                        frame_done_pulse <= '1';
                        frame_cnt <= frame_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    p_pipeline_depth : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                pipeline_depth <= (others => '0');
            else
                -- Count every block that actually enters the DCT (not gated by
                -- the admission signal, which runs a few cycles ahead of the
                -- input buffer's output pipeline), so the count cannot wrap.
                if blk_emerge = '1' and blk_done = '0' then
                    pipeline_depth <= pipeline_depth + 1;
                elsif blk_done = '1' and blk_emerge = '0' then
                    pipeline_depth <= pipeline_depth - 1;
                end if;
            end if;
        end if;
    end process;

    g_rgb_input : if RGB_INPUT /= 0 generate
    begin
        u_rgb2yuv : rgb_to_ycbcr
            port map (
                clk => clk, rst_n => rst_int_n,
                s_axis_tdata => s_axis_vid_tdata(23 downto 0),
                s_axis_tvalid => s_axis_vid_tvalid_gated,
                s_axis_tready => vid_tready_i,
                s_axis_tlast => s_axis_vid_tlast,
                s_axis_tuser => s_axis_vid_tuser,
                m_axis_tdata => vid_yuyv_tdata,
                m_axis_tvalid => vid_yuyv_tvalid,
                m_axis_tready => vid_yuyv_tready,
                m_axis_tlast => vid_yuyv_tlast,
                m_axis_tuser => vid_yuyv_tuser
            );
    end generate;

    g_yuyv_input : if RGB_INPUT = 0 generate
    begin
        vid_tready_i <= vid_yuyv_tready;
        vid_yuyv_tdata <= s_axis_vid_tdata(15 downto 0);
        vid_yuyv_tvalid <= s_axis_vid_tvalid_gated;
        vid_yuyv_tlast <= s_axis_vid_tlast;
        vid_yuyv_tuser <= s_axis_vid_tuser;
    end generate;

    u_regs : axi4_lite_regs
        generic map (LITE_MODE => LITE_MODE)
        port map (
            clk => clk, rst_n => rst_n,
            s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid,
            s_axi_awready => s_axi_awready, s_axi_wdata => s_axi_wdata,
            s_axi_wstrb => s_axi_wstrb, s_axi_wvalid => s_axi_wvalid,
            s_axi_wready => s_axi_wready, s_axi_bresp => s_axi_bresp,
            s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
            s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid,
            s_axi_arready => s_axi_arready, s_axi_rdata => s_axi_rdata,
            s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
            s_axi_rready => s_axi_rready, ctrl_enable => ctrl_enable,
            ctrl_soft_reset => ctrl_soft_reset, ctrl_quality => ctrl_quality,
            ctrl_restart_interval => ctrl_restart_interval, sts_busy => sts_busy,
            sts_frame_done_pulse => sts_frame_done_pulse,
            sts_frame_cnt => frame_cnt_slv,
            sts_frame_size => last_frame_size_slv
        );

    u_input_buffer : input_buffer
        generic map (IMG_WIDTH => IMG_WIDTH)
        port map (
            clk => clk, rst_n => rst_int_n,
            s_axis_tdata => vid_yuyv_tdata, s_axis_tvalid => vid_yuyv_tvalid,
            s_axis_tready => vid_yuyv_tready, s_axis_tlast => vid_yuyv_tlast,
            s_axis_tuser => vid_yuyv_tuser, blk_valid => ibuf_blk_valid,
            blk_data => ibuf_blk_data, blk_sof => ibuf_blk_sof,
            blk_sob => ibuf_blk_sob, blk_comp => ibuf_blk_comp,
            blk_ready => ibuf_blk_ready, blk_start => ibuf_blk_start,
            lines_done => ibuf_lines_done_unused, blk_avail => ibuf_blk_avail
        );

    u_dct : dct_2d
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => dct_in_valid,
            in_data => dct_in_data, in_sof => dct_in_sof,
            out_valid => dct_out_valid, out_data => dct_out_data,
            out_sof => dct_out_sof
        );

    u_quantizer : quantizer
        generic map (LITE_MODE => LITE_MODE, LITE_QUALITY => LITE_QUALITY)
        port map (
            clk => clk, rst_n => rst_int_n, comp_id => quant_comp_id,
            quality => frame_quality, in_valid => dct_out_valid,
            in_data => dct_out_data, in_sof => dct_out_sof,
            in_sob => dct_out_sof, out_valid => quant_out_valid,
            out_data => quant_out_data, out_sof => quant_out_sof_unused,
            out_sob => quant_out_sob, qt_rd_addr => qt_rd_addr,
            qt_rd_is_chroma => qt_rd_is_chroma, qt_rd_data => qt_rd_data,
            tables_busy => q_tables_busy
        );

    u_zigzag : zigzag_reorder
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => quant_out_valid,
            in_data => quant_out_data, in_sob => quant_out_sob,
            out_valid => zz_out_valid, out_data => zz_out_data,
            out_sob => zz_out_sob
        );

    -- DC predictors must reset at every start-of-scan (= each frame) as well as at
    -- RST markers (JPEG spec). Without a per-frame reset the predictor carries the
    -- previous frame's last DC into the next, washing out luma on every frame after
    -- the first. We use frame_done_pulse (not frame_start_pulse) so the reset is
    -- aligned to the Huffman's own last-block EOB - it always lands after this
    -- frame's last block and before the next frame's first block, regardless of how
    -- the pixel source pipelines frames upstream. Frame 0 is covered by reset; frames
    -- 1+ by the preceding frame_done. VHDL-93 forbids an expression in a port-map
    -- actual, so combine via a named signal; the packer RST path (in_restart) stays
    -- restart_trigger only, so no spurious RST marker is emitted.
    huff_restart <= restart_trigger or frame_done_pulse;

    u_huffman : huffman_encoder
        generic map (HUFF_BANKS => HUFF_BANKS)
        port map (
            clk => clk, rst_n => rst_int_n, comp_id => huff_comp_id,
            restart => huff_restart, in_valid => zz_out_valid,
            in_data => zz_out_data, in_sob => zz_out_sob,
            out_valid => huff_out_valid, out_bits => huff_out_bits,
            out_len => huff_out_len, out_sob => huff_out_sob_unused,
            out_eob => huff_out_eob, out_ready => huff_bp_ready
        );

    u_bitpacker : bitstream_packer
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => huff_out_valid,
            in_bits => huff_out_bits, in_len => huff_out_len,
            in_flush => frame_done_pulse, in_restart => restart_trigger,
            bp_ready => huff_bp_ready, out_valid => bs_out_valid,
            out_data => bs_out_data, out_last => bs_out_last,
            out_ready => bs_out_ready, byte_count => bs_byte_count_unused
        );

    u_jfif : jfif_writer
        generic map (
            IMG_WIDTH => IMG_WIDTH, IMG_HEIGHT => IMG_HEIGHT,
            LITE_MODE => LITE_MODE, LITE_QUALITY => LITE_QUALITY,
            EXIF_ENABLE => EXIF_ENABLE, EXIF_X_RES => EXIF_X_RES,
            EXIF_Y_RES => EXIF_Y_RES, EXIF_RES_UNIT => EXIF_RES_UNIT
        )
        port map (
            clk => clk, rst_n => rst_int_n,
            frame_start => frame_start_pulse, frame_done => frame_done_pulse,
            restart_interval => frame_restart,
            qt_rd_addr => qt_rd_addr, qt_rd_is_chroma => qt_rd_is_chroma,
            qt_rd_data => qt_rd_data, scan_valid => bs_out_valid,
            scan_data => bs_out_data, scan_last => bs_out_last,
            scan_ready => bs_out_ready, m_axis_tvalid => m_axis_jpg_tvalid_i,
            m_axis_tdata => m_axis_jpg_tdata, m_axis_tlast => m_axis_jpg_tlast_i,
            headers_done => jfif_headers_done
        );

end architecture rtl;
