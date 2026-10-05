// 27 MHz board oscillator
create_clock -name clkin -period 37.037 -waveform {0 18.518} [get_ports {clkin}] -add
// Native MSX CPU/JT2413 clock, nominally 3.579545 MHz
create_clock -name cpu_clk -period 279.365 -waveform {0 139.682} [get_ports {cpu_clkin}] -add

// S1 only asynchronously restarts the power-on/PLL reset sequencer. It is
// never sampled as functional data and has no synchronous setup requirement.
set_false_path -from [get_ports {s1}]

// 108 MHz main/SDRAM domain
create_generated_clock -name main_clk -source [get_ports {clkin}] -master_clock clkin -divide_by 1 -multiply_by 4 -add [get_nets {main_clk}]
create_generated_clock -name video_clk_135 -source [get_ports {clkin}] -master_clock clkin -divide_by 1 -multiply_by 5 -add [get_nets {video_clk_135}]
create_generated_clock -name hdmi_audio_clk -source [get_ports {clkin}] -master_clock clkin -divide_by 612 -add [get_nets {hdmi_audio_clk_raw}]
//create_generated_clock -name sdram_clk -source [get_ports {clkin}] -master_clock clkin -divide_by 1 -multiply_by 4 -duty_cycle 50 -phase 180 -add [get_nets {sdram_clk}]

// All 27 MHz <-> 108 MHz transfers use explicit synchronizers or bundled-data
// mailboxes. Do not time them as single-cycle synchronous paths.
set_clock_groups -asynchronous -group [get_clocks {clkin video_clk_135}] -group [get_clocks {hdmi_audio_clk}] -group [get_clocks {main_clk}]
set_clock_groups -asynchronous -group [get_clocks {cpu_clk}] -group [get_clocks {clkin video_clk_135 hdmi_audio_clk main_clk}]
