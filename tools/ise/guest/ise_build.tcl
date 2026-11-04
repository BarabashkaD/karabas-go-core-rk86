# xtclsh script: runs the complete flow of an existing ISE project without changing
# its properties.
# Usage: xtclsh ise_build.tcl <project.xise> <log_dir>

set xise [lindex $argv 0]
set logdir [lindex $argv 1]
if {$xise eq "" || $logdir eq ""} {
    puts "usage: xtclsh ise_build.tcl <project.xise> <log_dir>"
    exit 2
}

project open $xise

# Record the effective project properties (seed, effort, threads, ...).
set fh [open [file join $logdir project_properties.txt] w]
foreach p [lsort [project properties]] {
    if {[catch {set v [project get $p]}]} { set v "<unavailable>" }
    puts $fh "$p = $v"
}
close $fh

set ok [process run "Generate Programming File" -force rerun_all]
set st [process get "Generate Programming File" status]
puts "GENERATE_PROGRAMMING_FILE run=$ok status=$st"

project close

if {!$ok || ($st ne "up_to_date" && $st ne "warnings")} {
    exit 1
}
exit 0
