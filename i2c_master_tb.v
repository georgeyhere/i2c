//
//
module i2c_master_tb();

    reg i_clk = 0;
    reg i_rstn;

    reg i_wr;
    reg i_rd;
    reg i_slave_addr;
    reg i_reg_addr;
    wire i_wdata;

    wire o_rdata;

    wire o_busy;
    wire o_rdata_valid;
    wire [2:0] nack_status;

    wire scl, sda;

    pullup(scl);
    pullup(sda);

    always#(5) i_clk = ~i_clk;

    i2c_master 
    #(
    .CLK_FREQ (CLK_FREQ)
    ) 
    DUT
    (
    .i_clk         (i_clk         ), 
    .i_rstn        (i_rstn        ), // async active low rst

    // read/write control 
    .i_wr          (i_wr          ), // write enable
    .i_rd          (i_rd          ), // read enable
    .i_slave_addr  (7'h42         ), // 7-bit slave device addr
    .i_reg_addr    (i_reg_addr    ), // 8-bit register addr
    .i_wdata       (i_wdata       ), // 8-bit write data

    // read data out
    .o_rdata       (o_rdata       ), // 8-bit read data out

    // status signals
    .o_busy        (o_busy        ), // asserted when r/w in progress
    .o_rdata_valid (o_rdata_valid ), // indicates o_rdata is valid
    .o_nack_slave  (status[2]     ), // NACK on slave address frame
    .o_nack_addr   (status[1]     ), // NACK on register address frame
    .o_nack_data   (status[0]     ), // NACK on data frame

    // bidirectional i2c pins
    .SCL           (scl           ), 
    .SDA           (sda           )  
    );

    initial begin
        i_rstn = 0;
        i_wr   = 0;
        i_rd   = 0;
        i_reg_addr = 0;
        i_wdata    = 0;

        #200;

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
    end

endmodule