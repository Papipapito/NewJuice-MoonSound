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

// MoonSound (OPL4), all from rpll_main and therefore phase related to main_clk:
//   opl4_clk54   CLKOUTD  = 108 / 2 (bus side of the OPL4)
//   opl4_clk_eng CLKOUTD3 = 108 / 3 = 36 MHz (PCM engine and OPL3 FM core)
// They are timed together with main_clk: every crossing between them is
// analysed (the toggle synchronizers also tolerate a missed edge).
create_generated_clock -name opl4_clk54 -source [get_ports {clkin}] -master_clock clkin -divide_by 1 -multiply_by 2 -add [get_nets {opl4_clk54}]
create_generated_clock -name opl4_clk_eng -source [get_ports {clkin}] -master_clock clkin -divide_by 3 -multiply_by 4 -add [get_nets {opl4_clk_eng}]

// All 27 MHz <-> 108 MHz transfers use explicit synchronizers or bundled-data
// mailboxes. Do not time them as single-cycle synchronous paths.
set_clock_groups -asynchronous -group [get_clocks {clkin video_clk_135}] -group [get_clocks {hdmi_audio_clk}] -group [get_clocks {main_clk opl4_clk54 opl4_clk_eng}]
set_clock_groups -asynchronous -group [get_clocks {cpu_clk}] -group [get_clocks {clkin video_clk_135 hdmi_audio_clk main_clk opl4_clk54 opl4_clk_eng}]

// MoonSound FM: the Gray-code crossing of the OPL3 host FIFO (afifo) is
// designed not to meet hold between clk54 and clk_eng, and the first stage of
// its 2FF synchronizers and of its reset synchronizer accepts metastability by
// design. Same exceptions as in MoonTANG.
set_false_path -from [get_regs {moonsound_inst/u_opl4fm/u_opl3/host_if/afifo/wgray*}] -to [get_regs {moonsound_inst/u_opl4fm/u_opl3/host_if/afifo/wgray_cross*}]
set_false_path -from [get_regs {moonsound_inst/u_opl4fm/u_opl3/host_if/afifo/rgray*}] -to [get_regs {moonsound_inst/u_opl4fm/u_opl3/host_if/afifo/rgray_cross*}]
set_false_path -to [get_regs {moonsound_inst/u_opl4fm/u_opl3/*sync_regs[0]*}]
set_false_path -from [get_regs {moonsound_inst/rst_sync_2_s0}] -to [get_regs {moonsound_inst/u_opl4fm/u_opl3/reset_sync/r*}]
