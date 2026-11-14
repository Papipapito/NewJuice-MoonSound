#!/bin/bash
# Banco del arbitro SDRAM del fork V9990 de New Juice (WSL Ubuntu-24.04, Icarus 12).
# Usage: bash tools/sim/blocks/run_varb.sh [traffic|stop|neg|all]
#   traffic  trafico normal a 3,58 / 5,37 / 7,16 MHz de Z80, con V al 100 % (y al 50 %, y con el Z80 sin RFSH) y con V parado (LOAD=0)
#   stop     CPU parada 70 ms (sin RFSH), con V al 100 % y con V parado: el refresco propio mantiene la retencion
#   neg      controles negativos: sin refresco propio, bit de v_dout, bit de la lectura de A,
#            corrupcion de la SDRAM, ACK tarde
set -e
cd "$(dirname "$0")"
R=../../..
S=$R/src
mkdir -p build
WHAT=${1:-all}

SRC="tb_varb.v ../common/sdram_model.v $S/sdram.v $S/sdram_command_adapter.v $S/v9990/nj_v9990_arb.v"

# Cada banco se compila de cero: se borran antes su .vvp y su .log, de modo que
# un error de compilacion nunca deje una simulacion vieja que pase.
comp() {   # comp <tag> <top> <sources> [-P...]
    local tag=$1 top=$2 src=$3; shift 3
    rm -f build/$tag.vvp build/$tag.log
    if ! iverilog -g2012 -o build/$tag.vvp -s $top "$@" $src > build/$tag.comp 2>&1; then
        echo "ERROR: iverilog failed for $tag" >> build/$tag.comp; rm -f build/$tag.vvp
    fi
    grep -v "Pruning\|expects\|warning: Some\|sorry\|timescale" build/$tag.comp | head -20
    [ -s build/$tag.vvp ]
}
run() { stdbuf -oL vvp -n build/$1.vvp > build/$1.log 2>&1 || true; }
TAGS=""
bg() { local tag=$1; shift; TAGS="$TAGS $tag"; ( comp $tag "$@" && run $tag ) & }

TZ358=279.365; TZ537=186.243; TZ716=139.683
P=-Ptb_varb
if [ "$WHAT" = traffic ] || [ "$WHAT" = all ]; then
    bg t358        tb_varb "$SRC" $P.TZ=$TZ358
    bg t537        tb_varb "$SRC" $P.TZ=$TZ537
    bg t716        tb_varb "$SRC" $P.TZ=$TZ716
    bg t537_rr     tb_varb "$SRC" $P.TZ=$TZ537 $P.PATTERN=1 $P.SEED=2
    bg t537_l50    tb_varb "$SRC" $P.TZ=$TZ537 $P.LOAD=50 $P.SEED=3
    # el Z80 sin RFSH: el refresco propio convive con trafico de CPU y de V
    bg t537_norf   tb_varb "$SRC" $P.TZ=$TZ537 $P.NORFSH=1 $P.SEED=4
    # Not run: Z80 at 7.16 MHz with no RFSH at all. The own refresh plus a V
    # access can then hold a CPU write 30 clocks (278 ns), longer than the
    # gap to the next command of the synthetic Z80, which gets dropped. A
    # running Z80 always gives RFSH (then the refreshes are A's, t716 above).
    # bg t716_norf   tb_varb "$SRC" $P.TZ=$TZ716 $P.NORFSH=1 $P.SEED=5
    bg l0_358      tb_varb "$SRC" $P.TZ=$TZ358 $P.LOAD=0
    bg l0_537      tb_varb "$SRC" $P.TZ=$TZ537 $P.LOAD=0
    bg l0_716      tb_varb "$SRC" $P.TZ=$TZ716 $P.LOAD=0
fi
if [ "$WHAT" = stop ] || [ "$WHAT" = all ]; then
    bg stop_v100   tb_varb "$SRC" $P.MODE=1 $P.LOAD=100
    bg stop_v0     tb_varb "$SRC" $P.MODE=1 $P.LOAD=0
fi
if [ "$WHAT" = neg ] || [ "$WHAT" = all ]; then
    bg neg_ref     tb_varb "$SRC" $P.MODE=1 $P.LOAD=100 $P.NEG=1 $P.NOREFV=1
    bg neg_vdout   tb_varb "$SRC" $P.NEGV=1
    bg neg_adata   tb_varb "$SRC" $P.NEGA=1
    bg neg_mem     tb_varb "$SRC" $P.NEGM=3
    bg neg_slot    tb_varb "$SRC" $P.ACK_DLY=8
fi
wait
[ -n "$TAGS" ] || { echo "unknown bench: $WHAT"; exit 2; }
n=0; npass=0; failed=""
for tag in $TAGS; do
    n=$((n + 1))
    echo "=== $tag"
    if [ ! -s build/$tag.vvp ]; then
        echo "  ERROR: no simulation (compile failed, see build/$tag.comp)"
        failed="$failed $tag"; continue
    fi
    grep -a -E "CONFIG|SLOTS|OPS V|DATOS|PH |PHHIST|COMBO|EN  |CPU  |REFRESH|SDRAM :|CPU parada|caducadas|\[ok\]|\[FAIL\]|RESULTADO|ERROR|BAD_|PERDIDA|AJENA|DISTINTA|v_timing" build/$tag.log | head -80 | sed 's/^/  /'
    if grep -a -q "RESULTADO: PASS" build/$tag.log; then
        npass=$((npass + 1))
    else
        failed="$failed $tag"
    fi
done
echo "run_varb: $npass/$n PASS${failed:+ (failed:$failed)}"
[ "$npass" = "$n" ]
