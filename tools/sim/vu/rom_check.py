#!/usr/bin/env python3
# ============================================================================
# rom_check.py - the block-RAM ROMs of vu_screen in a Gowin synthesis netlist
# against the same ROMs in simulation.
#
#   python3 rom_check.py <netlist.vg> <rom_dump.txt> [--neg]
#
# rom_dump.txt comes from tb_vu_rom_dump.v. For each of it_rom (table of text
# elements, 512 x 33), str_rom (font codes of the strings, 128 x 6 used bits)
# and the font (u_font, 512 x 8), the INIT_RAM_xx strings of the pROM / pROMX9
# that synthesis made are unpacked (entry i at bits [i*W +: W] of the
# concatenated rows, W = BIT_WIDTH) and compared entry by entry, after
# checking that the address pins are the expected signals, in order.
# --neg flips one bit of the dump first: the check must then FAIL.
# ============================================================================
import re
import sys


def pins(vg, inst):
    m = re.search(r"\b(pROM|pROMX9)\s+(\S*%s)\s*\((.*?)\);" % re.escape(inst), vg, re.S)
    if not m:
        return None, None, None
    name = m.group(2)
    ad = re.search(r"\.AD\(\{(.*?)\}\)", m.group(3), re.S).group(1)
    do = re.search(r"\.DO\(\{(.*?)\}\)", m.group(3), re.S).group(1)
    return name, [s.strip() for s in ad.split(",")], [s.strip() for s in do.split(",")]


def init_bits(vg, name):
    rows = {}
    for m in re.finditer(r"defparam\s+%s\.INIT_RAM_([0-9A-Fa-f]{2})=(\d+)'h([0-9A-Fa-f]+);" % re.escape(name), vg):
        rows[int(m.group(1), 16)] = (int(m.group(2)), int(m.group(3), 16))
    w = int(re.search(r"defparam\s+%s\.BIT_WIDTH=(\d+);" % re.escape(name), vg).group(1))
    total, pos = 0, 0
    for r in range(64):
        n, v = rows.get(r, (288 if w == 36 else 256, 0))
        total |= v << pos
        pos += n
    return w, total


def module_text(vg, prefix):
    """Text of the first netlist module whose name starts with prefix."""
    for m in re.finditer(r"^module\s+(\S+?)\s*\(.*?^endmodule", vg, re.S | re.M):
        if m.group(1).startswith(prefix):
            return m.group(0)
    return ""


def main():
    vg_all = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    dump = {"it": {}, "str": {}, "font": {}}
    for line in open(sys.argv[2]):
        f = line.split()
        if len(f) == 3 and f[0] in dump:
            dump[f[0]][int(f[1])] = int(f[2], 16)
    if "--neg" in sys.argv:
        dump["it"][300] ^= 1 << 20
    ok = True
    for key, mod, inst, n, mask in (("it", "vu_screen", "it_rom_it_rom_0_0_s", 512, (1 << 33) - 1),
                                    ("str", "vu_screen", "str_rom_str_rom_0_0_s", 128, 0x3F),
                                    ("font", "font8x8", "rom_rom_0_0_s", 512, 0xFF)):
        vg = module_text(vg_all, mod)
        name, ad, do = pins(vg, inst)
        if name is None:
            print("%-4s: no ROM instance %s in the netlist" % (key, inst))
            ok = False
            continue
        w, bits = init_bits(vg, name)
        bad = [i for i in range(n) if ((bits >> (i * w)) & mask) != dump[key][i]]
        print("%-4s: %s, %s x %d, address pins %s; %d of %d entries differ%s"
              % (key, name, n, w, ",".join(ad), len(bad), n,
                 "" if not bad else " (first: %d, netlist %x, simulation %x)"
                 % (bad[0], (bits >> (bad[0] * w)) & mask, dump[key][bad[0]])))
        if bad:
            ok = False
    print("ROM: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
