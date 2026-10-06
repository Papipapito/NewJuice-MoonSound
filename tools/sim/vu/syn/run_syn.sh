#!/bin/bash
# Synthesis only (Gowin, Git Bash on Windows) of vu_screen with the texts of
# src/top.v, to simulate its netlist: then, in WSL,
#   GL=tools/sim/vu/syn/impl/gwsynthesis/vu_screen_nj.vg bash tools/sim/vu/run_vu.sh
# Another Gowin: GW_SH=/c/Gowin/.../IDE/bin/gw_sh.exe bash run_syn.sh
set -e
cd "$(dirname "$0")"
R=$(cd ../../../.. && pwd)
GW_SH=${GW_SH:-/c/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe}
TITLE=$(sed -n 's/^ *\.TITLE("\([^"]*\)"),.*/\1/p' "$R/src/top.v")
SUB=$(sed -n 's/^ *\.SUB("\([^"]*\)"),.*/\1/p' "$R/src/top.v")
FOOT=$(sed -n 's/^ *"\(NEW JUICE MOONSOUND[^"]*\)";.*/\1/p' "$R/src/top.v")
{ echo '`define VU_TITLE "'"$TITLE"'"'; echo "\`define VU_TITLE_N ${#TITLE}"
  echo '`define VU_SUB "'"$SUB"'"';     echo "\`define VU_SUB_N ${#SUB}"
  echo '`define VU_FOOT "'"$FOOT"'"';   echo "\`define VU_FOOT_N ${#FOOT}"; } > texts.vh
rm -rf impl syn.log
cat > syn.tcl <<TCL
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file $(cygpath -m "$PWD/texts.vh")
add_file $(cygpath -m "$PWD/vu_screen_nj.v")
add_file $(cygpath -m "$R/src/moonsound/vu_screen.v")
add_file $(cygpath -m "$R/src/moonsound/font8x8.v")
set_option -top_module vu_screen_nj
set_option -verilog_std sysv2017
set_option -output_base_name vu_screen_nj
run syn
TCL
"$GW_SH" syn.tcl > syn.log 2>&1 || { tail -20 syn.log; exit 1; }
tr '>' '\n' < impl/gwsynthesis/vu_screen_nj_syn_rsc.xml | grep "SubModule name=\"u\"" | sed 's/^ *//'
ls -la impl/gwsynthesis/vu_screen_nj.vg
