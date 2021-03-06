----------------------------------------------------------------------------
--  reg_file.vhd
--	AXI Lite Register File
--	Version 1.1
--
--  Copyright (C) 2013 H.Poetzl
--
--	This program is free software: you can redistribute it and/or
--	modify it under the terms of the GNU General Public License
--	as published by the Free Software Foundation, either version
--	2 of the License, or (at your option) any later version.
--
----------------------------------------------------------------------------


library IEEE;
use IEEE.std_logic_1164.all;

package reg_array_pkg is
    type reg_array is array (natural range <>) of
	std_logic_vector(31 downto 0);
end reg_array_pkg;


library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.ALL;

library unisim;
use unisim.VCOMPONENTS.all;

use work.axi3ml_pkg.all;	-- AXI3 Lite Master
use work.reg_array_pkg.ALL;


entity reg_file is
    generic (
	NAME : string := "RegisterFile";
	REG_MASK : unsigned (31 downto 0) := x"0000000F";
	OREG_SIZE : natural := 8;
	IREG_SIZE : natural := 8
    );
    port (
	s_axi_aclk : in std_logic;
	s_axi_areset_n : in std_logic;
	--
	s_axi_ro : out axi3ml_read_in_r;
	s_axi_ri : in axi3ml_read_out_r;
	s_axi_wo : out axi3ml_write_in_r;
	s_axi_wi : in axi3ml_write_out_r;
	--
	oreg : out reg_array(0 to OREG_SIZE - 1);
	ireg : in reg_array(0 to IREG_SIZE - 1)
    );
end entity reg_file;


architecture RTL of reg_file is

    procedure update(
	variable oval : inout std_logic_vector(31 downto 0);
	variable nval : in std_logic_vector(31 downto 0);
	variable strb : in std_logic_vector(3 downto 0)) is

    begin
	for I in strb'range loop
	    if strb(I) = '1' then
		oval(8*I + 7 downto 8*I) :=
		    nval(8*I + 7 downto 8*I);
	    end if;
	end loop;
    end procedure;

begin

    reg_rwseq_proc : process(
	s_axi_aclk, s_axi_areset_n,
	s_axi_ri, s_axi_wi, ireg )

	variable index : integer := 0;

	variable addr_v : std_logic_vector(31 downto 0)
	    := (others => '0');

	variable arready_v : std_logic := '0';
	variable rvalid_v : std_logic := '0';

	variable awready_v : std_logic := '0';
	variable wready_v : std_logic := '0';
	variable bvalid_v : std_logic := '0';

	variable rdata_v : std_logic_vector(31 downto 0);
	variable rresp_v : std_logic_vector(1 downto 0) := "00";

	variable wdata_v : std_logic_vector(31 downto 0);
	variable wstrb_v : std_logic_vector(3 downto 0);
	variable bresp_v : std_logic_vector(1 downto 0) := "00";

	type rw_state is (
	    idle,
	    r_addr, r_data, r_done,
	    w_addr, w_data, w_resp, w_done );

	variable state : rw_state := idle;

	variable oreg_v : reg_array(0 to OREG_SIZE - 1)
	    := (others => (others => '0'));

    begin
	if rising_edge(s_axi_aclk) then
	    if s_axi_areset_n = '0' then
		addr_v := (others => '0');

		arready_v := '0';
		rvalid_v := '0';

		awready_v := '0';
		wready_v := '0';
		bvalid_v := '0';

		rdata_v := (others => '0');
		wdata_v := (others => '0');
		wstrb_v := (others => '0');

		state := idle;

	    else
		case state is
		    when idle =>
			if s_axi_ri.arvalid = '1' then	-- address _is_ valid
			    state := r_addr;

			elsif s_axi_wi.awvalid = '1' then -- address _is_ valid
			    state := w_addr;

			end if;

		--  ARVALID ---> RVALID		    Master
		--     \	 /`   \
		--	\,	/      \,
		--	 ARREADY     RREADY	    Slave

		    when r_addr =>
			addr_v := s_axi_ri.araddr;
			arready_v := '1';		-- ready for transfer

			state := r_data;

		    when r_data =>
			arready_v := '0';		-- done with addr

			if index < OREG_SIZE then
			    rdata_v := oreg_v(index);
			    rresp_v := "00";		-- okay
			elsif index < OREG_SIZE + IREG_SIZE then
			    rdata_v := ireg(index - OREG_SIZE);
			    rresp_v := "00";		-- okay
			else
			    rdata_v := x"DEADBEEF";
			    rresp_v := "11";		-- decode error
			end if;

			if s_axi_ri.rready = '1' then	-- master ready
			    rvalid_v := '1';		-- data is valid

			    state := r_done;
			end if;

		    when r_done =>
			rvalid_v := '0';

			state := idle;

		--  AWVALID ---> WVALID	 _	       BREADY	    Master
		--     \    --__ /`   \	  --__		/`
		--	\,	/--__  \,     --_      /
		--	 AWREADY     -> WREADY ---> BVALID	    Slave

		    when w_addr =>
			addr_v := s_axi_wi.awaddr;
			awready_v := '1';		-- ready for transfer

			state := w_data;

		    when w_data =>
			awready_v := '0';		-- done with addr
			wready_v := '1';		-- ready for data

			if s_axi_wi.wvalid = '1' then	-- data transfer
			    wdata_v := s_axi_wi.wdata;
			    wstrb_v := s_axi_wi.wstrb;

			    if index < OREG_SIZE then
				update(oreg_v(index),
				    wdata_v, wstrb_v);
				bresp_v := "00";	-- transfer OK
			    elsif index < OREG_SIZE + IREG_SIZE then
				bresp_v := "10";	-- slave error
			    else
				bresp_v := "11";	-- decode error
			    end if;

			    state := w_resp;
			end if;

		    when w_resp =>
			wready_v := '0';		-- done with write

			if s_axi_wi.bready = '1' then	-- master ready
			    bvalid_v := '1';		-- response valid

			    state := w_done;
			end if;

		    when w_done =>
			bvalid_v := '0';

			state := idle;

		end case;
	    end if;
	end if;

	index := to_integer(unsigned(addr_v) and REG_MASK) / 4;

	s_axi_ro.arready <= arready_v;
	s_axi_ro.rvalid <= rvalid_v;

	s_axi_wo.awready <= awready_v;
	s_axi_wo.wready <= wready_v;
	s_axi_wo.bvalid <= bvalid_v;

	s_axi_ro.rdata <= rdata_v;
	s_axi_ro.rresp <= rresp_v;

	s_axi_wo.bresp <= bresp_v;

	oreg <= oreg_v;

    end process;

end RTL;
