// Single outstanding bundled-data mailbox. Payload is held until acknowledgement.
`timescale 1ns/1ps
module mca_bus_cdc (
 input wire clk_a, rstn_a, clk_b, rstn_b,
 input wire [31:0] addr_a, wdata_a,
 input wire wen_a, ren_a,
 output reg [31:0] rdata_a, output reg ack_a, err_a,
 output reg [31:0] addr_b, wdata_b,
 output reg wen_b, ren_b,
 input wire [31:0] rdata_b, input wire ack_b, err_b
);
 reg request, response, occupied, seen;
 reg [65:0] held_request;
 reg [32:0] held_response;
 (* ASYNC_REG="TRUE" *) reg req_meta, req_sync, rsp_meta, rsp_sync;
 always @(posedge clk_a) begin
  if (!rstn_a) begin
   request<=0; occupied<=0; seen<=0; held_request<=0;
   rsp_meta<=0; rsp_sync<=0; rdata_a<=0; ack_a<=0; err_a<=0;
  end else begin
   rsp_meta<=response; rsp_sync<=rsp_meta; ack_a<=0; err_a<=0;
   if (!wen_a && !ren_a) seen<=0;
   if (!occupied && !seen && (wen_a || ren_a)) begin
    held_request<={wen_a,ren_a,addr_a,wdata_a}; request<=!request;
    occupied<=1; seen<=1;
   end
   if (occupied && rsp_sync==request) begin
    rdata_a<=held_response[31:0]; err_a<=held_response[32]; ack_a<=1; occupied<=0;
   end
  end
 end
 always @(posedge clk_b) begin
  if (!rstn_b) begin
   req_meta<=0; req_sync<=0; response<=0; held_response<=0;
   addr_b<=0; wdata_b<=0; wen_b<=0; ren_b<=0;
  end else begin
   req_meta<=request; req_sync<=req_meta;
   if (!wen_b && !ren_b && req_sync!=response) begin
    {wen_b,ren_b,addr_b,wdata_b}<=held_request;
   end
   if ((wen_b || ren_b) && ack_b) begin
    held_response<={err_b,rdata_b}; response<=req_sync; wen_b<=0; ren_b<=0;
   end
  end
 end
endmodule
