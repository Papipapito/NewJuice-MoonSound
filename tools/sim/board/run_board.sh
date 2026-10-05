#!/bin/bash
# Whole-design bench of the New Juice MoonSound fork on the WonderTANG model.
# WSL Ubuntu-24.04 with Icarus 12 and sv2v.
# Usage: bash tools/sim/board/run_board.sh [main|blank|all]
#   main (default)  boot, MoonSound, mapper, MegaRAM, ROM, OPLL, audio, timing (~40 min)
#   blank           the flash has no YRW801: the checksum must flag it (and the LED)
#   all             both at once (two cores)
set -e
cd "$(dirname "$0")"
R=$(cd ../../.. && pwd)
GW=${GOWIN_SIMLIB:-/mnt/c/Gowin/Gowin_V1.9.12.03_x64/IDE/simlib/gw2a/prim_sim.v}
SV2V=${SV2V:-$(command -v sv2v || echo /home/albert/bin/sv2v)}
MODE=${1:-main}
mkdir -p build

# ---- 1. the design as listed in new-juice.gprj, converted to plain Verilog ----
FILES=$(grep -o 'path="[^"]*"' "$R/new-juice.gprj" | sed 's/path="//;s/"//' | grep -E '\.(v|sv)$')
# sd_reader.sv has an unnamed instance (accepted by Gowin, not by sv2v)
sed 's/^sd_crc_16(/sd_crc_16 u_sd_crc_16(/' "$R/src/sd_reader.sv" > build/sd_reader.sv
LIST=""
for f in $FILES; do
    if [ "$f" = "src/sd_reader.sv" ]; then LIST="$LIST $PWD/build/sd_reader.sv"; else LIST="$LIST $R/$f"; fi
done
# SIMULATION: the jotego cores (jt2413, jt51, jt49) zero their clock dividers
# in simulation; without it the OPLL never leaves X in Icarus.
(cd "$R" && "$SV2V" -DMODEL_TECH -DSIMULATION -I src $LIST -w "$OLDPWD/build/nj_sv2v.v")

# ---- 2. simulation shortcuts (the RTL is not touched; every pattern must match once) ----
patch() {   # patch <old> <new>
    local n; n=$(grep -c -F -- "$1" build/nj_sv2v.v || true)
    [ "$n" = 1 ] || { echo "patch: '$1' found $n times"; exit 1; }
    python3 - "$1" "$2" <<'EOF'
import sys
p = 'build/nj_sv2v.v'
t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(t.replace(sys.argv[1], sys.argv[2], 1))
EOF
}
patch "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd6749999;" "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd2000;"
patch "localparam [15:0] LAST_TEST_ADDR = 16'hfffe;"          "localparam [15:0] LAST_TEST_ADDR = 16'h00fe;"
patch "localparam [17:0] ROM_BYTE_COUNT = 18'h28000;"         "localparam [17:0] ROM_BYTE_COUNT = 18'h00800;"
echo "sv2v OK: $(grep -c '^module ' build/nj_sv2v.v) modules"

# ---- 3. pin wrapper from top.cst ----
python3 gen_pins_nj.py "$R/src/top.v" "$R/src/top.cst" build/nj_pins.v

# ---- 4. compile and run ----
comp() {   # comp <name> [iverilog options]
    local name=$1; shift
    iverilog -g2012 -I . -s tb_nj_board "$@" -o build/$name.vvp \
        tb_nj_board.v wt20x_board.v ../common/sdram_model.v ../common/spi_flash_model.v \
        build/nj_pins.v build/nj_sv2v.v "$GW" 2>&1 | grep -v 'Pruning\|expects 1 bits\|timescale\|Static variable' || true
}
run() { stdbuf -oL vvp -n build/$1.vvp > build/$1.log 2>&1 || true; }
show() { echo "################ $1 ################"; grep -a -v "^VCD\|WARNING: .*prim_sim" build/$1.log | tail -150; }
case "$MODE" in
    main)  comp main; run main; show main
           grep -q "RESULTADO: PASS" build/main.log ;;
    blank) comp blank -Ptb_nj_board.BLANK=1; run blank; show blank
           grep -q "RESULTADO: PASS" build/blank.log ;;
    all)   comp main; comp blank -Ptb_nj_board.BLANK=1
           run main & run blank & wait
           show main; show blank
           grep -q "RESULTADO: PASS" build/main.log && grep -q "RESULTADO: PASS" build/blank.log ;;
    *)     echo "unknown mode: $MODE"; exit 2 ;;
esac
