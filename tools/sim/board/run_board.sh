#!/bin/bash
# Whole-design bench of the New Juice MoonSound fork on the WonderTANG model.
# WSL Ubuntu-24.04 with Icarus 12 and sv2v.
# Usage: bash tools/sim/board/run_board.sh [main|blank|all|hdmi]
#   main (default)  boot, MoonSound, mapper, MegaRAM, ROM, OPLL, audio, timing (~40 min)
#   blank           the flash has no YRW801: the checksum must flag it (and the LED)
#   all             both at once (two cores)
#   hdmi            the video PLL runs: VU meter and debugger picture and HDMI audio
#                   through a verification receiver (hdmi_nj.vh), and its two negative
#                   controls (three cores, about 75 ms of board time each)
#   diff            the main bench on this tree and on REF (a git revision, default
#                   4730f9c = X3, before the bus input stage), side by side (two
#                   cores), then cyc_diff.py on their per-cycle bus logs: the same
#                   cycles and bytes, and how much later each bus event comes
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
rm -f build/nj_sv2v.v build/nj_sv2v_neg.v build/nj_pins.v build/sd_reader.sv
rm -f build/nj_sv2v_ref.v build/nj_pins_ref.v build/*.cyc

# ---- 1. the design as listed in new-juice.gprj, converted to plain Verilog ----
convert() {   # convert <tree> <output>
    local T=$1 OUT=$2 FILES LIST="" f
    FILES=$(grep -o 'path="[^"]*"' "$T/new-juice.gprj" | sed 's/path="//;s/"//' | grep -E '\.(v|sv)$')
    # sd_reader.sv has an unnamed instance (accepted by Gowin, not by sv2v)
    sed 's/^sd_crc_16(/sd_crc_16 u_sd_crc_16(/' "$T/src/sd_reader.sv" > build/sd_reader.sv
    for f in $FILES; do
        if [ "$f" = "src/sd_reader.sv" ]; then LIST="$LIST $PWD/build/sd_reader.sv"; else LIST="$LIST $T/$f"; fi
    done
    # SIMULATION: the jotego cores (jt2413, jt51, jt49) zero their clock dividers
    # in simulation; without it the OPLL never leaves X in Icarus.
    (cd "$T" && "$SV2V" -DMODEL_TECH -DSIMULATION -I src $LIST -w "$OLDPWD/$OUT")
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
open(p, 'w', encoding='utf-8').write(t.replace(sys.argv[1], sys.argv[2], 1))
EOF
}
shortcuts() {   # shortcuts <converted design>
    patch "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd6749999;" "localparam [22:0] AUTO_S1_DELAY_CYCLES = 23'd2000;" "$1"
    patch "localparam [15:0] LAST_TEST_ADDR = 16'hfffe;"          "localparam [15:0] LAST_TEST_ADDR = 16'h00fe;" "$1"
    patch "localparam [17:0] ROM_BYTE_COUNT = 18'h28000;"         "localparam [17:0] ROM_BYTE_COUNT = 18'h00800;" "$1"
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
    grep -v 'Pruning\|expects 1 bits\|timescale\|Static variable' build/$name.comp || true
    if [ $rc != 0 ] || [ ! -s build/$name.vvp ]; then
        rm -f build/$name.vvp
        echo "ERROR: iverilog failed for $name (build/$name.comp)"; exit 1
    fi
}
run() { stdbuf -oL vvp -n build/$1.vvp +cyclog=build/$1.cyc > build/$1.log 2>&1 || true; }
show() { echo "################ $1 ################"; grep -a -v "^VCD\|WARNING: .*prim_sim" build/$1.log | tail -150; }
verdict() {   # verdict <name>...: exit status 0 only if every log says PASS
    local n=0 npass=0 failed=""
    for name in "$@"; do
        n=$((n + 1))
        if grep -a -q "RESULTADO: PASS" build/$name.log; then npass=$((npass + 1)); else failed="$failed $name"; fi
    done
    echo "run_board: $npass/$n PASS${failed:+ (failed:$failed)}"
    [ "$npass" = "$n" ]
}
case "$MODE" in
    main)  comp main; run main; show main; verdict main ;;
    blank) comp blank -Ptb_nj_board.BLANK=1; run blank; show blank; verdict blank ;;
    all)   comp main; comp blank -Ptb_nj_board.BLANK=1
           run main & run blank & wait
           show main; show blank; verdict main blank ;;
    hdmi)
        # Negative controls: (neg) the FM R bar is fed from the wave R signal;
        # (neg2) the wave L and wave R bars are swapped (the bench pans the
        # wave so that they differ). The meter model (fed from each bar's own
        # source) must then disagree, and that must be the only failing check.
        cp build/nj_sv2v.v build/nj_sv2v_neg.v
        patch "opl4_vu_wave_r, opl4_vu_wave_l, opl4_vu_fm_r, opl4_vu_fm_l" \
              "opl4_vu_wave_r, opl4_vu_wave_l, opl4_vu_wave_r, opl4_vu_fm_l" build/nj_sv2v_neg.v
        cp build/nj_sv2v.v build/nj_sv2v_neg2.v
        patch "opl4_vu_wave_r, opl4_vu_wave_l, opl4_vu_fm_r, opl4_vu_fm_l" \
              "opl4_vu_wave_l, opl4_vu_wave_r, opl4_vu_fm_r, opl4_vu_fm_l" build/nj_sv2v_neg2.v
        rm -rf build/hdmi_*.ppm build/hdmi*_frames*.txt build/png build/png_bad
        EXTRA=../common/hdmi_rx_check.v comp hdmi -DWITH_HDMI -DHDMI_TAG=\"hdmi\"
        EXTRA=../common/hdmi_rx_check.v NETLIST=build/nj_sv2v_neg.v comp hdmi_neg -DWITH_HDMI -DHDMI_TAG=\"hdmi_neg\"
        EXTRA=../common/hdmi_rx_check.v NETLIST=build/nj_sv2v_neg2.v comp hdmi_neg2 -DWITH_HDMI -DHDMI_TAG=\"hdmi_neg2\"
        run hdmi & run hdmi_neg & run hdmi_neg2 & wait
        show hdmi
        echo "################ vu_check.py: the VU frames on the cable against the model ################"
        FOOT=$(sed -n 's/^ *"\(NEW JUICE MOONSOUND[^"]*\)";.*/\1/p' "$R/src/top.v")
        VU="python3 ../vu/vu_check.py build"
        $VU build/png "$R/src/moonsound/font8x8.v" --list hdmi_frames.txt \
            --title "NEW JUICE" --sub "+ MOONSOUND OPL4" --foot "$FOOT" | tee build/hdmi_check.log || true
        # the checker itself must see a one-segment error in one bar
        awk '{ if (NF == 15) $2 = ($2 + 1) % 29; print }' build/hdmi_frames.txt > build/hdmi_frames_bad.txt
        $VU build/png_bad "$R/src/moonsound/font8x8.v" --list hdmi_frames_bad.txt \
            --title "NEW JUICE" --sub "+ MOONSOUND OPL4" --foot "$FOOT" > build/hdmi_check_bad.log 2>&1 || true
        echo "################ negative control: FM R bar fed from wave R ################"
        grep -a "FAIL\]\|RESULTADO\|(vumetro)\|modelo del medidor" build/hdmi_neg.log | tail -12
        echo "################ negative control 2: wave L and wave R bars swapped ################"
        grep -a "FAIL\]\|RESULTADO\|(vumetro)\|modelo del medidor" build/hdmi_neg2.log | tail -12
        n=0; npass=0; failed=""
        n=$((n+1)); if grep -a -q "RESULTADO: PASS" build/hdmi.log; then npass=$((npass+1)); else failed="$failed hdmi"; fi
        n=$((n+1)); if grep -q "^MODELO: 2 cuadros .*PASS" build/hdmi_check.log; then npass=$((npass+1)); else failed="$failed vu_check"; fi
        n=$((n+1)); if grep -q "^MODELO: .*FAIL" build/hdmi_check_bad.log; then npass=$((npass+1)); else failed="$failed vu_check_neg"; fi
        n=$((n+1)); if grep -a -q "RESULTADO: FAIL" build/hdmi_neg.log && grep -a -q "FAIL\] vumetro: las barras" build/hdmi_neg.log \
                       && [ "$(grep -a -c 'FAIL\]' build/hdmi_neg.log)" = 1 ]; then npass=$((npass+1)); else failed="$failed hdmi_neg"; fi
        n=$((n+1)); if grep -a -q "RESULTADO: FAIL" build/hdmi_neg2.log && grep -a -q "FAIL\] vumetro: las barras" build/hdmi_neg2.log \
                       && [ "$(grep -a -c 'FAIL\]' build/hdmi_neg2.log)" = 1 ]; then npass=$((npass+1)); else failed="$failed hdmi_neg2"; fi
        echo "run_board: $npass/$n PASS${failed:+ (failed:$failed)}"
        echo "  (hdmi bench; vu_check of its frames; vu_check of a wrong level must FAIL; both negative controls must FAIL, on the meter check only)"
        [ "$npass" = "$n" ] ;;
    diff)
        # the reference design: REF's sources (its submodules, which git
        # archive leaves out, are taken from this tree: they are not changed)
        REF=${REF:-4730f9c}
        rm -rf build/ref && mkdir -p build/ref
        git -C "$R" -c safe.directory='*' archive "$REF" src new-juice.gprj | tar -x -C build/ref
        for s in src/jt49 src/jt51 src/jtopl; do rm -rf build/ref/$s; cp -r "$R/$s" build/ref/$s; rm -f build/ref/$s/.git; done
        convert "$PWD/build/ref" build/nj_sv2v_ref.v
        shortcuts build/nj_sv2v_ref.v
        python3 gen_pins_nj.py build/ref/src/top.v build/ref/src/top.cst build/nj_pins_ref.v
        echo "reference: $REF ($(git -C "$R" -c safe.directory='*' log --oneline -1 "$REF"))"
        comp main
        PINS=build/nj_pins_ref.v NETLIST=build/nj_sv2v_ref.v comp ref
        run main & run ref & wait
        show main; show ref
        echo "################ bus timing at the slot, $REF (ref) and this tree (main) ################"
        for name in ref main; do echo "-- $name"; grep -a "\[bus\]" build/$name.log; done
        echo "################ cyc_diff.py: ref -> main ################"
        rc=0; python3 cyc_diff.py build/ref.cyc build/main.cyc || rc=$?
        verdict main ref && [ $rc = 0 ] ;;
    *)     echo "unknown mode: $MODE"; exit 2 ;;
esac
