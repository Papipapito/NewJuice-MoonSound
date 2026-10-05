#!/bin/bash
# Block-level benches of the New Juice MoonSound fork (WSL Ubuntu-24.04, Icarus 12).
# Usage: bash tools/sim/blocks/run_blocks.sh [arb|refresh|map|opll|all]
#   arb      SDRAM arbiter + real adapter/controller/wave chain, Z80 at 3.58/5.37/7.16 MHz
#   refresh  Z80 stopped 70 ms: own refresh keeps the SDRAM alive (+ negative control)
#   map      2 MB mapper, wave memory map, size detection of the wave RAM
#   opll     New Juice's OPLL (jt2413) run directly, without sv2v
set -e
cd "$(dirname "$0")"
R=../../..
S=$R/src
M=$S/moonsound
mkdir -p build
WHAT=${1:-all}

ARB_SRC="tb_arb.v ../common/sdram_model.v $S/sdram.v $S/sdram_command_adapter.v $M/nj_sdram_arb.v $M/wave_sdram.v $M/opl4_pcm.v $M/opl4wave/ymf278b_gowin.v"
MAP_SRC="tb_map.v ../common/sdram_model.v $S/sdram.v $S/sdram_command_adapter.v $S/sdram_mapper.v $M/nj_sdram_arb.v $M/wave_sdram.v $M/opl4_pcm.v $M/opl4wave/ymf278b_gowin.v"

comp() {   # comp <tag> <top> <sources> [-P...]
    local tag=$1 top=$2 src=$3; shift 3
    iverilog -g2012 -o build/$tag.vvp -s $top "$@" $src 2>&1 | grep -v "Pruning\|expects\|warning: Some\|sorry\|timescale" | head -20 || true
}
run() { stdbuf -oL vvp -n build/$1.vvp > build/$1.log 2>&1 || true; }
bg() { local tag=$1; shift; ( comp $tag "$@" && run $tag ) & }

TZ358=279.365; TZ537=186.243; TZ716=139.683
if [ "$WHAT" = arb ] || [ "$WHAT" = all ]; then
    bg arb_358     tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ358
    bg arb_537     tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ537
    bg arb_716     tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ716
    bg arb_358_rr  tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ358 -Ptb_arb.PATTERN=1
    bg arb_f2o3    tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ358 -Ptb_arb.FMT=2 -Ptb_arb.OCT=3
    bg arb_nocpu   tb_arb "$ARB_SRC" -Ptb_arb.CPU_ON=0
    bg arb_cpu358  tb_arb "$ARB_SRC" -Ptb_arb.PCM_ON=0 -Ptb_arb.TZ=$TZ358
    bg arb_cpu537  tb_arb "$ARB_SRC" -Ptb_arb.PCM_ON=0 -Ptb_arb.TZ=$TZ537
    bg arb_cpu716  tb_arb "$ARB_SRC" -Ptb_arb.PCM_ON=0 -Ptb_arb.TZ=$TZ716
    # the same traffic without the CPU-read hint (to see what it buys)
    bg arb_nohint_537 tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ537 -Ptb_arb.CPU_HINT=0
    bg arb_nohint_716 tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ716 -Ptb_arb.CPU_HINT=0
    bg arb_f2o3_716   tb_arb "$ARB_SRC" -Ptb_arb.TZ=$TZ716 -Ptb_arb.FMT=2 -Ptb_arb.OCT=3
fi
if [ "$WHAT" = refresh ] || [ "$WHAT" = all ]; then
    bg ref_pos     tb_arb "$ARB_SRC" -Ptb_arb.MODE=1 -Ptb_arb.PCM_ON=0
    bg ref_neg     tb_arb "$ARB_SRC" -Ptb_arb.MODE=1 -Ptb_arb.PCM_ON=0 -Ptb_arb.NEG=1
fi
if [ "$WHAT" = map ] || [ "$WHAT" = all ]; then
    bg map         tb_map "$MAP_SRC"
fi
if [ "$WHAT" = opll ] || [ "$WHAT" = all ]; then
    bg opll        tb_opll "tb_opll.v $S/jtopl/hdl/*.v" -DSIMULATION
fi
wait
for f in build/*.log; do
    echo "=== $f"
    grep -a -E "CONFIG|AUDIO|MOTOR|LATENC|ARB |CPU |SDRAM|DATOS|HIST|Z80 parado|refrescos|caducadas|\[ok\]|\[FAIL\]|RESULTADO|ERROR|BAD" "$f" | head -60 | sed 's/^/  /'
done
