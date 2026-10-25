// started with Gowin_SDPBRAM and a 4*4 resolution but switched to complete resolution with sdram builtin

module mandelbrot (
    input wire clk_in, // 27 mhz
    input wire button,
    
    // Physical HDMI output pins
    output wire tmds_clk_p,
    output wire tmds_clk_n,
    output wire [2:0] tmds_data_p,
    output wire [2:0] tmds_data_n,
    output reg led = 1,   // Tang Nano 20K LEDs are ACTIVE-LOW: 0 = lit

    // SDRAM Pins (Internal SIP connections for GW2AR-18)
    output wire O_sdram_clk,
    output wire O_sdram_cke,
    output wire O_sdram_cs_n,
    output wire O_sdram_cas_n,
    output wire O_sdram_ras_n,
    output wire O_sdram_wen_n,
    output wire [3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    inout wire [31:0] IO_sdram_dq
);
    
    wire clk_fast; // 371,25 mhz
    wire clk_medium; // 74.25 mhz
    wire pll_lock;  

    Gowin_rPLL pll_inst (
        .clkin(clk_in), 
        .clkout(clk_fast), 
        .lock(pll_lock)
    );
    CLKDIV #(
        .DIV_MODE("5")
    ) u_clkdiv (
        .HCLKIN(clk_fast),
        .RESETN(pll_lock),
        .CALIB(1'b0),
        .CLKOUT(clk_medium)
    );

    // 720p @ 60Hz Timing Constants 
    localparam H_VISIBLE    = 1280;
    localparam H_SYNC_START = 1280 + 110;
    localparam H_SYNC_END   = 1390 + 40;
    localparam H_TOTAL      = 1650;

    localparam V_VISIBLE    = 720;
    localparam V_SYNC_START = 720 + 5;
    localparam V_SYNC_END   = 725 + 5;
    localparam V_TOTAL      = 750;

    wire Hsync;
    wire Vsync;
    wire DE;

    // beam location
    reg [10:0] xBeam = 0;
    reg [9:0] yBeam = 0;

    // signals sent to hdmi controller
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;

    // Generate Sync and Data Enable Logic
    assign DE    = (xBeam < H_VISIBLE) && (yBeam < V_VISIBLE);
    assign Hsync = (xBeam >= H_SYNC_START) && (xBeam < H_SYNC_END);
    assign Vsync = (yBeam >= V_SYNC_START) && (yBeam < V_SYNC_END);

// -------------------------------Mandelbrot setup-------------------------------------------------------------------
    
    reg [10:0] calc_x = 0; 
    reg [9:0] calc_y = 0; 

    // ---- number format: Q4.F fixed point, W = F + 4 bits (value = integer / 2^F) ----
    localparam F = 28;
    localparam W = F + 4;

    // centre of the zoom (Seahorse Valley), already multiplied by 2^F. to get value:
    //   python3 -c "F=28; print(round(-0.743643887037151*2**F), round(0.131825904205330*2**F))"
    localparam signed [W-1:0] CX = -199620386;     // -0.743643887037151
    localparam signed [W-1:0] CY =   35386747;     //  0.131825904205330

    // zoom: distance between two pixels in Q.F units 
    localparam signed [W-1:0] STEP0    = 737280;   // start view = your "45" at F=14 (width ~3.5)
    localparam signed [W-1:0] MIN_STEP = 200;            // stop at about 4000x, then start over
    localparam ZOOM_SHIFT = 3;                           // per finished frame: step -= step >> 3 (12.5 %) bits shifted

    reg  signed [W-1:0] step = STEP0;
    wire at_min = (step <= MIN_STEP);
    wire signed [W-1:0] step_next = at_min ? STEP0 : (step - (step >>> ZOOM_SHIFT)); //  7/8

    // top-left corner of the view; registered, follows `step` one clock later
    reg signed [W-1:0] x0r = CX - 640 * STEP0;
    reg signed [W-1:0] y0r = CY + 360 * STEP0;
    always @(posedge clk_medium) begin
        x0r <= CX - 640 * step;
        y0r <= CY + 360 * step;
    end

    // running pixel coordinates: adders only, no multiplier (c = corner + pixel*step)
    reg signed [W-1:0] cx_acc = CX - 640 * STEP0;
    reg signed [W-1:0] cy_acc = CY + 360 * STEP0;

    // c and z (W bits). syn_preserve on zx/zy keeps them as plain registers (see wedge bug)
    reg signed [W-1:0] cx, cy;
    reg signed [W-1:0] zx = 0 /* synthesis syn_preserve = 1 */;
    reg signed [W-1:0] zy = 0 /* synthesis syn_preserve = 1 */;

    // pipeline stage 1: products (2W bits)
    reg signed [2*W-1:0] p_xx, p_yy, p_xy;
    // stage 2 inputs: narrow results (z update) and wide results (escape test, no wrap)
    wire signed [W-1:0]     pxx_n = p_xx[F+W-1:F];
    wire signed [W-1:0]     pyy_n = p_yy[F+W-1:F];
    wire signed [W-1:0]     pxy_n = p_xy[F+W-1:F];
    wire signed [2*W-F-1:0] pxx_w = p_xx[2*W-1:F];
    wire signed [2*W-F-1:0] pyy_w = p_yy[2*W-1:F];
    // stage 2 results
    reg signed [W-1:0]      nzx, nzy;
    reg signed [2*W-F:0]    mag;
    localparam signed [2*W-F:0] ESCAPE = 4 << F;      // |z|^2 > 4.0

    reg [9:0] iter = 0;
    reg [9:0] max_iter = 250;
    

    // State Machine States
    reg [2:0] state = 0;
    localparam S_INIT  = 0;   // load c, clear z
    localparam S_PROD  = 1;   // products (registered)
    localparam S_ADD   = 2;   // new z and |z|^2 (registered)
    localparam S_CHECK = 3;   // escape / max-iter test, take new z
    localparam S_WRITE = 4;   // push the pixel into the write FIFO, advance coordinates
    localparam S_SET1  = 5;   // frame finished: let x0r/y0r follow the new step
    localparam S_SET2  = 6;   // load corner of the next frame

    // ============================================================================
    // 1. SDRAM CONTROLLER SIGNALS (Embedded Version)
    // ============================================================================
    localparam MAX_ADRESS = 21'd230400;

    reg        I_sdrc_wr_n = 1'b1; // Active-Low
    reg        I_sdrc_rd_n = 1'b1; // Active-Low
    reg [20:0] I_sdrc_addr = 21'b0;
    wire [7:0] I_sdrc_data_len = 8'd63;

    wire       I_sdrc_power_down  = 1'b0;
    wire       I_sdrc_selfrefresh = 1'b0;
    wire [3:0] I_sdrc_dqm         = 4'b0000;

    // ============================================================================
    // 2. FIFO & ARBITER WIRES
    // ============================================================================
    wire [31:0] fifo_in_to_sdram; 
    wire [31:0] sdram_to_fifo_out; 
    wire [7:0]  pixel_from_fifo;   
    
    wire fifo_in_full;
    wire fifo_in_almost_full; // unused
    wire fifo_out_almost_empty;
    wire fifo_out_empty;
    wire fifo_in_empty; // unused
    wire fifo_out_full; // unused
    
    wire sdram_init_done;
    wire O_sdrc_busy_n;
    wire O_sdrc_rd_valid;
    wire O_sdrc_wrd_ack;

    localparam TEST_MODE = 0; // TESTPURPOSES overwrites write_data 
    wire [7:0] write_data = TEST_MODE ? (calc_x==0? 8'd100 : 8'd0)  : ((iter == max_iter) ? 8'd0 : {iter[5:0], 2'b00}); // bands: 4 brightness steps per iteration, repeats every 64
    wire       write_en   = (state == S_WRITE) && !fifo_in_full; // wait to dump fifo if fifo in full one cycle

//---------------------------------Mandelbrot State Machine------------------------------------------------------
    always @(posedge clk_medium) begin
        case (state)
            S_INIT: begin
                cx <= cx_acc;
                cy <= cy_acc;
                zx <= 0;
                zy <= 0;
                iter <= 0;
                state <= S_PROD;
            end

            S_PROD: begin
                p_xx <= zx * zx;
                p_yy <= zy * zy;
                p_xy <= zx * zy;
                state <= S_ADD;
            end

            S_ADD: begin
                nzx <= pxx_n - pyy_n + cx;
                nzy <= (pxy_n <<< 1) + cy;
                mag <= pxx_w + pyy_w;
                state <= S_CHECK;
            end

            S_CHECK: begin
                if (mag > ESCAPE || iter == max_iter) begin
                    state <= S_WRITE;
                end else begin
                    zx <= nzx;
                    zy <= nzy;
                    iter <= iter + 1'b1;
                    state <= S_PROD;
                end
            end

            S_WRITE: begin
                if (!fifo_in_full) begin
                    if (calc_x == 1279) begin
                        calc_x <= 0;
                        if (calc_y == 719) begin
                            calc_y <= 0;
                            step   <= step_next;              // zoom one notch for the whole next frame
                            max_iter <= at_min ? 250 : ((max_iter < 1000) ? max_iter + 12 : max_iter);
                            state  <= S_SET1;
                        end else begin
                            calc_y <= calc_y + 1'b1;
                            cy_acc <= cy_acc - step;
                            cx_acc <= x0r;                    // back to the left edge
                            state  <= S_INIT;
                        end
                    end else begin
                        calc_x <= calc_x + 1'b1;
                        cx_acc <= cx_acc + step;
                        state  <= S_INIT;
                    end
                end
            end

            S_SET1: state <= S_SET2;

            S_SET2: begin
                cx_acc <= x0r;
                cy_acc <= y0r;
                state  <= S_INIT;
            end

            default: state <= S_INIT;
        endcase
    end

//---------------------------- Arbiter & Write Counter -------------------------------------------------------------
    localparam IDLE = 0, WAIT_ACK = 1;

    reg [2:0]  arbiter_state = 0;
    reg        is_reading = 1'b0;
    reg [6:0]  write_counter = 0;
    reg [20:0] sdram_write_addr = 0;
    reg [20:0] sdram_read_addr = 0;
    reg        fifo_out_rst = 0;
    wire custom_write_req = (I_sdrc_wr_n == 1'b0) || (write_counter > 0);

    // no new commands while the read FIFO is flushed (lines 736..741, i.e. vertical blanking)
    wire no_new_cmd = (yBeam >= 736) && (yBeam <= 741);

    always @(posedge clk_medium) begin
        I_sdrc_wr_n <= 1'b1;
        I_sdrc_rd_n <= 1'b1;

        if (write_counter > 0)
            write_counter <= write_counter - 1'b1;

        case (arbiter_state)
            IDLE: begin
                if (sdram_init_done && O_sdrc_busy_n) begin
                    if ((fifo_out_almost_empty || fifo_out_empty) && !no_new_cmd) begin // priority on fifo_out to hdmi
                        I_sdrc_addr   <= sdram_read_addr;
                        I_sdrc_rd_n   <= 1'b0;
                        is_reading    <= 1'b1;
                        arbiter_state <= WAIT_ACK;
                    end
                    else if (fifo_in_full) begin
                        I_sdrc_addr   <= sdram_write_addr;
                        I_sdrc_wr_n   <= 1'b0;
                        is_reading    <= 1'b0;
                        write_counter <= 7'd64;   // exactly 64 FIFO pops, starting in the wr_n cycle
                        arbiter_state <= WAIT_ACK;
                    end
                end
            end

            WAIT_ACK: begin
                if (O_sdrc_wrd_ack) begin
                    if (is_reading) begin
                        if (sdram_read_addr + 64 >= MAX_ADRESS) sdram_read_addr <= 0;
                        else sdram_read_addr <= sdram_read_addr + 21'd64;
                    end else begin
                        if (sdram_write_addr + 64 >= MAX_ADRESS) sdram_write_addr <= 0;
                        else sdram_write_addr <= sdram_write_addr + 21'd64;
                    end
                    arbiter_state <= IDLE;
                end
            end
        endcase

        // once per frame, in the middle of vertical blanking: flush read FIFO, restart read pointer
        // no read fifo can happen here because of no_new_cmd)
        // Reason is fifo_out has to have pixels for 0 0 ready when DE is turned on at xybeam 00 (no garbage data and skewed picture)
        fifo_out_rst <= (yBeam == 740) && (xBeam < 8);
        if (yBeam == 740 && xBeam == 0)
            sdram_read_addr <= 0;
    end

    // ---- Underrun indicator on the LED (lit = display ran out of pixels at least once) ----
    reg armed = 0;
    reg underrun = 0;
    always @(posedge clk_medium) begin
        if (fifo_out_rst) armed <= 1'b1;                    // ignore the first frame (SDRAM still starting)
        if (armed && DE && fifo_out_empty) underrun <= 1'b1;
        led <= ~underrun;                                   // active-low LED
    end


    // Color Mapping
    assign red   = DE ? pixel_from_fifo : 8'd0;
    assign green = DE ? pixel_from_fifo : 8'd0;
    assign blue  = DE ? pixel_from_fifo : 8'd0;


    // --- 1. WRITE FIFO (Mandelbrot -> RAM) ---
    fifo_top fifo_mandelbrot_to_ram(
        .Data(write_data),
        .WrClk(clk_medium),         
        .RdClk(clk_medium),         
        .WrEn(write_en),
        .RdEn(custom_write_req), 
    .Almost_Full(fifo_in_almost_full), 
    .Q(fifo_in_to_sdram),        
    .Empty(fifo_in_empty),    
        .Full(fifo_in_full),
        .WrReset(1'b0),
        .RdReset(1'b0)
    
    );

    

    // --- 2. READ FIFO (RAM -> HDMI) ---
    fifo_out fifo_ram_to_hdmi(
        .Data(sdram_to_fifo_out),
        .WrClk(clk_medium),          
        .RdClk(clk_medium),          
        .WrEn(O_sdrc_rd_valid),
        .RdEn(DE),                  
        .Almost_Empty(fifo_out_almost_empty), 
        .Q(pixel_from_fifo),        
        .Empty(fifo_out_empty),                   
        .Full(fifo_out_full),
        .WrReset(fifo_out_rst),
        .RdReset(fifo_out_rst)
    );

    // --- 3. SDRAM CONTROLLER (Embedded SIP Version) ---
    SDRAM_controller_top_SIP sdram_ctrl(
        .O_sdram_clk(O_sdram_clk), 
        .O_sdram_cke(O_sdram_cke), 
        .O_sdram_cs_n(O_sdram_cs_n), 
        .O_sdram_cas_n(O_sdram_cas_n), 
        .O_sdram_ras_n(O_sdram_ras_n), 
        .O_sdram_wen_n(O_sdram_wen_n), 
        .O_sdram_dqm(O_sdram_dqm), 
        .O_sdram_addr(O_sdram_addr), 
        .O_sdram_ba(O_sdram_ba), 
        .IO_sdram_dq(IO_sdram_dq), 
        
        .I_sdrc_rst_n(pll_lock), 
        .I_sdrc_clk(clk_medium), 
        .I_sdram_clk(~clk_medium), 
        
        .I_sdrc_selfrefresh(I_sdrc_selfrefresh), 
        .I_sdrc_power_down(I_sdrc_power_down), 
        
        .I_sdrc_wr_n(I_sdrc_wr_n), 
        .I_sdrc_rd_n(I_sdrc_rd_n), 
        .I_sdrc_addr(I_sdrc_addr), 
        .I_sdrc_data_len(I_sdrc_data_len), 
        .I_sdrc_dqm(I_sdrc_dqm), 
        .I_sdrc_data(fifo_in_to_sdram), 
        .O_sdrc_data(sdram_to_fifo_out), 
        
        .O_sdrc_init_done(sdram_init_done), 
        .O_sdrc_busy_n(O_sdrc_busy_n), 
        .O_sdrc_rd_valid(O_sdrc_rd_valid), 
        .O_sdrc_wrd_ack(O_sdrc_wrd_ack) 
    );

    // Pixel Counter
    always @(posedge clk_medium) begin
        if (xBeam == H_TOTAL - 1) begin
            xBeam <= 0;
            if (yBeam == V_TOTAL - 1) begin
                yBeam <= 0;
            end else begin
                yBeam <= yBeam + 1'b1;
            end
        end else begin
            xBeam <= xBeam + 1'b1;
        end
    end

    // Connect everything to the Gowin HDMI hardware encoder
    DVI_TX_Top hdmi_inst (
        .I_rst_n(pll_lock),
        .I_rgb_clk(clk_medium),
        .I_serial_clk(clk_fast),
        .I_rgb_vs(Vsync),
        .I_rgb_hs(Hsync),
        .I_rgb_de(DE),
        .I_rgb_r(red),
        .I_rgb_g(green),
        .I_rgb_b(blue),
        
        .O_tmds_clk_p(tmds_clk_p),
        .O_tmds_clk_n(tmds_clk_n),
        .O_tmds_data_p(tmds_data_p),
        .O_tmds_data_n(tmds_data_n)
    );

endmodule