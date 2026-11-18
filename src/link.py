#!/usr/bin/env python3
"""Link one aarch64 relocatable object into a static executable."""
import struct
import sys

data = open(sys.argv[1], "rb").read()
out_path = sys.argv[2]
assert data[:4] == b"\x7fELF"
e_shoff, = struct.unpack_from("<Q", data, 40)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)

def shdr(i):
    o = e_shoff + i * e_shentsize
    return struct.unpack_from("<IIQQQQIIQQ", data, o)

shstr = shdr(e_shstrndx)
shstrtab = data[shstr[4]:shstr[4] + shstr[5]]

def nm(off):
    return shstrtab[off:shstrtab.find(b"\0", off)].decode()

secs = [shdr(i) for i in range(e_shnum)]
by = {nm(h[0]): (i, h) for i, h in enumerate(secs)}

def blob(name):
    h = by[name][1]
    return bytearray(data[h[4]:h[4] + h[5]])

text = blob(".text")
chunks = [(".text", text)]
for extra in (".rodata.cst8", ".rodata.cst16", ".rodata.str1.1"):
    if extra in by:
        raw = blob(extra)
        align = 16 if "cst16" in extra else (8 if "cst8" in extra else 1)
        chunks.append((extra, raw, align))

# rebuild chunk list uniformly
parts = [(".text", text, 16)]
for extra, align in ((".rodata.cst8", 8), (".rodata.cst16", 16), (".rodata.str1.1", 1)):
    if extra in by:
        parts.append((extra, blob(extra), align))

cursor = 0
placed = {}
buf = bytearray()
for name, raw, align in parts:
    if cursor % align:
        pad = align - (cursor % align)
        buf += b"\0" * pad
        cursor += pad
    placed[name] = cursor
    buf += raw
    cursor += len(raw)
if cursor % 16:
    pad = 16 - (cursor % 16)
    buf += b"\0" * pad
    cursor += pad
bss_off = cursor
bss_size = by[".bss"][1][5]
filesz_img = len(buf)
memsz_img = bss_off + bss_size

LOAD_OFF = 0x1000
BASE = 0x400000

symh = by[".symtab"][1]
symraw = data[symh[4]:symh[4] + symh[5]]
strh = by[".strtab"][1]
strtab = data[strh[4]:strh[4] + strh[5]]
syms = []
for i in range(0, len(symraw), symh[9]):
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", symraw, i)
    name = strtab[st_name:strtab.find(b"\0", st_name)].decode()
    syms.append((name, st_shndx, st_value))

shndx_to_name = {i: nm(h[0]) for i, h in enumerate(secs)}

def sym_addr(idx):
    name, shndx, value = syms[idx]
    if shndx == 0:
        raise SystemExit(f"undefined symbol {name}")
    sec = shndx_to_name[shndx]
    if sec == ".bss":
        return BASE + LOAD_OFF + bss_off + value
    if sec not in placed:
        raise SystemExit(f"{name} in {sec}")
    return BASE + LOAD_OFF + placed[sec] + value

def patch_imm(ins, bit, width, value):
    mask = (1 << width) - 1
    return (ins & ~(mask << bit)) | ((value & mask) << bit)

ADR = 275
ADD = 277
L32, L64, L128 = 285, 286, 299
CALL = 283
image = bytearray(buf)
rela = by[".rela.text"][1]
rel = data[rela[4]:rela[4] + rela[5]]
text_off = placed[".text"]
for j in range(0, rela[5], 24):
    r_off, r_info, r_add = struct.unpack_from("<QQq", rel, j)
    typ = r_info & 0xFFFFFFFF
    sym = r_info >> 32
    P = BASE + LOAD_OFF + text_off + r_off
    S = sym_addr(sym)
    A = r_add
    at = text_off + r_off
    ins = struct.unpack_from("<I", image, at)[0]
    if typ == ADR:
        imm = (((S + A) & ~0xFFF) - (P & ~0xFFF)) >> 12
        ins = patch_imm(ins, 5, 19, imm >> 2)
        ins = patch_imm(ins, 29, 2, imm)
    elif typ == ADD:
        ins = patch_imm(ins, 10, 12, (S + A) & 0xFFF)
    elif typ in (L32, L64, L128):
        shift = {L32: 2, L64: 3, L128: 4}[typ]
        ins = patch_imm(ins, 10, 12, ((S + A) & 0xFFF) >> shift)
    elif typ == CALL:
        imm = ((S + A) - P) >> 2
        ins = patch_imm(ins, 0, 26, imm)
    else:
        raise SystemExit(f"unknown reloc {typ}")
    struct.pack_into("<I", image, at, ins)

entry = None
for name, shndx, value in syms:
    if name == "_start":
        entry = sym_addr(syms.index((name, shndx, value)))
if entry is None:
    raise SystemExit("no _start")

def phdr(typ, flags, off, va, fsz, msz, align):
    return struct.pack("<IIQQQQQQ", typ, flags, off, va, va, fsz, msz, align)

eh = struct.pack(
    "<16sHHIQQQIHHHHHH",
    b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 8,
    2, 183, 1, entry, 64, 0, 0, 64, 56, 1, 0, 0, 0,
)
hdr = eh + phdr(1, 7, 0, BASE, LOAD_OFF + filesz_img, LOAD_OFF + memsz_img, 0x1000)
file_bytes = bytearray(LOAD_OFF) + image
file_bytes[:len(hdr)] = hdr
open(out_path, "wb").write(file_bytes)
print(f"wrote {out_path} entry {entry:#x} file {len(file_bytes)}")
