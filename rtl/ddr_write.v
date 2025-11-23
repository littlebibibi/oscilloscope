module ddr_write #(
    parameter ADDR_WIDTH = 33 ,     // DDR4 8GB (64Gb) 33 bit address 
    parameter DATA_WIDTH = 512,     // MIG User Interface Width
    parameter BURST_LEN  = 8        // MIG Burst Length (BL8)
)(
    input wire                  clk             , // MIG UI Clock (333MHz)
    input wire                  rst_n           ,
    
    // 控制接口 (来自上位机/寄存器)
    input wire                  run_start       , // 开始采集脉冲
    input wire [ADDR_WIDTH-1:0] start_addr      , // 环形缓冲起始地址
    input wire [ADDR_WIDTH-1:0] end_addr        , // 环形缓冲结束地址
    input wire [31:0]           pre_trig_len    , // 预触发长度 (单位: MIG写次数/CMD)
    input wire [31:0]           post_trig_len   , // 触发后长度 (单位: MIG写次数/CMD)
    
    // 触发信号
    input wire trigger_in,          // 这是一个脉冲，需在该时钟域同步过
    
    // 数据输入 (来自前端 FIFO)
    input wire [DATA_WIDTH-1:0] fifo_data,
    input wire fifo_valid, // FIFO非空，可以读
    output reg fifo_rd_en,
    
    // MIG Native/AXI 接口 (简化版 Native Interface)
    output reg app_en,              // 命令使能
    output reg [2:0] app_cmd,       // 000 = Write
    output reg [ADDR_WIDTH-1:0] app_addr,
    input wire app_rdy,             // MIG 准备好接收命令
    
    output reg app_wdf_wren,        // 写数据使能
    output reg [DATA_WIDTH-1:0] app_wdf_data,
    output reg app_wdf_end,         // Burst结束标志
    input wire app_wdf_rdy,         // MIG 准备好接收数据
    
    // 状态反馈
    output reg capture_done,        // 采集完成
    output reg [ADDR_WIDTH-1:0] trig_pos_addr // 触发发生时的DDR地址
);

    // 状态定义
    localparam S_IDLE      = 3'd0;
    localparam S_PRE_FILL  = 3'd1; // 填满预触发所需的最小数据量
    localparam S_WAIT_TRIG = 3'd2; // 循环写入，等待触发
    localparam S_CAPTURE   = 3'd3; // 触发后写入固定长度
    localparam S_DONE      = 3'd4;

    reg [2:0] state;
    reg [31:0] cnt_post_trig;
    reg [31:0] cnt_pre_fill;
    
    // MIG 指令总是 Write (000)
    always @(*) app_cmd = 3'b000; 

    // 组合逻辑处理握手：只有当 MIG 的 CMD 和 DATA 通道都 Ready，且 FIFO 有数据时，才推进
    wire transaction_go = app_rdy && app_wdf_rdy && fifo_valid && (state != S_IDLE && state != S_DONE);

    // FIFO 读使能跟随 transaction
    always @(*) fifo_rd_en = transaction_go;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            app_en <= 0;
            app_wdf_wren <= 0;
            app_wdf_end <= 0; // 对于 Native 接口，通常跟 wren 一起拉高
            app_addr <= 0;
            trig_pos_addr <= 0;
            capture_done <= 0;
            cnt_post_trig <= 0;
            cnt_pre_fill <= 0;
        end else begin
            // 默认拉低使能，下面根据握手条件拉高
            app_en <= 0;
            app_wdf_wren <= 0;
            app_wdf_end <= 0;

            case (state)
                S_IDLE: begin
                    capture_done <= 0;
                    if (run_start) begin
                        app_addr <= start_addr;
                        cnt_pre_fill <= 0;
                        state <= S_PRE_FILL;
                    end
                end

                S_PRE_FILL: begin
                    if (transaction_go) begin
                        // 发出写指令
                        app_en <= 1;
                        app_wdf_wren <= 1;
                        app_wdf_end <= 1;
                        app_wdf_data <= fifo_data;
                        
                        // 地址递增 (MIG 地址通常按字节寻址，这里假设每次加 0x40 = 64Bytes = 512bits)
                        // 具体步进取决于 APP_ADDR_WIDTH 定义
                        if (app_addr + 8 >= end_addr) // 假设+8对应一个BL8的地址跳变
                            app_addr <= start_addr;
                        else
                            app_addr <= app_addr + 8; 

                        cnt_pre_fill <= cnt_pre_fill + 1;
                        
                        if (cnt_pre_fill >= pre_trig_len)
                            state <= S_WAIT_TRIG;
                    end
                end

                S_WAIT_TRIG: begin
                    // 持续循环写入
                    if (transaction_go) begin
                        app_en <= 1;
                        app_wdf_wren <= 1;
                        app_wdf_end <= 1;
                        app_wdf_data <= fifo_data;

                        // 记录触发位置
                        if (trigger_in) begin
                            trig_pos_addr <= app_addr; // 记录当前写指针
                            cnt_post_trig <= 0;
                            state <= S_CAPTURE;
                        end

                        // 环形地址逻辑
                        if (app_addr + 8 >= end_addr)
                            app_addr <= start_addr;
                        else
                            app_addr <= app_addr + 8;
                    end
                end

                S_CAPTURE: begin
                    // 写入剩余长度
                    if (transaction_go) begin
                        app_en <= 1;
                        app_wdf_wren <= 1;
                        app_wdf_end <= 1;
                        app_wdf_data <= fifo_data;

                        // 环形地址逻辑（即使触发后也可能回环）
                        if (app_addr + 8 >= end_addr)
                            app_addr <= start_addr;
                        else
                            app_addr <= app_addr + 8;

                        cnt_post_trig <= cnt_post_trig + 1;
                        
                        if (cnt_post_trig >= post_trig_len) begin
                            state <= S_DONE;
                            capture_done <= 1;
                        end
                    end
                end

                S_DONE: begin
                    // 等待上位机复位或新的 run 信号
                    if (run_start) state <= S_IDLE;
                end
            endcase
        end
    end

endmodule