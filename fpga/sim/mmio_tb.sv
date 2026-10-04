`timescale 1ns/1ps
module mmio_tb;
  wire [63:0] timestamp_ticks = 0;
  reg clk=0; always #4 clk=~clk;
  reg rstn=0; reg signed [13:0] adc=0;
  reg [31:0] addr=0,wdata=0; reg [3:0] wstrb=15;
  reg wen=0,ren=0;
  wire [31:0] rdata; wire ack,err;
  mca_mmio #(.FIFO_LOG2(2),.WARMUP(256)) dut(.*);
  integer j,k;
  reg [31:0] value, first_word;
  task write_reg(input [31:0] a,input [31:0] d,input integer hold_cycles,input bit expect_error);
    begin
      @(negedge clk); addr=a; wdata=d; wen=1;
      @(posedge clk); #1;
      if(!ack || err !== expect_error) $fatal(1,"write ack/error at %h",a);
      for(k=1;k<hold_cycles;k=k+1) begin
        @(posedge clk); #1;
        if(ack) $fatal(1,"held transaction acknowledged twice");
      end
      @(negedge clk); wen=0;
      repeat(2) @(negedge clk);
    end
  endtask
  task read_reg(input [31:0] a,output [31:0] v,input bit expect_error);
    begin
      @(negedge clk); addr=a; ren=1;
      @(posedge clk); #1;
      if(!ack || err !== expect_error) $fatal(1,"read ack/error at %h",a);
      v=rdata;
      @(negedge clk); ren=0;
      repeat(2) @(negedge clk);
    end
  endtask
  task pulse;
    begin
      @(negedge clk); adc=1000;
      repeat(50) @(negedge clk);
      adc=0;
      repeat(1100) @(negedge clk);
    end
  endtask
  initial begin
    repeat(4) @(negedge clk); rstn=1;
    read_reg(0,value,0); if(value != 32'h4d434131) $fatal(1,"wrong ID");
    write_reg('h2c,'h10000,1,0); // fixed zero baseline
    write_reg('h14,800,1,0);
    write_reg('h10,200,1,0);
    write_reg('h08,1,1,0);
    write_reg('h10,300,1,1); // no config changes during a run
    repeat(400) @(negedge clk);
    for(j=0;j<5;j=j+1) pulse();
    read_reg('h20,value,0); if(value != 4) $fatal(1,"FIFO not full: %d",value);
    write_reg('h40,1,1,0);
    read_reg('h60,value,0); if(value != 1) $fatal(1,"overflow counter: %d",value);
    read_reg('h5c,value,0); if(value != 5) $fatal(1,"trigger count: %d",value);
    read_reg('h64,value,0); if(value != 4) $fatal(1,"stored count: %d",value);
    for(j=1;j<=4;j=j+1) begin
      read_reg('h118,value,0); if(value != j) $fatal(1,"FIFO order: %d expected %d",value,j);
      read_reg('h100,first_word,0);
      read_reg('h100,value,0); if(value != first_word) $fatal(1,"head read consumed event");
      write_reg('h20,1,8,0); // repeated strobes must pop exactly once
      read_reg('h20,value,0); if(value != 4-j) $fatal(1,"pop count: %d",value);
    end
    read_reg('h100,value,1);
    write_reg('h20,1,1,1); // empty pop rejected
    write_reg('h08,2,1,0); // reset disables acquisition and clears counters
    read_reg('h20,value,0); if(value != 0) $fatal(1,"reset FIFO");
    write_reg('h40,1,1,0);
    read_reg('h5c,value,0); if(value != 0) $fatal(1,"reset counters");
    write_reg('h10,900,1,0); // invalid: short > long
    write_reg('h08,1,1,1);
    read_reg('h08,value,0); if(value != 0) $fatal(1,"invalid configuration enabled");
    $display("PASS: MMIO handshake, immutable records, order, full FIFO/drop accounting, reset, config validation");
    $finish;
  end
endmodule
