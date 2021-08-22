// 
//
//

interface dut_if();
	logic scl = 0;
	logic sda;
endinterface : dut_if

typedef logic [6:0] slave_addr_t;
typedef logic [7:0] reg_addr_t;
typedef logic [7:0] i2c_data_t;

//
//
//
module i2c_master_tb();

`define T_CLK 10

	dut_if dut_();

	logic wr_en;
	logic rd_en;
	logic clk, rstn;

	slave_addr_t slave_addr;
	reg_addr_t   reg_addr;
	i2c_data_t   wr_data;
	i2c_data_t   rd_data;

	i2c_master 
	#(
	.CLK_FREQ (CLK_FREQ)
	) 
	DUT
	(
    .i_clk         (clk),
    .i_rstn        (rstn), // async active low rst

    // read/write control 
    .i_wr          (wr_en), // write enable
    .i_rd          (rd_en), // read enable
    .i_slave_addr  (slave_addr), // 7-bit slave device addr
    .i_reg_addr    (reg_addr), // 8-bit register addr
    .i_wdata       (wr_data), // 8-bit write data

    // read data out
    .o_rdata       (rd_data), // 8-bit read data out

    // status signals
    .o_busy        (), // asserted when r/w in progress
    .o_rdata_valid (), // indicates o_rdata is valid
    .o_nack_slave  (), // NACK on slave address frame
    .o_nack_addr   (), // NACK on register address frame
    .o_nack_data   (), // NACK on data frame

    // bidirectional i2c pins
    .SCL           (dut_.scl), 
    .SDA           (dut_.sda)  
	);

// **** Driver Class ****
//
	class dut_driver;

		virtual dut_if dut_;
		mailbox#(uint32) mbx;

		bit verbose = false;
		uint16 clk_period;

		//
		function new(virtual dut_if dut_, uint16 clk_period, mailbox #(uint32) mbx);
			dut_       = dut_;
			clk_period = clk_period;
			mbx        = mbx;
		endfunction // new


		//
		task automatic run();
			fork begin
				forever begin
					// look for start condition
					@(negedge dut_.sda) begin
						logic [27:0] data_bits;

						// read in data bits when SCL is high
						for(int i=0; i<27; i++) begin
							@(posedge dut_.scl);
							if(dut_.scl == 1) data_bits[i] = dut_.sda;
						end

						int data;
						data = {data_bits, {5{1'b0}}};
						mbx.put(data);
					end 
				end
			end
			join_none
		endtask // run
	endclass // driver

// **** Simulation Tasks ****
//
	// task to initialize dut
	task automatic dut_init();
		slave_addr = 0;
		reg_addr   = 0;
		wr_data    = 0;
		wr_en      = 0;
		rd_en      = 0;
	endtask

	// task to reset dut
	task automatic dut_reset();
		rstn = 0;
		repeat(16) @(negedge clk);
		rstn = 1;
		#700;
	endtask // dut_reset


	// write task
	task automatic dut_write( slave_addr_t addr_slave, i2c_data_t addr_reg, i2c_data_t data_wr);
		@(negedge clk);
		slave_addr = addr_slave;
		rd_en      = 0;
		wr_en      = 1;
		reg_addr   = addr_reg;
		wr_data    = data_wr;
		@(negedge clk);
	endtask // dut_write

	task automatic build_test_harness( mailbox #(uint32) dut_driver_mbx, mailbox#(uint32) dut_monitor_mbx);

		dut_driver_mbx  = new(0);
		dut_monitor_mbx = new(0);

		dut_driver  = new( dut_, `T_CLK, dut_driver_mbx);
		dut_monitor = new( dut_, `T_CLK, dut_monitor_mbx);

		dut_driver.run();
		dut_monitor.run();

	endtask // build_test_harness


	task automatic test_dut_interface();
		i2c_data_t readval
		$display("testing dut interface...");

		dut_reset();

		dut_write('h42, 'h12, 'h42);

	endtask

	task automatic test_dut();
		mailbox #(uint32) sent_data_mbx;
		mailbox #(uint32) dut_driver_mbx;
		mailbox #(uint32) dut_monitor_mbx;

		build_test_harness(dut_driver_mbx, dut_monitor_mbx);
		dut_reset();

		sent_data_mbx = new(0);
		$display("Testing...");

		repeat(50) begin
			uint32 readval;
			logic [6:0] slave_addr_dat = $random;
			logic [7:0] reg_addr_dat = $random;
			logic [7:0] wr_dat = $random;

			dut_write(slave_addr_dat, reg_addr_dat, wr_dat);
			sent_data_mbx.put({slave_addr_dat, reg_addr_dat, wr_dat});
		end

		compare_mailbox_data(sent_data_mbx, dut_monitor_mbx);
	endtask

	function automatic void compare_mailbox_data( mailbox #(uint32) ref_mbx, mailbox #(uint32) dut_mbx);
		uint32 error;
		uint32 good;
		uint32 ref_mbx_num;
		uint32 dut_mbx_num;

		ref_mbx_num = ref_mbx.num();
		dut_mbx_num = dut_mbx.num();

		repeat(ref_mbx_num) begin
			uint32 dut_data;
			uint32 ref_data;
			uint32 tryget_result;

			ref_mbx.try_get(ref_data);
			tryget_result = dut_mbx.try_get( dut_data );
      	    if (tryget_result) begin
      	        if (ref_data != dut_data) begin
      	            error++;
      	        end
      	        else begin
      	            good++;
      	        end
      	        break; //no more DUT data
      	    end
		end

		$display("Good: %2d, Errored: %2d, Excess reference: %2d, Excess DUT: %2d",
			    good, error, ref_mbx_num, dut_mbx_num);
	endfunction


// **** Simulation ****
//

	// system clock
	initial begin
		clk = 0;
		forever #5ns clk = ~clk;
	end

	// instantiate classes
	dut_driver  dut_driver;
	dut_monitor dut_monitor;

	// main sim process
	initial begin
		$display("%t << Starting the simulation >>", $time);
		dut_init();

		test_dut();
		$display("%m: %t << Simulation ran to completion >>", $time);
		$finish;
	end

endmodule // i2c_master_tb

