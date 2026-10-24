create_clock -name clk_in     -period 37.037 [get_ports {clk_in}]
create_clock -name clk_fast   -period 2.694  [get_pins {pll_inst/rpll_inst/CLKOUT}]
create_clock -name clk_medium -period 13.468 [get_pins {u_clkdiv/CLKOUT}]