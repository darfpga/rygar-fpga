-- Copyright (c) 2019 Josh Bassett
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types.all;

entity rygar is
  generic (
    SPRITE_LAYER_ENABLE : boolean := true;
    CHAR_LAYER_ENABLE   : boolean := true;
    FG_LAYER_ENABLE     : boolean := true;
    BG_LAYER_ENABLE     : boolean := true
  );
  port (
    -- clock signals
    clk   : in std_logic;
    cen_6 : in std_logic;
    cen_4 : in std_logic;

    -- reset
    reset : in std_logic;

    -- sync signals
    hsync : out std_logic;
    vsync : out std_logic;

    -- pixel data
    pixel : out rgb_t
  );
end rygar;

architecture arch of rygar is
  -- CPU signals
  signal cpu_cen     : std_logic;
  signal cpu_addr    : std_logic_vector(15 downto 0);
  signal cpu_din     : byte_t;
  signal cpu_dout    : byte_t;
  signal cpu_ioreq_n : std_logic;
  signal cpu_mreq_n  : std_logic;
  signal cpu_rd_n    : std_logic;
  signal cpu_wr_n    : std_logic;
  signal cpu_rfsh_n  : std_logic;
  signal cpu_int_n   : std_logic := '1';
  signal cpu_m1_n    : std_logic;
  signal cpu_halt_n  : std_logic;

  -- chip select signals
  signal prog_rom_1_cs  : std_logic;
  signal prog_rom_2_cs  : std_logic;
  signal prog_rom_3_cs  : std_logic;
  signal work_ram_cs    : std_logic;
  signal char_ram_cs    : std_logic;
  signal fg_ram_cs      : std_logic;
  signal bg_ram_cs      : std_logic;
  signal sprite_ram_cs  : std_logic;
  signal palette_ram_cs : std_logic;
  signal bank_cs        : std_logic;
  signal scroll_cs      : std_logic;

  -- chip data output signals
  signal prog_rom_1_dout  : byte_t;
  signal prog_rom_2_dout  : byte_t;
  signal prog_rom_3_dout  : byte_t;
  signal work_ram_dout    : byte_t;
  signal char_ram_dout    : byte_t;
  signal fg_ram_dout      : byte_t;
  signal bg_ram_dout      : byte_t;
  signal sprite_ram_dout  : byte_t;
  signal palette_ram_dout : byte_t;

  -- currently selected bank for program ROM 3
  signal current_bank : unsigned(3 downto 0);

  -- scroll position registers
  signal fg_scroll_pos : pos_t;
  signal bg_scroll_pos : pos_t;

  -- sprite priority data
  signal sprite_priority : priority_t;

  -- graphics layer data
  signal sprite_data : byte_t := (others => '0');
  signal char_data   : byte_t := (others => '0');
  signal fg_data     : byte_t := (others => '0');
  signal bg_data     : byte_t := (others => '0');

  -- video signals
  signal video : video_t;

  -- control signals
  signal vblank_falling : std_logic;
begin
  -- video timing generator
  sync_gen : entity work.sync_gen
  port map (
    clk   => clk,
    cen   => cen_6,
    video => video
  );

  -- detect falling edges of the VBLANK signal
  vblank_edge_detector : entity work.edge_detector
  generic map (FALLING => true)
  port map (
    clk  => clk,
    data => video.vblank,
    edge => vblank_falling
  );

  -- program ROM 1
  prog_rom_1 : entity work.single_port_rom
  generic map (ADDR_WIDTH => PROG_ROM_1_ADDR_WIDTH, INIT_FILE => "rom/cpu_5p.mif")
  port map (
    clk  => clk,
    cs   => prog_rom_1_cs,
    addr => cpu_addr(PROG_ROM_1_ADDR_WIDTH-1 downto 0),
    dout => prog_rom_1_dout
  );

  -- program ROM 2
  prog_rom_2 : entity work.single_port_rom
  generic map (ADDR_WIDTH => PROG_ROM_2_ADDR_WIDTH, INIT_FILE => "rom/cpu_5m.mif")
  port map (
    clk  => clk,
    cs   => prog_rom_2_cs,
    addr => cpu_addr(PROG_ROM_2_ADDR_WIDTH-1 downto 0),
    dout => prog_rom_2_dout
  );

  -- program ROM 3
  prog_rom_3 : entity work.single_port_rom
  generic map (ADDR_WIDTH => PROG_ROM_3_ADDR_WIDTH, INIT_FILE => "rom/cpu_5j.mif")
  port map (
    clk  => clk,
    cs   => prog_rom_3_cs,
    addr => std_logic_vector(current_bank) & cpu_addr(10 downto 0),
    dout => prog_rom_3_dout
  );

  -- work RAM
  work_ram : entity work.single_port_ram
  generic map (ADDR_WIDTH => WORK_RAM_ADDR_WIDTH)
  port map (
    clk  => clk,
    cs   => work_ram_cs,
    addr => cpu_addr(WORK_RAM_ADDR_WIDTH-1 downto 0),
    din  => cpu_dout,
    dout => work_ram_dout,
    we   => not cpu_wr_n
  );

  -- main CPU
  cpu : entity work.T80s
  port map (
    RESET_n => not reset,
    CLK     => clk,
    CEN     => cen_4,
    WAIT_n  => '1',
    INT_n   => cpu_int_n,
    M1_n    => cpu_m1_n,
    MREQ_n  => cpu_mreq_n,
    IORQ_n  => cpu_ioreq_n,
    RD_n    => cpu_rd_n,
    WR_n    => cpu_wr_n,
    RFSH_n  => cpu_rfsh_n,
    HALT_n  => cpu_halt_n,
    BUSAK_n => open,
    A       => cpu_addr,
    DI      => cpu_din,
    DO      => cpu_dout
  );

  -- sprite layer
  sprite_layer_gen : if SPRITE_LAYER_ENABLE generate
    sprite_layer : entity work.sprite
    port map (
      clk      => clk,
      cen      => cen_6,
      ram_cs   => sprite_ram_cs,
      ram_addr => cpu_addr(SPRITE_RAM_ADDR_WIDTH-1 downto 0),
      ram_din  => cpu_dout,
      ram_dout => sprite_ram_dout,
      ram_we   => not cpu_wr_n,
      video    => video,
      priority => sprite_priority,
      data     => sprite_data
    );
  else generate
    -- dummy sprite RAM
    sprite_ram : entity work.single_port_ram
    generic map (ADDR_WIDTH => SPRITE_RAM_ADDR_WIDTH)
    port map (
      clk  => clk,
      cs   => sprite_ram_cs,
      addr => cpu_addr(SPRITE_RAM_ADDR_WIDTH-1 downto 0),
      din  => cpu_dout,
      dout => sprite_ram_dout,
      we   => not cpu_wr_n
    );
  end generate;

  -- character layer
  char_layer_gen : if CHAR_LAYER_ENABLE generate
    char_layer : entity work.char
    port map (
      clk      => clk,
      cen      => cen_6,
      ram_cs   => char_ram_cs,
      ram_addr => cpu_addr(CHAR_RAM_ADDR_WIDTH-1 downto 0),
      ram_din  => cpu_dout,
      ram_dout => char_ram_dout,
      ram_we   => not cpu_wr_n,
      video    => video,
      data     => char_data
    );
  else generate
    -- dummy character RAM
    char_ram : entity work.single_port_ram
    generic map (ADDR_WIDTH => CHAR_RAM_ADDR_WIDTH)
    port map (
      clk  => clk,
      cs   => char_ram_cs,
      addr => cpu_addr(CHAR_RAM_ADDR_WIDTH-1 downto 0),
      din  => cpu_dout,
      dout => char_ram_dout,
      we   => not cpu_wr_n
    );
  end generate;

  -- foreground layer
  fg_layer_gen : if FG_LAYER_ENABLE generate
    fg_layer : entity work.scroll
    generic map (
      RAM_ADDR_WIDTH => FG_RAM_ADDR_WIDTH,
      ROM_ADDR_WIDTH => FG_ROM_ADDR_WIDTH,
      ROM_INIT_FILE  => "rom/fg.mif"
    )
    port map (
      clk        => clk,
      cen        => cen_6,
      ram_cs     => fg_ram_cs,
      ram_addr   => cpu_addr(FG_RAM_ADDR_WIDTH-1 downto 0),
      ram_din    => cpu_dout,
      ram_dout   => fg_ram_dout,
      ram_we     => not cpu_wr_n,
      video      => video,
      scroll_pos => fg_scroll_pos,
      data       => fg_data
    );
  else generate
    -- dummy foreground RAM
    fg_ram : entity work.single_port_ram
    generic map (ADDR_WIDTH => FG_RAM_ADDR_WIDTH)
    port map (
      clk  => clk,
      cs   => fg_ram_cs,
      addr => cpu_addr(FG_RAM_ADDR_WIDTH-1 downto 0),
      din  => cpu_dout,
      dout => fg_ram_dout,
      we   => not cpu_wr_n
    );
  end generate;

  -- background layer
  bg_layer_gen : if BG_LAYER_ENABLE generate
    bg_layer : entity work.scroll
    generic map (
      RAM_ADDR_WIDTH => BG_RAM_ADDR_WIDTH,
      ROM_ADDR_WIDTH => BG_ROM_ADDR_WIDTH,
      ROM_INIT_FILE  => "rom/bg.mif"
    )
    port map (
      clk        => clk,
      cen        => cen_6,
      ram_cs     => bg_ram_cs,
      ram_addr   => cpu_addr(BG_RAM_ADDR_WIDTH-1 downto 0),
      ram_din    => cpu_dout,
      ram_dout   => bg_ram_dout,
      ram_we     => not cpu_wr_n,
      video      => video,
      scroll_pos => bg_scroll_pos,
      data       => bg_data
    );
  else generate
    -- dummy background RAM
    bg_ram : entity work.single_port_ram
    generic map (ADDR_WIDTH => BG_RAM_ADDR_WIDTH)
    port map (
      clk  => clk,
      cs   => bg_ram_cs,
      addr => cpu_addr(BG_RAM_ADDR_WIDTH-1 downto 0),
      din  => cpu_dout,
      dout => bg_ram_dout,
      we   => not cpu_wr_n
    );
  end generate;

  -- colour palette
  palette : entity work.palette
  port map (
    clk             => clk,
    cen             => cen_6,
    ram_cs          => palette_ram_cs,
    ram_addr        => cpu_addr(PALETTE_RAM_ADDR_WIDTH-1 downto 0),
    ram_din         => cpu_dout,
    ram_dout        => palette_ram_dout,
    ram_we          => not cpu_wr_n,
    video           => video,
    sprite_priority => sprite_priority,
    sprite_data     => sprite_data,
    char_data       => char_data,
    fg_data         => fg_data,
    bg_data         => bg_data,
    pixel           => pixel
  );

  -- Trigger an interrupt on the falling edge of the VBLANK signal.
  --
  -- Once the interrupt request has been accepted by the CPU, it is
  -- acknowledged by activating the IORQ signal during the M1 cycle. This
  -- disables the interrupt signal, and the cycle starts over.
  irq : process (clk)
  begin
    if rising_edge(clk) then
      if cpu_m1_n = '0' and cpu_ioreq_n = '0' then
        cpu_int_n <= '1';
      elsif vblank_falling = '1' then
        cpu_int_n <= '0';
      end if;
    end if;
  end process;

  -- set current bank register
  set_current_bank : process (clk)
  begin
    if rising_edge(clk) then
      if bank_cs = '1' and cpu_wr_n = '0' then
        -- flip-flop 6J uses data lines 3 to 6
        current_bank <= unsigned(cpu_dout(6 downto 3));
      end if;
    end if;
  end process;

  -- set foreground and background scroll position registers
  set_scroll_pos : process (clk)
  begin
    if rising_edge(clk) then
      if scroll_cs = '1' and cpu_wr_n = '0' then
        case cpu_addr(2 downto 0) is
          when "000" => fg_scroll_pos.x(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "001" => fg_scroll_pos.x(8 downto 8) <= unsigned(cpu_dout(0 downto 0));
          when "010" => fg_scroll_pos.y(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "011" => bg_scroll_pos.x(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "100" => bg_scroll_pos.x(8 downto 8) <= unsigned(cpu_dout(0 downto 0));
          when "110" => bg_scroll_pos.y(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when others => null;
        end case;
      end if;
    end if;
  end process;

  -- $0000-$7fff PROGRAM ROM 1
  -- $8000-$bfff PROGRAM ROM 2
  -- $c000-$cfff WORK RAM
  -- $d000-$d7ff CHARACTER RAM
  -- $d800-$dbff FOREGROUND RAM
  -- $dc00-$dfff BACKGROUND RAM
  -- $e000-$e7ff SPRITE RAM
  -- $e800-$efff PALETTE RAM
  -- $f000-$f7ff PROGRAM ROM 3 (BANK SWITCHED)
  -- $f800-$ffff
  prog_rom_1_cs  <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"0000" and unsigned(cpu_addr) <= x"7fff" else '0';
  prog_rom_2_cs  <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"8000" and unsigned(cpu_addr) <= x"bfff" else '0';
  work_ram_cs    <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"c000" and unsigned(cpu_addr) <= x"cfff" else '0';
  char_ram_cs    <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"d000" and unsigned(cpu_addr) <= x"d7ff" else '0';
  fg_ram_cs      <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"d800" and unsigned(cpu_addr) <= x"dbff" else '0';
  bg_ram_cs      <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"dc00" and unsigned(cpu_addr) <= x"dfff" else '0';
  sprite_ram_cs  <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"e000" and unsigned(cpu_addr) <= x"e7ff" else '0';
  palette_ram_cs <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"e800" and unsigned(cpu_addr) <= x"efff" else '0';
  prog_rom_3_cs  <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"f000" and unsigned(cpu_addr) <= x"f7ff" else '0';
  scroll_cs      <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) >= x"f800" and unsigned(cpu_addr) <= x"f805" else '0';
  bank_cs        <= '1' when cpu_mreq_n = '0' and cpu_rfsh_n = '1' and unsigned(cpu_addr) = x"f808" else '0';

  -- CPU data input bus
  cpu_din <= prog_rom_1_dout or
             prog_rom_2_dout or
             prog_rom_3_dout or
             work_ram_dout or
             char_ram_dout or
             fg_ram_dout or
             bg_ram_dout or
             sprite_ram_dout or
             palette_ram_dout;

  -- set sync signals
  hsync <= video.hsync;
  vsync <= video.vsync;
end architecture arch;