// Four native ADC-domain processors. No raw ADC bus crosses a clock domain.
// Register bank 0: global clock/identity. Banks 1..4: independent MCA1 registers.
`timescale 1ns/1ps
module mca_four #(
 parameter integer FIFO_LOG2=7, WARMUP=2048
)(
 input wire clk01, clk23, rstn01, rstn23,
 input wire signed [13:0] adc0, adc1, adc2, adc3,
 input wire [31:0] addr, wdata,
 input wire wen, ren,
 output wire [31:0] rdata, output wire ack, err
);
 reg [63:0] clock_ticks, clock_gray;
 reg [63:0] time01a, time01b, time01;
 (* ASYNC_REG="TRUE" *) reg [63:0] gray_meta, gray_sync;
 reg [63:0] time23;
 reg [63:0] snap_clock;
 reg global_seen, global_ack, global_err;
 reg [31:0] global_data;
 wire global_select=addr[19:12]==0;
 wire [3:0] selected;
 wire [31:0] ch_addr [0:3], ch_wdata [0:3], ch_rdata [0:3];
 wire [3:0] ch_wen, ch_ren, ch_ack, ch_err;
 wire [31:0] routed_data [0:3];
 wire [3:0] routed_ack, routed_err;
 function automatic [63:0] gray_decode(input [63:0] g);
  integer k;
  begin for(k=0;k<64;k=k+1) gray_decode[k]=^(g>>k); end
 endfunction
 always @(posedge clk01) begin
  if (!rstn01) begin
   clock_ticks<=0; clock_gray<=0; time01a<=0; time01b<=0; time01<=0;
   global_seen<=0; global_ack<=0; global_err<=0; global_data<=0; snap_clock<=0;
  end else begin
   clock_ticks<=clock_ticks+1;
   clock_gray<=((clock_ticks+1)>>1)^(clock_ticks+1);
   // Match nominal timestamp transfer latency to the other ADC pair.
   time01a<=clock_ticks; time01b<=time01a; time01<=time01b;
   global_ack<=0; global_err<=0;
   if (!wen && !ren) global_seen<=0;
   if (global_select && !global_seen && (wen || ren)) begin
    global_seen<=1; global_ack<=1; global_data<=0;
    if ((wen && ren) || addr[1:0]!=0) global_err<=1;
    else if (ren) case(addr[11:0])
     12'h000:global_data<=32'h4d434134; // MCA4
     12'h004:global_data<=32'h00020000;
     12'h008:global_data<=4;
     12'h030:global_data<=125000000;
     12'h044:global_data<=snap_clock[31:0];
     12'h048:global_data<=snap_clock[63:32];
     default:global_err<=1;
    endcase
    else if (wen && addr[11:0]==12'h040) snap_clock<=clock_ticks;
    else global_err<=1;
   end
  end
 end
 always @(posedge clk23) begin
  if (!rstn23) begin gray_meta<=0;gray_sync<=0;time23<=0;end
  else begin gray_meta<=clock_gray;gray_sync<=gray_meta;time23<=gray_decode(gray_sync);end
 end
 for(genvar c=0;c<4;c=c+1) begin: channel
  localparam integer CH=c;
  assign selected[c]=addr[19:12]==c+1;
  if(c<2) begin: direct
   assign ch_addr[c]={20'b0,addr[11:0]}; assign ch_wdata[c]=wdata;
   assign ch_wen[c]=wen && selected[c]; assign ch_ren[c]=ren && selected[c];
   assign routed_data[c]=ch_rdata[c];assign routed_ack[c]=ch_ack[c];assign routed_err[c]=ch_err[c];
  end else begin: cdc
   mca_bus_cdc mailbox(
    .clk_a(clk01),.rstn_a(rstn01),.clk_b(clk23),.rstn_b(rstn23),
    .addr_a({20'b0,addr[11:0]}),.wdata_a(wdata),.wen_a(wen && selected[c]),.ren_a(ren && selected[c]),
    .rdata_a(routed_data[c]),.ack_a(routed_ack[c]),.err_a(routed_err[c]),
    .addr_b(ch_addr[c]),.wdata_b(ch_wdata[c]),.wen_b(ch_wen[c]),.ren_b(ch_ren[c]),
    .rdata_b(ch_rdata[c]),.ack_b(ch_ack[c]),.err_b(ch_err[c]));
  end
  mca_mmio #(.FIFO_LOG2(FIFO_LOG2),.WARMUP(WARMUP),.EXTERNAL_TIME(1)) processor(
   .clk(CH<2 ? clk01 : clk23),.rstn(CH<2 ? rstn01 : rstn23),
   .adc(CH==0 ? adc0 : CH==1 ? adc1 : CH==2 ? adc2 : adc3),
   .timestamp_ticks(CH<2 ? time01 : time23),
   .addr(ch_addr[c]),.wdata(ch_wdata[c]),.wstrb(4'hf),.wen(ch_wen[c]),.ren(ch_ren[c]),
   .rdata(ch_rdata[c]),.ack(ch_ack[c]),.err(ch_err[c]));
 end
 assign rdata=global_select ? global_data : selected[0] ? routed_data[0] : selected[1] ? routed_data[1] :
               selected[2] ? routed_data[2] : selected[3] ? routed_data[3] : 32'hdeadbeef;
 assign ack=global_select ? global_ack : selected[0] ? routed_ack[0] : selected[1] ? routed_ack[1] :
             selected[2] ? routed_ack[2] : selected[3] ? routed_ack[3] : wen || ren;
 assign err=global_select ? global_err : selected[0] ? routed_err[0] : selected[1] ? routed_err[1] :
             selected[2] ? routed_err[2] : selected[3] ? routed_err[3] : wen || ren;
endmodule
