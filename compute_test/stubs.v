// "Do nothing" stand-ins for the Gowin IP, just so mandelbrot.v compiles.
// The write FIFO never reports "full", so the compute engine never has to wait.
module Gowin_rPLL(input clkin, output clkout, output lock);
    assign clkout = clkin;  assign lock = 1'b1;
endmodule

module CLKDIV #(parameter DIV_MODE = "5")(input HCLKIN, input RESETN, input CALIB, output CLKOUT);
    assign CLKOUT = HCLKIN;
endmodule

module fifo_top(input [7:0] Data, input WrClk, RdClk, WrEn, RdEn, output Almost_Full,
                output [31:0] Q, output Empty, Full, input WrReset, RdReset);
    assign Almost_Full = 0; assign Q = 0; assign Empty = 0; assign Full = 0;
endmodule

module fifo_out(input [31:0] Data, input WrClk, RdClk, WrEn, RdEn, output Almost_Empty,
                output [7:0] Q, output Empty, Full, input WrReset, RdReset);
    assign Almost_Empty = 0; assign Q = 0; assign Empty = 0; assign Full = 0;
endmodule

module SDRAM_controller_top_SIP(
    output O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
    output [3:0] O_sdram_dqm, output [10:0] O_sdram_addr, output [1:0] O_sdram_ba, inout [31:0] IO_sdram_dq,
    input I_sdrc_rst_n, I_sdrc_clk, I_sdram_clk, I_sdrc_selfrefresh, I_sdrc_power_down,
    input I_sdrc_wr_n, I_sdrc_rd_n, input [20:0] I_sdrc_addr, input [7:0] I_sdrc_data_len,
    input [3:0] I_sdrc_dqm, input [31:0] I_sdrc_data, output [31:0] O_sdrc_data,
    output O_sdrc_init_done, O_sdrc_busy_n, O_sdrc_rd_valid, O_sdrc_wrd_ack);
    assign O_sdrc_init_done = 0; assign O_sdrc_busy_n = 1; assign O_sdrc_rd_valid = 0;
    assign O_sdrc_wrd_ack = 0;   assign O_sdrc_data = 0;
endmodule

module DVI_TX_Top(input I_rst_n, I_rgb_clk, I_serial_clk, I_rgb_vs, I_rgb_hs, I_rgb_de,
                  input [7:0] I_rgb_r, I_rgb_g, I_rgb_b,
                  output O_tmds_clk_p, O_tmds_clk_n, output [2:0] O_tmds_data_p, O_tmds_data_n);
endmodule
