#!/bin/bash
# Benches of the VU meter on HDMI (New Juice MoonSound fork).
# WSL Ubuntu-24.04 with Icarus 12, python3 and sv2v (SV2V=/path/to/sv2v).
#   bash tools/sim/vu/run_vu.sh          (about two minutes)
#
#  1. tb_vu_meter_eq.v: src/moonsound/vu_meter_nj.v against MoonTANG's
#     vu_meter.v (moontang/, commit 5400f15) on random signals: the same
#     levels and peak marks in every frame. Negative control: HOLD 44 must FAIL.
#  2. tb_vu_hdmi_nj.v: src/moonsound/vu_screen.v with the texts of src/top.v,
#     through the fork's hdmi module (src/hdmi, via sv2v); the frame at the
#     output of hdmi.sv is compared pixel for pixel with vu_check.py's model.
#     Negative control: the same frame against a one-segment-wrong level must FAIL.
#     Then the same with the other YRW801 states (copying, error, not a
#     YRW801) and with the MSX clock stopped, each against the model.
#  3. only with VG=<impl/gwsynthesis/new-juice.vg of a build>: the three ROMs
#     of vu_screen (text elements, strings, font) as Gowin synthesis filled its
#     block RAMs, against the simulation (tb_vu_rom_dump.v + rom_check.py).
#  4. only with GL=<netlist from syn/run_syn.sh>: step 2 with the Gowin
#     synthesis netlist of vu_screen (Gowin simulation primitives) instead of
#     the RTL, so the block-RAM ROMs and the registers synthesis moved into
#     them are checked too.
# The whole design on the board model, HDMI receiver included, is
# tools/sim/board/run_board.sh hdmi.
set -e
cd "$(dirname "$0")"
R=$(cd ../../.. && pwd)
SV2V=${SV2V:-sv2v}
command -v "$SV2V" >/dev/null || { echo "sv2v not found: put it in PATH or set SV2V=/path/to/sv2v"; exit 2; }
mkdir -p build
rm -f build/eq*.vvp build/eq*.log build/vu_hdmi_nj* build/frames_hdmi_nj*.txt build/hdmi_nj_sv2v.v build/check_nj*.log
n=0; npass=0; failed=""
pass() { n=$((n+1)); if eval "$2"; then npass=$((npass+1)); else failed="$failed $1"; fi; }

echo "################ 1. vu_meter_nj = MoonTANG's vu_meter ################"
SRC="tb_vu_meter_eq.v moontang/vu_meter.v $R/src/moonsound/vu_meter_nj.v"
iverilog -g2005 -s tb_vu_meter_eq -o build/eq.vvp $SRC
iverilog -g2005 -DMUTANT=1 -s tb_vu_meter_eq -o build/eqm.vvp $SRC
vvp -n build/eq.vvp  | tee build/eq.log  | tail -2
vvp -n build/eqm.vvp > build/eqm.log; tail -2 build/eqm.log
pass eq      'grep -q "^RESULTADO: PASS" build/eq.log'
pass eq_neg  'grep -q "^RESULTADO: FAIL" build/eqm.log'

echo "################ 2. vu_screen with the fork's texts, through hdmi.sv ################"
# the texts, as src/top.v gives them to vu_screen
TITLE=$(sed -n 's/^ *\.TITLE("\([^"]*\)"),.*/\1/p' "$R/src/top.v")
SUB=$(sed -n 's/^ *\.SUB("\([^"]*\)"),.*/\1/p' "$R/src/top.v")
FOOT=$(sed -n 's/^ *"\(NEW JUICE MOONSOUND[^"]*\)";.*/\1/p' "$R/src/top.v")
echo "title '$TITLE', subtitle '$SUB', footer '$FOOT'"
H=$R/src/hdmi
"$SV2V" -DMODEL_TECH $H/hdmi.sv $H/tmds_channel.sv $H/packet_picker.sv $H/packet_assembler.sv \
    $H/audio_clock_regeneration_packet.sv $H/audio_info_frame.sv $H/audio_sample_packet.sv \
    $H/auxiliary_video_information_info_frame.sv $H/source_product_description_info_frame.sv -w build/hdmi_nj_sv2v.v
Q='"'
iverilog -g2012 -s tb_vu_hdmi_nj -o build/vu_hdmi_nj.vvp \
    "-DVU_TITLE=${Q}$TITLE${Q}" "-DVU_TITLE_N=${#TITLE}" "-DVU_SUB=${Q}$SUB${Q}" "-DVU_SUB_N=${#SUB}" \
    "-DVU_FOOT=${Q}$FOOT${Q}" "-DVU_FOOT_N=${#FOOT}" \
    $R/src/moonsound/vu_screen.v $R/src/moonsound/font8x8.v build/hdmi_nj_sv2v.v tb_vu_hdmi_nj.v
( cd build && vvp -n vu_hdmi_nj.vvp ) | tee build/vu_hdmi_nj.log | tail -2
python3 vu_check.py build build/png "$R/src/moonsound/font8x8.v" --list frames_hdmi_nj.txt \
    --title "$TITLE" --sub "$SUB" --foot "$FOOT" | tee build/check_nj.log
awk '{ if (NF == 15) $2 = ($2 + 1) % 29; print }' build/frames_hdmi_nj.txt > build/frames_hdmi_nj_bad.txt
python3 vu_check.py build build/png_bad "$R/src/moonsound/font8x8.v" --list frames_hdmi_nj_bad.txt \
    --title "$TITLE" --sub "$SUB" --foot "$FOOT" > build/check_nj_bad.log 2>&1 || true
pass hdmi       'grep -q "^RESULTADO HDMI: PASS" build/vu_hdmi_nj.log'
pass model      'grep -q "^MODELO: 1 cuadros .*PASS" build/check_nj.log'
pass model_neg  'grep -q "^MODELO: .*FAIL" build/check_nj_bad.log'

# the other YRW801 and MSX states (the frame above has YRW801 OK, MSX OK):
# ... (copying), ERROR, NO VALIDA, and MSX --
for st in "0 1" "2 1" "3 1" "1 0"; do
    set -- $st; d=build/st_$1$2; rm -rf "$d"; mkdir -p "$d"
    iverilog -g2012 -s tb_vu_hdmi_nj -DST_ROM=$1 -DST_MSX=$2 -o "$d/vu.vvp"         "-DVU_TITLE=${Q}$TITLE${Q}" "-DVU_TITLE_N=${#TITLE}" "-DVU_SUB=${Q}$SUB${Q}" "-DVU_SUB_N=${#SUB}"         "-DVU_FOOT=${Q}$FOOT${Q}" "-DVU_FOOT_N=${#FOOT}"         $R/src/moonsound/vu_screen.v $R/src/moonsound/font8x8.v build/hdmi_nj_sv2v.v tb_vu_hdmi_nj.v
    ( cd "$d" && vvp -n vu.vvp ) > "$d/vu.log"
    python3 vu_check.py "$d" "$d/png" "$R/src/moonsound/font8x8.v" --list frames_hdmi_nj.txt         --title "$TITLE" --sub "$SUB" --foot "$FOOT" > "$d/check.log" 2>&1 || true
    grep -h "st_rom=" "$d/check.log"; tail -1 "$d/check.log"
    pass "st_rom$1_msx$2" "grep -q '^RESULTADO HDMI: PASS' $d/vu.log && grep -q 'st_rom=$1 st_msx=$2' $d/check.log && grep -q '^MODELO: 1 cuadros .*PASS' $d/check.log"
done

if [ -n "${VG:-}" ]; then
    echo "################ 3. the ROMs of vu_screen in a synthesis netlist ($VG) ################"
    iverilog -g2012 -s tb_vu_rom_dump -o build/rom_dump.vvp         "-DVU_TITLE=${Q}$TITLE${Q}" "-DVU_TITLE_N=${#TITLE}" "-DVU_SUB=${Q}$SUB${Q}" "-DVU_SUB_N=${#SUB}"         "-DVU_FOOT=${Q}$FOOT${Q}" "-DVU_FOOT_N=${#FOOT}"         $R/src/moonsound/vu_screen.v $R/src/moonsound/font8x8.v tb_vu_rom_dump.v
    ( cd build && vvp -n rom_dump.vvp )
    python3 rom_check.py "$VG" build/rom_dump.txt | tee build/rom_check.log
    python3 rom_check.py "$VG" build/rom_dump.txt --neg > build/rom_check_neg.log || true
    pass rom      'grep -q "^ROM: PASS" build/rom_check.log'
    pass rom_neg  'grep -q "^ROM: FAIL" build/rom_check_neg.log'
fi

if [ -n "${GL:-}" ]; then
    echo "################ 4. the synthesis netlist of vu_screen ($GL), through hdmi.sv ################"
    GW=${GOWIN_SIMLIB:-/mnt/c/Gowin/Gowin_V1.9.12.03_x64/IDE/simlib/gw2a/prim_sim.v}
    # the RTL frame of step 2 goes first, so that only the netlist can pass
    rm -f build/vu_hdmi_gl.vvp build/vu_hdmi_gl.log build/check_gl.log build/vu_hdmi_nj.ppm build/frames_hdmi_nj.txt
    iverilog -g2012 -s tb_vu_hdmi_nj -DVU_NETLIST -o build/vu_hdmi_gl.vvp         "-DVU_TITLE=${Q}$TITLE${Q}" "-DVU_TITLE_N=${#TITLE}" "-DVU_SUB=${Q}$SUB${Q}" "-DVU_SUB_N=${#SUB}"         "-DVU_FOOT=${Q}$FOOT${Q}" "-DVU_FOOT_N=${#FOOT}"         "$GL" "$GW" build/hdmi_nj_sv2v.v tb_vu_hdmi_nj.v 2>&1 | grep -v "warning\|timescale" | head -5
    ( cd build && vvp -n vu_hdmi_gl.vvp ) | grep -a -v "^VCD\|prim_sim" | tee build/vu_hdmi_gl.log | tail -2
    python3 vu_check.py build build/png_gl "$R/src/moonsound/font8x8.v" --list frames_hdmi_nj.txt         --title "$TITLE" --sub "$SUB" --foot "$FOOT" | tee build/check_gl.log
    pass gl_hdmi   'grep -q "^RESULTADO HDMI: PASS" build/vu_hdmi_gl.log'
    pass gl_model  'grep -q "^MODELO: 1 cuadros .*PASS" build/check_gl.log'
fi

echo "run_vu: $npass/$n PASS${failed:+ (failed:$failed)}  (eq, eq_neg must FAIL, hdmi, model, model_neg must FAIL, the four other states${VG:+, rom, rom_neg must FAIL}${GL:+, gl_hdmi, gl_model})"
[ "$npass" = "$n" ]
