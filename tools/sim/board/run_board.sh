#!/bin/bash
# Whole-design bench of the New Juice V9990 fork on the WonderTANG model.
# WSL Ubuntu-24.04 with Icarus 12 and sv2v.
# Usage: bash tools/sim/board/run_board.sh [main|video|neg|all]
#   main (default)  boot (SDRAM test, ROM copy), the V9990 at ports 60h-6Fh (registers,
#                   VRAM by P#0 in B1 and P1, /WAIT, SDRAM placement at 0x780000, /INT,
#                   reset response), the 4 MB mapper, Super-MegaRAM, Nextor ROM, LINEAR,
#                   OPLL writes, I2S, CPU traffic against a V9990 with its display on
#                   (no lost VRAM slot), memory reads without /WAIT at 3.58 and 5.37 MHz,
#                   bus timing at the slot pins, no illegal SDRAM command, no stale row.
#                   The video PLL is held in reset.
#   video           the same boot, then the video PLL runs and the picture is captured
#                   at the input of the (stubbed) DVI transmitter: geometry of 2 frames
#                   (855 x 524 dots, DE 720 x 480, HS 62), border colour from the
#                   palette, a B1 bitmap line written by P#0 (video_nj.vh)
#   neg             negative controls (each one must FAIL): a bit of the V9990 read
#                   data flipped; the arbiter's a_busy without v_rw_req (the CPU no
#                   longer yields to a waiting V9990 access: its deadline breaks, a
#                   VRAM slot is lost); the V9990's SDRAM address moved off 0x780000;
#                   a_busy forced to 0. They run the short version of main (boot,
#                   registers, VRAM, CPU traffic with the display on)
#   all             main, video and neg at once (cores: 1 + 1 + 4)
# The DVI transmitter is Gowin's encrypted IP (src/v9990/dvi_tx/dvi_tx.v): neither
# sv2v nor Icarus read it, tools/sim/common/dvi_tx_stub.v takes its place.
set -e
cd "$(dirname "$0")"
R=$(cd ../../.. && pwd)
GW=${GOWIN_SIMLIB:-/mnt/c/Gowin/Gowin_V1.9.12.03_x64/IDE/simlib/gw2a/prim_sim.v}
SV2V=${SV2V:-sv2v}                  # or SV2V=/path/to/sv2v
command -v "$SV2V" >/dev/null || { echo "sv2v not found: put it in PATH or set SV2V=/path/to/sv2v"; exit 2; }
[ -f "$GW" ] || { echo "Gowin simulation library not found: $GW (set GOWIN_SIMLIB)"; exit 2; }
MODE=${1:-main}
mkdir -p build
# nothing from an earlier run is reused: a failed step stops the bench
rm -f build/nj_sv2v.v build/nj_sv2v_neg*.v build/nj_pins.v build/sd_reader.sv build/t9990.sv

# ---- 1. the design as listed in new-juice.gprj, converted to plain Verilog ----
# Three workarounds, none touches src/:
#  - sd_reader.sv has an unnamed instance (accepted by Gowin, not by sv2v);
#  - t9990.sv declares the interface instances (REG, STATUS...) after the first
#    module that uses them: sv2v wants them first, so the lines are moved up;
#  - the encrypted DVI_TX_Top IP is replaced by a stub with the same ports.
# sv2v also wants the files that declare interfaces and packages first.
convert() {   # convert <tree> <output>
    local T=$1 OUT=$2 FILES LIST="" PRE="" POST="" f x
    FILES=$(grep -o 'path="[^"]*"' "$T/new-juice.gprj" | sed 's/path="//;s/"//' | grep -E '\.(v|sv)$')
    sed 's/^sd_crc_16(/sd_crc_16 u_sd_crc_16(/' "$T/src/sd_reader.sv" > build/sd_reader.sv
    python3 fix_t9990.py "$T/src/v9990/tiny9990/t9990.sv" build/t9990.sv
    for f in $FILES; do
        case "$f" in
            src/sd_reader.sv)                LIST="$LIST $PWD/build/sd_reader.sv" ;;
            src/v9990/tiny9990/t9990.sv)     LIST="$LIST $PWD/build/t9990.sv" ;;
            src/v9990/dvi_tx/dvi_tx.v)       LIST="$LIST $PWD/../common/dvi_tx_stub.v" ;;
            *)                               LIST="$LIST $T/$f" ;;
        esac
    done
    for x in $LIST; do
        if grep -qE '^(interface|package) ' "$x"; then PRE="$PRE $x"; else POST="$POST $x"; fi
    done
    # SIMULATION: the jotego cores (jt2413, jt49) zero their clock dividers
    # in simulation; without it the OPLL never leaves X in Icarus.
    (cd "$T" && "$SV2V" -DMODEL_TECH -DSIMULATION -I src $PRE $POST -w "$OLDPWD/$OUT")
}
convert "$R" build/nj_sv2v.v

# ---- 2. simulation shortcuts (the RTL is not touched; every pattern must match once) ----
patch() {   # patch <old> <new> [file]
    local f=${3:-build/nj_sv2v.v} n
    n=$(grep -c -F -- "$1" "$f" || true)
    [ "$n" = 1 ] || { echo "patch: '$1' found $n times in $f"; exit 1; }
    python3 - "$1" "$2" "$f" <<'EOF'
import sys
p = sys.argv[3]
t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8', newline='\n').write(t.replace(sys.argv[1], sys.argv[2], 1))
EOF
}
shortcuts() {   # shortcuts <converted design>
    patch "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd6749999;" "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd2000;" "$1"
    patch "localparam [15:0] LAST_TEST_ADDR = 16'hfffe;"          "localparam [15:0] LAST_TEST_ADDR = 16'h00fe;" "$1"
    patch "localparam [17:0] ROM_BYTE_COUNT = 18'h28000;"         "localparam [17:0] ROM_BYTE_COUNT = 18'h00800;" "$1"
    # Icarus 12 has no unpacked unions: the blitter's `work` (t9990_blit.sv) becomes
    # the packed vector the three members overlay (same bits, LSB aligned)
    python3 fix_union.py "$1"
    # the sprite generate (t9990_sprite.sv) puts the loop index in an untyped localparam that
    # sv2v then uses inside a concatenation, which Icarus rejects ("indefinite width")
    patch "localparam v_num = _gv_v_num_1;" "localparam [4:0] v_num = _gv_v_num_1;" "$1"
    echo "sv2v OK: $(grep -c '^module ' "$1") modules in $1"
}
shortcuts build/nj_sv2v.v

# ---- 3. pin wrapper from top.cst ----
python3 gen_pins_nj.py "$R/src/top.v" "$R/src/top.cst" build/nj_pins.v

# ---- 4. compile and run ----
# The old .vvp and .log are removed first and a compile error stops the
# bench, so an older simulation can never run and pass in its place.
comp() {   # comp <name> [iverilog options]   (NETLIST, EXTRA: from the environment)
    local name=$1 rc=0; shift
    rm -f build/$name.vvp build/$name.log
    iverilog -g2012 -I . -s tb_nj_board "$@" -o build/$name.vvp \
        tb_nj_board.v wt20x_board.v ../common/sdram_model.v ../common/spi_flash_model.v \
        ${EXTRA:-} ${PINS:-build/nj_pins.v} ${NETLIST:-build/nj_sv2v.v} "$GW" > build/$name.comp 2>&1 || rc=$?
    grep -v 'Pruning\|expects 1 bits\|timescale\|Static variable\|out of bounds array access cur_area' build/$name.comp || true
    if [ $rc != 0 ] || [ ! -s build/$name.vvp ]; then
        rm -f build/$name.vvp
        echo "ERROR: iverilog failed for $name (build/$name.comp)"; exit 1
    fi
}
run() { stdbuf -oL vvp -n build/$1.vvp +cyclog=build/$1.cyc > build/$1.log 2>&1 || true; }
show() { echo "################ $1 ################"; grep -a -v "^VCD\|WARNING: .*prim_sim" build/$1.log | tail -${2:-250}; }
verdict() {   # verdict <name>...: exit status 0 only if every log says PASS
    local n=0 npass=0 failed="" name
    for name in "$@"; do
        n=$((n + 1))
        if grep -a -q "RESULTADO: PASS" build/$name.log; then npass=$((npass + 1)); else failed="$failed $name"; fi
    done
    echo "run_board: $npass/$n PASS${failed:+ (failed:$failed)}"
    [ "$npass" = "$n" ]
}
# negative controls: the netlist is patched, the bench is the short one
negs() {
    cp build/nj_sv2v.v build/nj_sv2v_neg1.v
    patch "assign rd_data = dout_q;" "assign rd_data = dout_q ^ 8'h01;" build/nj_sv2v_neg1.v
    # the CPU no longer yields to a V9990 request that is waiting: the arbiter's deadline breaks
    cp build/nj_sv2v.v build/nj_sv2v_neg2.v
    patch "assign a_busy = ((s_busy | v_rw_req) | rf_hold) | a_closed;" "assign a_busy = s_busy | rf_hold;" build/nj_sv2v_neg2.v
    cp build/nj_sv2v.v build/nj_sv2v_neg3.v
    patch "assign s_v_addr = {4'b1111, v_addr[18:2]};" "assign s_v_addr = {4'b1110, v_addr[18:2]};" build/nj_sv2v_neg3.v
    # a_busy forced to 0: the adapter issues whatever the controller is doing
    cp build/nj_sv2v.v build/nj_sv2v_neg4.v
    patch "assign a_busy = ((s_busy | v_rw_req) | rf_hold) | a_closed;" "assign a_busy = 1'b0;" build/nj_sv2v_neg4.v
    for n in 1 2 3 4; do NETLIST=build/nj_sv2v_neg$n.v comp neg$n -Ptb_nj_board.SHORT=1; done
}
negverdict() {
    local n=0 npass=0 failed="" name
    for name in neg1 neg2 neg3 neg4; do
        n=$((n + 1))
        echo "-- $name: $(grep -a -c 'FAIL\]' build/$name.log) FAIL lines"
        grep -a 'FAIL\]\|RESULTADO\|ranuras de VRAM perdidas' build/$name.log | head -8
        if grep -a -q "RESULTADO: FAIL" build/$name.log; then npass=$((npass + 1)); else failed="$failed $name"; fi
    done
    echo "run_board neg: $npass/$n negative controls detected${failed:+ (NOT detected:$failed)}"
    [ "$npass" = "$n" ]
}
case "$MODE" in
    main)  comp main; run main; show main; verdict main ;;
    video) comp video -DWITH_VIDEO; run video; show video; verdict video ;;
    neg)   negs; run neg1 & run neg2 & run neg3 & run neg4 & wait; negverdict ;;
    all)   comp main; comp video -DWITH_VIDEO; negs
           run main & run video & run neg1 & run neg2 & run neg3 & run neg4 & wait
           show main; show video
           rcv=0; verdict main video || rcv=$?
           rcn=0; negverdict || rcn=$?
           [ $rcv = 0 ] && [ $rcn = 0 ] ;;
    *)     echo "unknown mode: $MODE"; exit 2 ;;
esac
