################################################################################
# Lists every failing timing endpoint of an existing build, one path each,
# from the post-route checkpoint the build leaves in prj/<project>/out/.
#
# Run from fpga/:
#   vivado -nojournal -mode batch -source report_timing_failing.tcl -tclargs lockbox
# Writes prj/<project>/out/post_route_timing_failing.rpt (the build itself
# writes the same report since this script was added).
################################################################################

set prj_name [lindex $argv 0]
set path_out prj/$prj_name/out

open_checkpoint $path_out/post_route.dcp
report_timing -file $path_out/post_route_timing_failing.rpt -sort_by group -max_paths 5000 -nworst 1 -unique_pins -slack_lesser_than 0 -path_type summary
