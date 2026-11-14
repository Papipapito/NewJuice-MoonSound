import re, sys
src, out = sys.argv[1:3]
L = open(src, encoding='utf-8').read().split('\n')
decl = [l for l in L if re.match(r'^    T9990_[A-Z0-9_]+_IF +\w+\(\);', l)]
L = [l for l in L if l not in decl]
i = next(k for k, l in enumerate(L) if l.startswith('    logic CLK_MASTER_EN;'))
L[i:i] = decl
open(out, 'w', encoding='utf-8', newline='\n').write('\n'.join(L))
