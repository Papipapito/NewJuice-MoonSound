import re, sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
t, n = re.subn(r'union \{\s*logic \[37:0\] chr;\s*logic \[24:0\] line;\s*logic \[2:0\] srch;\s*\} work;', 'reg [37:0] work;', t)
assert n == 1, n
t, m = re.subn(r'\bwork\.(chr|line|srch)\b', 'work', t)
print('union -> reg [37:0]; %d refs' % m)
open(p, 'w', encoding='utf-8', newline='\n').write(t)
