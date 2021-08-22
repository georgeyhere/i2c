// directed unit tests for i2c_master
// -> just to test functionality on a *very limted* scale
// -> use SystemVerilog testbench instead
// 
module i2c_master_tb();

    reg        i_clk = 0;
    reg        i_rstn;

    reg        i_wr;
    reg        i_rd;
    reg  [7:0] i_reg_addr;
    reg  [7:0] i_wdata;

    wire [7:0] o_rdata;

    wire       o_busy;
    wire       o_rdata_valid;
    wire [2:0] nack_status;

    wire       i_scl, i_sda;
    wire       o_scl, o_sda;


// simulate SCL and SDA pins
//
    wire       SCL, SDA;
    pullup(SCL);
    pullup(SDA);

    assign SCL = (o_scl) ? 1'bz : 1'b0;
    assign SDA = (o_sda) ? 1'bz : 1'b0;

    assign i_scl = SCL;
    assign i_sda = SDA;

// generate clock
//
    parameter T_CLK = 10;
    always#(T_CLK/2) i_clk = ~i_clk;

// instantiate DUT
//
    i2c_master 
    #(
    .T_CLK (T_CLK)
    ) 
    DUT
    (
    .i_clk         (i_clk          ), 
    .i_rstn        (i_rstn         ), // async active low rst
 
    // read/write control  
    .i_wr          (i_wr           ), // write enable
    .i_rd          (i_rd           ), // read enable
    .i_slave_addr  (7'h42          ), // 7-bit slave device addr
    .i_reg_addr    (i_reg_addr     ), // 8-bit register addr
    .i_wdata       (i_wdata        ), // 8-bit write data
 
    // read data out 
    .o_rdata       (o_rdata        ), // 8-bit read data out

    // status signals
    .o_busy        (o_busy         ), // asserted when r/w in progress
    .o_rdata_valid (o_rdata_valid  ), // indicates o_rdata is valid
    .o_nack_slave  (nack_status[2] ), // NACK on slave address frame
    .o_nack_addr   (nack_status[1] ), // NACK on register address frame
    .o_nack_data   (nack_status[0] ), // NACK on data frame

    // bidirectional i2c pins
    .i_scl         (i_scl          ),
    .i_sda         (i_sda          ),
    .o_scl         (o_scl          ),
    .o_sda         (o_sda          ) 
    );

    initial begin
       $dumpfile("i2c_master_tb.vcd");
       $dumpvars(0, i2c_master_tb);
    end

    initial begin
        i_rstn     = 0;
        i_wr       = 0;
        i_rd       = 0;
        i_reg_addr = 0;
        i_wdata    = 0;

        #100;

        @(posedge i_clk) begin
            i_rstn  <= 1;
        end

        // attempt to write during initializations state
        // -> should be ignored
        @(posedge i_clk) begin
            i_wr       <= 1;
            i_reg_addr <= 8'h12;
            i_wdata    <= 8'h80;
        end

        // wait out initialization state
        #700;

        // write 0x80 to register 0x12
        @(posedge i_clk) begin
            i_wr       <= 1;
            i_reg_addr <= 8'h12;
            i_wdata    <= 8'h80;
        end

        @(posedge i_clk) begin
            i_wr       <= 0;
            i_reg_addr <= 0;
            i_wdata    <= 0;
        end

        #500_000;
        $finish;
    end

endmodule