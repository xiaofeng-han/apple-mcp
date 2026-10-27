# Print the protobuf field structure (numbers / wire types / lengths) of a Notes body, never the text.
import sqlite3, gzip, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute("select ZDATA from ZICNOTEDATA where ZDATA is not null and length(ZDATA) between 400 and 3000 limit 1").fetchone()
raw = row[0]
print("gzip magic:", raw[:2].hex())
buf = gzip.decompress(raw)
def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s; s += 7
        if c < 0x80: return r, i
def walk(b, depth, maxdepth=5):
    i = 0; out = []
    try:
        while i < len(b):
            key, i = varint(b, i); f, wt = key >> 3, key & 7
            if wt == 0: v, i = varint(b, i); out.append((f, 'varint', v))
            elif wt == 2:
                n, i = varint(b, i); sub = b[i:i+n]; i += n
                inner = walk(sub, depth+1) if depth < maxdepth else None
                out.append((f, f'len={n}', inner))
            elif wt == 5: i += 4; out.append((f, 'fixed32', None))
            elif wt == 1: i += 8; out.append((f, 'fixed64', None))
            else: return None
        return out
    except Exception:
        return None
def show(tree, ind=0, seen=None):
    agg = {}
    for f, t, inner in tree:
        k = (f, t.split('=')[0])
        agg.setdefault(k, []).append((t, inner))
    for (f, t), items in agg.items():
        sample = items[0]
        tag = 'varint' if t == 'varint' else ('bytes/msg' if t == 'len' else t)
        print('  ' * ind + f'field {f} [{tag}] x{len(items)}' + (f' e.g. {sample[0]}' if t == 'len' else ''))
        if t == 'len' and sample[1] and ind < 4:
            show(sample[1], ind + 1)
show(walk(buf, 0))
