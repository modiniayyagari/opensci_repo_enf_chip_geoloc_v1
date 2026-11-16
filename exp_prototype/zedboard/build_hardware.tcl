# Build with Vivado 2025.2 in a fresh ENF_BUILD_DIR outside this repository.
if {![info exists ::env(ENF_BUILD_DIR)] || $::env(ENF_BUILD_DIR) eq ""} {
    puts stderr "Set ENF_BUILD_DIR to a fresh external build directory."
    exit 1
}
set repository [file normalize [file join [file dirname [info script]] ..]]
set build [file normalize $::env(ENF_BUILD_DIR)]
if {[string equal -nocase $build $repository] ||
    [string first "[string tolower $repository]/" "[string tolower $build]/"] == 0} {
    puts stderr "ENF_BUILD_DIR must be outside the repository."
    exit 1
}
if {[catch {
    # STEP_1: Check tools and reserve fresh output paths.
    if {[version -short] ne "2025.2"} {error "Vivado 2025.2 is required"}
    if {[llength [get_parts -quiet xc7z020clg484-1]] != 1} {error "Install Zynq-7000 device support"}
    foreach directory {source vivado artifacts reports} {
        if {[file exists $build/$directory]} {error "Use a fresh build directory: $build/$directory exists"}
    }
    file mkdir $build/source
    file mkdir $build/reports
    file copy $repository/zedboard/hardware $build/source/hardware
    set hardware $build/source/hardware

    # STEP_2: Register RTL before reconstructing the unchanged block design.
    create_project enf_clean $build/vivado -part xc7z020clg484-1
    set_property target_language Verilog [current_project]
    add_files -norecurse $hardware/project/zb_fpga_em_trace_200s.srcs/sources_1/new/fpga_em_trace_capture.v
    update_compile_order -fileset sources_1
    source $hardware/scripts/zb_fpga_em_trace_bd_final.tcl
    set bd [get_files -quiet */zb_fpga_em_trace_bd.bd]
    if {[llength $bd] != 1} {error "Expected one reconstructed block design"}
    validate_bd_design
    save_bd_design
    add_files -fileset constrs_1 -norecurse $hardware/project/zb_fpga_em_trace_200s.srcs/constrs_1/new/zb_fpga_em_trace_xadc_pins.xdc
    generate_target all $bd
    add_files -norecurse [make_wrapper -files $bd -top]
    set_property top zb_fpga_em_trace_bd_wrapper [current_fileset]
    update_compile_order -fileset sources_1

    # STEP_3: Synthesize and route using the project's default strategies.
    launch_runs synth_1 -jobs 6
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
        ![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {error "Synthesis failed"}
    launch_runs impl_1 -to_step route_design -jobs 6
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%" ||
        ![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {error "Implementation failed"}
    open_run impl_1
    report_utilization -file $build/reports/utilization.rpt
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file $build/reports/timing_summary.rpt
    report_drc -file $build/reports/drc.rpt
    foreach delay_type {max min} {
        set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
        if {[llength $paths] == 0 || [get_property SLACK [lindex $paths 0]] < 0} {error "Timing check failed: $delay_type"}
    }
    if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {error "DRC errors remain"}

    # STEP_4: Generate a real bitstream and export its fresh hardware platform.
    launch_runs impl_1 -to_step write_bitstream -jobs 6
    wait_on_run impl_1
    set bitstream $build/vivado/enf_clean.runs/impl_1/zb_fpga_em_trace_bd_wrapper.bit
    if {![file exists $bitstream] || [file size $bitstream] == 0} {error "Bitstream missing"}
    file mkdir $build/artifacts
    write_hw_platform -fixed -include_bit -force -file $build/artifacts/enf_clean.xsa
    if {[file size $build/artifacts/enf_clean.xsa] == 0} {error "XSA missing"}
    puts "HARDWARE BUILD PASS: $bitstream; $build/artifacts/enf_clean.xsa"
} failure]} {
    puts stderr "HARDWARE BUILD FAIL: $failure"
    exit 1
}
exit 0
