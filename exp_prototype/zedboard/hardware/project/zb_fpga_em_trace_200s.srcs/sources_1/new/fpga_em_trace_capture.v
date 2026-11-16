`timescale 1ns / 1ps
`default_nettype none

module fpga_em_trace_capture #(
    parameter integer SAMPLE_COUNT       = 400000,
    parameter integer CHUNK_SAMPLE_COUNT = 16000,
    parameter integer CLOCK_HZ           = 100000000,
    parameter integer SAMPLE_RATE_HZ     = 2000,
    parameter integer XADC_TIMEOUT_CLKS  = 10000
)(
    /*
     * Common 100 MHz PL clock.
     */
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.aclk CLK" *)
    (* X_INTERFACE_PARAMETER =
       "XIL_INTERFACENAME CLK.aclk, ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET aresetn" *)
    input wire aclk,

    /*
     * Active-low synchronous reset.
     */
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.aresetn RST" *)
    (* X_INTERFACE_PARAMETER =
       "XIL_INTERFACENAME RST.aresetn, POLARITY ACTIVE_LOW" *)
    input wire aresetn,

    /*
     * Request control from AXI GPIO.
     */
    input  wire        start,
    output wire [31:0] status,

    /*
     * XADC conversion-event and DRP controls.
     */
    output wire        xadc_convst,
    output wire [6:0]  xadc_daddr,
    output wire        xadc_den,
    output wire [15:0] xadc_di,
    output wire        xadc_dwe,

    /*
     * XADC result/status inputs.
     */
    input wire        xadc_busy,
    input wire        xadc_eoc,
    input wire        xadc_drdy,
    input wire [15:0] xadc_do,
    input wire [4:0]  xadc_channel,

    /*
     * AXI4-Stream output to AXI FIFO MM S.
     */
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER =
       "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1, HAS_TKEEP 0, HAS_TSTRB 0, HAS_TUSER 0, HAS_TID 0, HAS_TDEST 0" *)
    output wire [31:0] m_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire m_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input wire m_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire m_axis_tlast
);

    localparam integer SAMPLE_INTERVAL_CLKS =
        CLOCK_HZ / SAMPLE_RATE_HZ;

    localparam integer SAMPLE_TIMER_WIDTH =
        (SAMPLE_INTERVAL_CLKS <= 1)
            ? 1
            : $clog2(SAMPLE_INTERVAL_CLKS);

    localparam integer TIMEOUT_TIMER_WIDTH =
        (XADC_TIMEOUT_CLKS <= 1)
            ? 1
            : $clog2(XADC_TIMEOUT_CLKS);

    localparam [1:0] XADC_IDLE        = 2'd0;
    localparam [1:0] XADC_WAIT_EOC    = 2'd1;
    localparam [1:0] XADC_DRP_REQUEST = 2'd2;
    localparam [1:0] XADC_WAIT_DRDY   = 2'd3;

    localparam [7:0] ERROR_NONE           = 8'd0;
    localparam [7:0] ERROR_EOC_TIMEOUT    = 8'd1;
    localparam [7:0] ERROR_DRDY_TIMEOUT   = 8'd2;
    localparam [7:0] ERROR_WRONG_CHANNEL  = 8'd3;
    localparam [7:0] ERROR_SAMPLE_OVERRUN = 8'd4;

    localparam [6:0] VAUX0_DRP_ADDRESS = 7'h10;

    reg [SAMPLE_TIMER_WIDTH-1:0] sample_timer;
    reg [TIMEOUT_TIMER_WIDTH-1:0] timeout_timer;

    /*
     * Total accepted samples.
     * 19 bits are required to represent 0 through 400000.
     */
    reg [18:0] accepted_sample_count;
    
    /*
     * Position within the current 16000-sample transport chunk.
     * Range: 0 through 15999.
     */
    reg [13:0] chunk_sample_count;

    reg [1:0] xadc_state;
    reg       convst_reg;
    reg       den_reg;

    reg       busy_reg;
    reg       done_reg;
    reg       error_reg;
    reg [7:0] error_code_reg;

    reg start_delayed;

    reg [31:0] axis_data_reg;
    reg        axis_valid_reg;

    wire start_rising_edge;
    wire sample_tick;
    wire axis_transfer;

    assign start_rising_edge =
        start && !start_delayed;

    assign sample_tick =
        busy_reg &&
        !error_reg &&
        (accepted_sample_count < SAMPLE_COUNT) &&
        (sample_timer == SAMPLE_INTERVAL_CLKS - 1);

    assign axis_transfer =
        axis_valid_reg && m_axis_tready;

    /*
     * VAUX0 result register address.
     * This matches channel_out == 5'h10.
     */
    assign xadc_convst = convst_reg;
    assign xadc_daddr  = VAUX0_DRP_ADDRESS;
    assign xadc_den    = den_reg;
    assign xadc_di     = 16'h0000;
    assign xadc_dwe    = 1'b0;

    /*
     * XADC's 12-bit result occupies do_out[15:4].
     */
    assign m_axis_tdata =
        axis_data_reg;

    assign m_axis_tvalid =
        axis_valid_reg;

    assign m_axis_tlast =
        axis_valid_reg &&
        (chunk_sample_count == CHUNK_SAMPLE_COUNT - 1);

    /*
     * Status layout:
     *
     * bit 0       busy
     * bit 1       done
     * bit 2       error
     * bits 21:3   total accepted sample count, 0..400000
     * bits 29:22  error code
     * bits 31:30  reserved
     */
    assign status = {
        2'b00,
        error_code_reg,
        accepted_sample_count,
        error_reg,
        done_reg,
        busy_reg
    };

    always @(posedge aclk) begin
        if (!aresetn) begin
            sample_timer          <= {SAMPLE_TIMER_WIDTH{1'b0}};
            timeout_timer         <= {TIMEOUT_TIMER_WIDTH{1'b0}};
            accepted_sample_count <= 19'd0;
            chunk_sample_count    <= 14'd0;

            xadc_state            <= XADC_IDLE;
            convst_reg            <= 1'b0;
            den_reg               <= 1'b0;

            busy_reg              <= 1'b0;
            done_reg              <= 1'b0;
            error_reg             <= 1'b0;
            error_code_reg        <= ERROR_NONE;

            start_delayed         <= 1'b0;

            axis_data_reg         <= 32'd0;
            axis_valid_reg        <= 1'b0;
        end
        else begin
            start_delayed <= start;

            /*
             * These are one-clock pulses.
             */
            convst_reg <= 1'b0;
            den_reg    <= 1'b0;

            /*
             * Idle state: wait for a rising edge on START.
             */
            if (!busy_reg) begin
                sample_timer <= {SAMPLE_TIMER_WIDTH{1'b0}};

                if (start_rising_edge && !error_reg) begin
                    accepted_sample_count <= 19'd0;
                    chunk_sample_count    <= 14'd0;
                    timeout_timer         <=
                        {TIMEOUT_TIMER_WIDTH{1'b0}};

                    xadc_state            <= XADC_IDLE;
                    axis_valid_reg        <= 1'b0;

                    busy_reg              <= 1'b1;
                    done_reg              <= 1'b0;
                    error_code_reg        <= ERROR_NONE;
                end
            end

            /*
             * Active capture.
             */
            else if (!error_reg) begin
                /*
                 * Generate one conversion request every 50,000 clocks:
                 *
                 * 100 MHz / 2000 Hz = 50,000
                 */
                if (sample_tick) begin
                    sample_timer <=
                        {SAMPLE_TIMER_WIDTH{1'b0}};
                end
                else begin
                    sample_timer <= sample_timer + 1'b1;
                end

                /*
                 * Count samples only after the FIFO accepts them.
                 */
                if (axis_transfer) begin
                    axis_valid_reg <= 1'b0;
                
                    /*
                     * Advance or wrap the position within the
                     * current 16000-sample chunk.
                     */
                    if (chunk_sample_count ==
                        CHUNK_SAMPLE_COUNT - 1) begin
                
                        chunk_sample_count <= 14'd0;
                    end
                    else begin
                        chunk_sample_count <=
                            chunk_sample_count + 1'b1;
                    end
                
                    /*
                     * The complete acquisition stops only after
                     * all 400000 samples have been accepted.
                     */
                    if (accepted_sample_count ==
                        SAMPLE_COUNT - 1) begin
                
                        accepted_sample_count <=
                            accepted_sample_count + 1'b1;
                
                        busy_reg <= 1'b0;
                        done_reg <= 1'b1;
                    end
                    else begin
                        accepted_sample_count <=
                            accepted_sample_count + 1'b1;
                    end
                end

                case (xadc_state)
                    XADC_IDLE: begin
                        timeout_timer <=
                            {TIMEOUT_TIMER_WIDTH{1'b0}};

                        if (sample_tick) begin
                            /*
                             * A new period arrived before the previous
                             * result was transferred.
                             */
                            if (xadc_busy || axis_valid_reg) begin
                                busy_reg       <= 1'b0;
                                done_reg       <= 1'b0;
                                error_reg      <= 1'b1;
                                error_code_reg <=
                                    ERROR_SAMPLE_OVERRUN;
                            end
                            else begin
                                convst_reg <= 1'b1;
                                xadc_state <= XADC_WAIT_EOC;
                            end
                        end
                    end

                    XADC_WAIT_EOC: begin
                        if (xadc_eoc) begin
                            timeout_timer <=
                                {TIMEOUT_TIMER_WIDTH{1'b0}};

                            xadc_state <= XADC_DRP_REQUEST;
                        end
                        else if (timeout_timer ==
                                 XADC_TIMEOUT_CLKS - 1) begin

                            busy_reg       <= 1'b0;
                            done_reg       <= 1'b0;
                            error_reg      <= 1'b1;
                            error_code_reg <= ERROR_EOC_TIMEOUT;
                            xadc_state     <= XADC_IDLE;
                        end
                        else begin
                            timeout_timer <=
                                timeout_timer + 1'b1;
                        end
                    end

                    XADC_DRP_REQUEST: begin
                        /*
                         * Assert DEN for one DCLK cycle.
                         */
                        den_reg <= 1'b1;

                        timeout_timer <=
                            {TIMEOUT_TIMER_WIDTH{1'b0}};

                        xadc_state <= XADC_WAIT_DRDY;
                    end

                    XADC_WAIT_DRDY: begin
                        if (xadc_drdy) begin
                            timeout_timer <=
                                {TIMEOUT_TIMER_WIDTH{1'b0}};

                            xadc_state <= XADC_IDLE;

                            if (xadc_channel != 5'h10) begin
                                busy_reg       <= 1'b0;
                                done_reg       <= 1'b0;
                                error_reg      <= 1'b1;
                                error_code_reg <=
                                    ERROR_WRONG_CHANNEL;
                            end
                            else if (axis_valid_reg) begin
                                busy_reg       <= 1'b0;
                                done_reg       <= 1'b0;
                                error_reg      <= 1'b1;
                                error_code_reg <=
                                    ERROR_SAMPLE_OVERRUN;
                            end
                            else begin
                                axis_data_reg <= {
                                    20'h00000,
                                    xadc_do[15:4]
                                };

                                axis_valid_reg <= 1'b1;
                            end
                        end
                        else if (timeout_timer ==
                                 XADC_TIMEOUT_CLKS - 1) begin

                            busy_reg       <= 1'b0;
                            done_reg       <= 1'b0;
                            error_reg      <= 1'b1;
                            error_code_reg <= ERROR_DRDY_TIMEOUT;
                            xadc_state     <= XADC_IDLE;
                        end
                        else begin
                            timeout_timer <=
                                timeout_timer + 1'b1;
                        end
                    end

                    default: begin
                        busy_reg       <= 1'b0;
                        done_reg       <= 1'b0;
                        error_reg      <= 1'b1;
                        error_code_reg <=
                            ERROR_SAMPLE_OVERRUN;

                        xadc_state <= XADC_IDLE;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
