# Gray bus changes at most one bit per source cycle. Bound propagation/skew to
# one 125-MHz period. Bundled mailbox data remains held for the round trip.
set gray_source [get_cells -hier -filter {NAME =~ *four_mca/clock_gray_reg*}]
set gray_meta [get_cells -hier -filter {NAME =~ *four_mca/gray_meta_reg*}]
set rq [get_cells -hier -filter {NAME =~ *four_mca/*mailbox/held_request_reg*}]
set dst [get_cells -hier -filter {NAME =~ *four_mca/*mailbox/addr_b_reg* || NAME =~ *four_mca/*mailbox/wdata_b_reg* || NAME =~ *four_mca/*mailbox/wen_b_reg* || NAME =~ *four_mca/*mailbox/ren_b_reg*}]
set rsp [get_cells -hier -filter {NAME =~ *four_mca/*mailbox/held_response_reg*}]
set rd [get_cells -hier -filter {NAME =~ *four_mca/*mailbox/rdata_a_reg* || NAME =~ *four_mca/*mailbox/err_a_reg*}]
foreach group [list $gray_source $gray_meta $rq $dst $rsp $rd] {
 if {[llength $group]==0} {error "MCA CDC constraint matched no cells"}
}
set_max_delay -datapath_only 8.000 -from $gray_source -to $gray_meta
set_bus_skew 8.000 -from $gray_source -to $gray_meta
set_max_delay -datapath_only 8.000 -from $rq -to $dst
# Remove the vendor's broad ADC23->ADC01 false path for these held response
# paths only, so their electrical delay is checked explicitly.
reset_path -from $rsp -to $rd
set_max_delay -datapath_only 8.000 -from $rsp -to $rd
set_bus_skew 8.000 -from $rsp -to $rd
