// i2c module for communication w/ ov7670
//
// Timing parameters from i2c datasheet (p48, fast mode)
// -> https://www.nxp.com/docs/en/user-guide/UM10204.pdf
//
// Cross-referenced w/ OV7670 datasheet (p6)
// -> http://web.mit.edu/6.111/www/f2016/tools/OV7670_2006.pdf
//
/* **** INSTANTIATION TEMPLATE ****
	i2c_master 
	#(
	.CLK_FREQ (CLK_FREQ)
	) 
	DUT
	(
    .i_clk         (),
    .i_rstn        (), // async active low rst

    // read/write control 
    .i_wr          (), // write enable
    .i_rd          (), // read enable
    .i_slave_addr  (), // 7-bit slave device addr
    .i_reg_addr    (), // 8-bit register addr
    .i_wdata       (), // 8-bit write data

    // read data out
    .o_rdata       (), // 8-bit read data out

    // status signals
    .o_busy        (), // asserted when r/w in progress
    .o_rdata_valid (), // indicates o_rdata is valid
    .o_nack_slave  (), // NACK on slave address frame
    .o_nack_addr   (), // NACK on register address frame
    .o_nack_data   (), // NACK on data frame

    // bidirectional i2c pins
    .SCL           (), 
    .SDA           ()  
	);

*/
//
`default_nettype none
//
module i2c_master#
	(
		parameter CLK_FREQ = 100_000_000
	) 
	(
	input  wire       i_clk,         // 100 MHz clock
	input  wire       i_rstn,        // synchronous active low reset
 	
	input  wire       i_wr,
	input  wire       i_rd,

	input  wire [6:0] i_slave_addr,   // 7'h42 for OV7670
	input  wire [7:0] i_reg_addr,     // register address to read/write
	input  wire [7:0] i_wdata,        // write data
	output reg  [7:0] o_rdata,        // read data

	// Status
	output reg        o_busy,         // asserted when a r/w in progress
	output reg        o_rdata_valid,  // read data valid
	output reg        o_nack_slave,   // NACK on slave address
	output reg        o_nack_addr,    // NACK on register address
	output reg        o_nack_data,    // NACK on data byte

	// SCL and SDA pins
	inout  wire       SCL,
	inout  wire       SDA      
);



// **** SCL and SDA pin setup *****
//
	wire      scl_i;     // SCL in
    reg       scl_o = 1; // SCL out
    
    wire      sda_i;     // SDA in
    reg       sda_o = 1; // SDA out

    assign scl_i = SCL;
    assign SCL = (scl_o) ? 1'bz : 1'b0;

    assign sda_i = SDA;
    assign SDA = (sda_o) ? 1'bz : 1'b0;


// **** Timing Parameters ****
// 
	localparam T_CLK = 1/CLK_FREQ;
	//
	localparam T_SU_STA = 600/T_CLK,  // START condition setup time  
	           T_HD_STA = 600/T_CLK,  // START condition hold time
               T_LOW    = 1300/T_CLK, // SCL low time
	           T_HIGH   = 600/T_CLK,  // SCL high time
	           T_HD_DAT = 300/T_CLK,  // Data-in hold time
               T_SU_DAT = 100/T_CLK,  // Data-in setup time,
               T_SU_STO = 600/T_CLK;  // STOP condition setup time 

    // timer counter
    reg [$clog2(T_LOW)-1:0] timer     = 0;
    reg [$clog2(T_LOW)-1:0] nxt_timer = 0;



// **** FSM Registers ****
//
	localparam STATE_INITIAL    = 0,
	           STATE_IDLE       = 1,
	           STATE_START      = 2,
	           STATE_BIT1       = 3,
	           STATE_BIT2       = 4,
	           STATE_BIT3       = 5,
	           STATE_STOP       = 6,
	           STATE_TIMER      = 7; 

	reg [3:0] STATE = STATE_INITIAL;
	reg [3:0] NEXT_STATE;
	reg [3:0] RETURN_STATE;


	reg [26:0] sda_txqueue;
	reg [26:0] nxt_sda_txqueue;

	reg [7:0]  read_sr;
	reg [7:0]  nxt_read_sr;

    reg [4:0]  bit_counter;
    reg [4:0]  nxt_bit_counter;
    
    reg        load_r;
    reg        r_wr;
    reg        r_rd;
    reg [6:0]  r_slave_addr;
    reg [7:0]  r_reg_addr;
    reg [7:0]  r_wdata;
     
	reg nxt_scl_o;
	reg nxt_sda_o;

	reg [7:0] nxt_rdata;

	reg nxt_busy;
	reg nxt_rdata_valid;
	reg nxt_nack_slave;
	reg nxt_nack_addr;
	reg nxt_nack_data;

	reg wr_cycle;
	reg nxt_wr_cycle;

	reg repeat_start;
    reg nxt_repeat_start;



// **** Debounce External Inputs ****

    // shift registers initialized to idle values
    reg [3:0] scl_sr = {4{1'b1}};
    reg [3:0] sda_sr = {4{1'b1}};

    reg scl;   // debounced SCL
	reg sda;   // debounced SDA

    always@(posedge i_clk or negedge i_rstn) begin
    	if(!i_rstn) begin
    		scl_sr <= {4{1'b1}};
    		sda_sr <= {4{1'b1}};
    		scl    <= 1;
    		sda    <= 1;
    	end
    	else begin
    		scl_sr <= {scl_sr[2:0], scl_i};
    		sda_sr <= {sda_sr[2:0], sda_i};
    		scl <= (scl_sr == {4{1'b1}});
    		sda <= (sda_sr == {4{1'b1}});
    	end
    end

// **** FSM Next State Logic ****
//
	always@* begin
		nxt_scl_o        = scl_o;          // scl is floating by default           
		nxt_sda_o        = sda_o;          // sda is floating by default
        
        load_r           = 0;
        nxt_wr_cycle     = wr_cycle;
		nxt_sda_txqueue  = sda_txqueue;
        nxt_read_sr      = read_sr;
        
        nxt_rdata        = o_rdata;
		nxt_busy         = o_busy;
		nxt_rdata_valid  = o_rdata_valid;
		nxt_nack_slave   = o_nack_slave;
		nxt_nack_addr    = o_nack_addr;
		nxt_nack_data    = o_nack_data;
 
		nxt_timer        = timer;

		NEXT_STATE       = STATE;
		RETURN_STATE     = STATE;

		case(STATE)

			// initial state
			//     -> T_SU_STA (START setup time)
			STATE_INITIAL: begin
				nxt_scl_o    = 1;
				nxt_sda_o    = 1;
				timer        = T_SU_STA;
				NEXT_STATE   = STATE_TIMER;
				RETURN_STATE = STATE_IDLE;
			end
			
		    // idle state; SCL and SDA are high
			STATE_IDLE: begin
				nxt_scl_o      = 1;
				nxt_sda_o      = 1;
				nxt_busy       = 0;
				nxt_nack_slave = 0;
				nxt_nack_addr  = 0;
				nxt_nack_data  = 0;
				if((i_wr || i_rd) && (!o_busy)) begin
					nxt_rdata_valid  = (~i_rd);
					nxt_busy         = 1;
					load_r           = 1;
					nxt_wr_cycle     = 1;
					NEXT_STATE       = STATE_START;
				end
			end

			// START condition; pull SDA low 
			//     -> T_HD_STA (START hold time)
			STATE_START: begin
                nxt_sda_o       = 0;
                nxt_bit_counter = 0;

                // load sda_txqueue with transaction data
                //
				if(i_rd) begin
					// first part of read
					if(wr_cycle) 
						nxt_sda_txqueue = {i_slave_addr, // slave addr         [26:20]     
					                       1'b0,         // write bit          [19]
					                       1'b1,         // release; slave ack [18]
					                       i_reg_addr,   // rd register addr   [17:10]
					                       1'b1,         // release; slave ack [9]
					                       9'b0};        // * not used; repeated start *
					// second part of read
                    else 
                    	nxt_sda_txqueue = {i_slave_addr, // slave addr          [26:20]
					                       1'b1,         // read bit            [19]
					                       1'b1,         // release; slave ack  [18]
					                       8'hff,        // release; read data  [17:10]
					                       1'b1,         // release; master ACK [9]
					                       9'b0};        // * not used; STOP condition *
				end

				// write
				else begin
                    nxt_sda_txqueue = {i_slave_addr, // slave addr         [26:20]
                                       1'b0,         // write bit          [19]
                                       1'b1,         // release; slave ack [18]
                                       i_reg_addr,   // wr register addr   [17:10]
                                       1'b1,         // release; slave ack [9]
                                       i_wdata,      // write data         [8:1]
                                       1'b1};        // release; slave ack [0]
				end

				timer        = T_HD_STA;
                NEXT_STATE   = (!sda_i) ? STATE_TIMER : STATE_START;
                RETURN_STATE = STATE_BIT1;
			end
            
            // Bit Part 1; pull SCL low
            //     -> T_HD_DAT (Data-in Hold Time)
            STATE_BIT1: begin
            	nxt_scl_o    = 0;
            	timer        = T_HD_DAT;
            	NEXT_STATE   = (!scl) ? STATE_TIMER : STATE_BIT1;
            	RETURN_STATE = STATE_BIT2;
            end

            // Bit Part 2: SDA transaction
            //     -> T_LOW (SCL low time)
            STATE_BIT2: begin
            	nxt_sda_o       = sda_txqueue[26]; 
            	nxt_sda_txqueue = {sda_txqueue[25:0], 1'b0};
            	timer           = T_LOW;
            	NEXT_STATE      = STATE_TIMER;
            	RETURN_STATE    = STATE_BIT3;
            end

            // Bit Part 3: release SCL high
            //
            STATE_BIT3: begin
            	nxt_scl_o       = 1;
            	timer           = T_HIGH;

            	if(scl) begin
            		nxt_bit_counter = bit_counter + 1;

            		if(bit_counter == 8) begin
            			nxt_nack_slave = sda;
            		end
            		else if ((bit_counter == 17) & wr_cycle) begin
            			nxt_nack_addr = sda;
            		end
            		else if(bit_counter == 26) begin
            			nxt_nack_data = sda;
            		end
            		
            		// for reads:  state transition after second slave ACK
            		// for writes: state transition at end of transmission
            		if( ((bit_counter == 18) & (r_rd)) || (bit_counter == 27)) begin
            			timer        = T_SU_STO;
            			NEXT_STATE   = STATE_TIMER;
            			RETURN_STATE = STATE_STOP;
            		end
            		else begin
            			if((bit_counter != 17) && (r_rd)) begin
            				nxt_read_sr = {read_sr[6:1], sda};
            			end
            			timer        = T_HIGH;
            			NEXT_STATE   = STATE_TIMER;
            			RETURN_STATE = STATE_BIT1;
            		end 
            	end
            end

            // Stop Condition Part 1
            STATE_STOP: begin
            	sda_o = 1;
            	if(sda) begin
            		// reads
            	    if(r_rd) begin
            	    	// read write register address done
            	    	if(wr_cycle) begin
            	    		if(r_rd) begin
            	    			timer = T_SU_STA - T_SU_STO;
            	    		end
            	    		else begin
            	    			timer = T_SU_STA;
            	    		end
            	    		RETURN_STATE = STATE_START;
            	    	end
            	    	// read received
            	    	else begin
            	    		nxt_rdata       = read_sr;
            	    		nxt_rdata_valid = 1;
            	    		timer           = T_SU_STA;
            	    		RETURN_STATE    = STATE_IDLE;
            	    	end
            	    	nxt_wr_cycle = 0;
            	    	NEXT_STATE   = STATE_TIMER;
            	    end

            	    // writes
            	    else begin
    					nxt_rdata_valid = 0;
    					timer           = T_SU_STA;
    					NEXT_STATE      = STATE_TIMER;
    					RETURN_STATE    = STATE_IDLE;
            	    end
                end
            end

            STATE_TIMER: begin
            	if(timer == 0) begin
            		NEXT_STATE = RETURN_STATE;
            	end
            	else begin
            		nxt_timer = timer - 1;
            	end
            end

		endcase 
	end

// **** FSM Registers ****
//
	always@(posedge i_clk or negedge i_rstn) begin
		if(!i_rstn) begin
			o_rdata       <= 8'h0;
			o_busy        <= 0;
			o_rdata_valid <= 0;
			o_nack_slave  <= 0;
			o_nack_addr   <= 0;
			o_nack_data   <= 0;

			scl_o         <= 1;
			sda_o         <= 1;

			sda_txqueue   <= {27{1'b1}};
			read_sr       <= 8'h0;
			bit_counter   <= 5'h0;

			wr_cycle      <= 0;
			repeat_start  <= 0;

			r_wr          <= 0;
            r_rd          <= 0;
            r_slave_addr  <= 0;
            r_reg_addr    <= 0;
            r_wdata       <= 0;

			STATE         <= STATE_INITIAL;
		end
		else begin
			o_rdata       <= nxt_rdata;
			o_busy        <= nxt_busy;
			o_rdata_valid <= nxt_rdata_valid;
			o_nack_slave  <= nxt_nack_slave;
			o_nack_addr   <= nxt_nack_addr;
			o_nack_data   <= nxt_nack_data;

			scl_o         <= nxt_scl_o;
			sda_o         <= nxt_sda_o;

			sda_txqueue   <= nxt_sda_txqueue;
			read_sr       <= nxt_read_sr;
			bit_counter   <= nxt_bit_counter;

			wr_cycle      <= nxt_wr_cycle;
			repeat_start  <= nxt_repeat_start;

			if(load_r) begin
				r_wr         <= i_wr;
				r_rd         <= i_rd;
				r_slave_addr <= i_slave_addr;
				r_reg_addr   <= i_reg_addr;
				r_wdata      <= i_wdata;
			end
		end
	end



endmodule 
