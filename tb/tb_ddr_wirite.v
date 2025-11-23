`timescale 1ns / 1ps

module tb_ddr_write;

    // Parameters
    parameter ADDR_WIDTH = 29;
    parameter DATA_WIDTH = 512;

    // Signals
    reg clk;
    reg rst;
    reg run_start;
    reg [ADDR_WIDTH-1:0] start_addr;
    reg [ADDR_WIDTH-1:0] end_addr;
    reg [31:0] pre_trig_len;
    reg [31:0] post_trig_len;
    reg trigger_in;
    
    reg [DATA_WIDTH-1:0] fifo_data;
    reg fifo_valid;
    wire fifo_rd_en;
    
    wire app_en;
    wire [2:0] app_cmd;
    wire [ADDR_WIDTH-1:0] app_addr;
    reg app_rdy;
    
    wire app_wdf_wren;
    wire [DATA_WIDTH-1:0] app_wdf_data;
    wire app_wdf_end;
    reg app_wdf_rdy;
    
    wire capture_done;
    wire [ADDR_WIDTH-1:0] trig_pos_addr;

    // Instantiate CUT (Code Under Test)
    ddr_write #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(!rst),
        .run_start(run_start),
        .start_addr(start_addr),
        .end_addr(end_addr),
        .pre_trig_len(pre_trig_len),
        .post_trig_len(post_trig_len),
        .trigger_in(trigger_in),
        .fifo_data(fifo_data),
        .fifo_valid(fifo_valid),
        .fifo_rd_en(fifo_rd_en),
        .app_en(app_en),
        .app_cmd(app_cmd),
        .app_addr(app_addr),
        .app_rdy(app_rdy),
        .app_wdf_wren(app_wdf_wren),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end(app_wdf_end),
        .app_wdf_rdy(app_wdf_rdy),
        .capture_done(capture_done),
        .trig_pos_addr(trig_pos_addr)
    );

    // Clock Generation (333MHz approx 3ns)
    initial begin
        clk = 0;
        forever #1.5 clk = ~clk;
    end

    // Simulate MIG Ready signals (Random backpressure)
    always @(posedge clk) begin
        app_rdy <= ($random % 10) != 0; // 90% chance ready
        app_wdf_rdy <= ($random % 10) != 0;
    end

    // Simulate Data Source
    always @(posedge clk) begin
        if (rst) begin
            fifo_data <= 0;
            fifo_valid <= 0;
        end else begin
            fifo_valid <= 1; // Always have data
            if (fifo_rd_en)
                fifo_data <= fifo_data + 1;
        end
    end

    // Test Sequence
    initial begin
        // Initialize
        rst = 1;
        run_start = 0;
        trigger_in = 0;
        start_addr = 29'h0000_0000;
        end_addr   = 29'h0000_0100; // Small buffer for sim (size 256)
        // 步进是8，所以总共有 256/8 = 32 个位置
        
        pre_trig_len = 10;  // 预触发写10次
        post_trig_len = 20; // 触发后写20次
        
        #100;
        rst = 0;
        #50;
        
        // 1. Start Acquisition
        $display("Starting Acquisition...");
        run_start = 1;
        #10 run_start = 0;

        // Wait some time (Let it pre-fill and loop inside ring buffer)
        // Ring buffer size is small, so it should wrap around quickly
        #2000; 
        
        // 2. Assert Trigger
        $display("Asserting Trigger...");
        @(posedge clk);
        trigger_in = 1;
        #3 ; // Pulse trigger
        trigger_in = 0;

        // 3. Wait for Done
        wait(capture_done);
        $display("Capture Done! Trigger Address: %h", trig_pos_addr);
        
        #500;
        $finish;
    end

endmodule