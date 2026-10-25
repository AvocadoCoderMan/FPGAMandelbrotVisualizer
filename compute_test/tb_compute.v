module tb_compute(
    input         clk,
    output        write_en,   
    output [7:0]  write_data, 
    output [10:0] calc_x,     
    output [9:0]  calc_y,
    // constants of the design, so the C++ side never has its own copy that could go out of date
    output signed [31:0] CX, CY, STEP0, MIN_STEP,
    output [31:0] ZOOM_SHIFT
);
    mandelbrot dut(.clk_in(clk), .button(1'b0));

    assign write_en   = dut.write_en;
    assign write_data = dut.write_data;
    assign calc_x     = dut.calc_x;
    assign calc_y     = dut.calc_y;
    assign CX = dut.CX;  assign CY = dut.CY;  assign STEP0 = dut.STEP0;
    assign MIN_STEP = dut.MIN_STEP;  assign ZOOM_SHIFT = dut.ZOOM_SHIFT;
endmodule
