`timescale 1ns/1ps
module four_tb;
 reg clk01=0,clk23=0;always #4 clk01=~clk01;
 initial begin #1;forever #4 clk23=~clk23;end
 reg rstn01=0,rstn23=0;
 reg signed [13:0] adc0=0,adc1=0,adc2=0,adc3=0;
 reg [31:0] addr=0,wdata=0;reg wen=0,ren=0;
 wire [31:0] rdata;wire ack,err;
 mca_four #(.FIFO_LOG2(2),.WARMUP(256)) dut(.*);
 task access(input bit writing,input [31:0] a,d,output [31:0] v,input bit bad);
 integer timeout;
 begin
  @(negedge clk01);addr=a;wdata=d;wen=writing;ren=!writing;timeout=0;
  @(posedge clk01);#1;
  while(!ack && timeout<100) begin @(posedge clk01);#1;timeout=timeout+1;end
  if(!ack || err!==bad)$fatal(1,"MMIO ack/error %h err=%b",a,err);
  v=rdata;@(negedge clk01);wen=0;ren=0;repeat(5)@(negedge clk01);
 end
 endtask
 reg [31:0] v,w; reg [63:0] stamp[0:3]; integer c,j;
 task wr(input [31:0] a,d);begin access(1,a,d,v,0);end endtask
 task rd(input [31:0] a);begin access(0,a,0,v,0);end endtask
 initial begin
  repeat(10)@(negedge clk01);rstn01=1;rstn23=1;
  rd(0);if(v!=32'h4d434134)$fatal(1,"wrong global identity");
  for(c=0;c<4;c=c+1)begin
   wr((c+1)*4096+8,2);wr((c+1)*4096+'h2c,'h10000);
   wr((c+1)*4096+'h10,200);wr((c+1)*4096+'h14,1000);
   wr((c+1)*4096+8,1);
  end
  repeat(400)@(negedge clk01);
  for(j=0;j<40;j=j+1)begin adc0=j*100;adc1=j*100;adc2=j*100;adc3=j*100;@(negedge clk01);end
  for(j=40;j>0;j=j-1)begin adc0=j*100;adc1=j*100;adc2=j*100;adc3=j*100;@(negedge clk01);end
  adc0=0;adc1=0;adc2=0;adc3=0;
  repeat(1200)@(negedge clk01);
  for(c=0;c<4;c=c+1)begin
   rd((c+1)*4096+'h20);if(v!=1)$fatal(1,"channel %d lost overlapping pulse",c);
   rd((c+1)*4096+'h100);w=v;rd((c+1)*4096+'h104);stamp[c]={v,w};
   rd((c+1)*4096+'h118);if(v!=1)$fatal(1,"sequence not independent");
   wr((c+1)*4096+'h20,1);
  end
  for(c=1;c<4;c=c+1)if(stamp[c]+2<stamp[0] || stamp[c]>stamp[0]+2)$fatal(1,"time reference differs %d %d",stamp[0],stamp[c]);
  // Reset/disable channel 4; the common clock and other channels continue.
  wr(4*4096+8,2);
  access(0,'h40,0,v,1);
  wr('h40,1);rd('h44);if(v<stamp[0])$fatal(1,"channel reset reset common time");
  adc0=4000;adc1=4000;adc2=4000;adc3=4000;repeat(60)@(negedge clk01);
  adc0=0;adc1=0;adc2=0;adc3=0;repeat(1200)@(negedge clk01);
  for(c=0;c<4;c=c+1)begin rd((c+1)*4096+'h20);if(v!=(c==3 ? 0:1))$fatal(1,"active channel isolation");end
  $display("PASS four concurrent channels, asynchronous MMIO, common time and disable/reset isolation");$finish;
 end
 initial begin #200000;$fatal(1,"test timeout");end
endmodule
