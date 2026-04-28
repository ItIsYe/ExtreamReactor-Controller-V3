#!/usr/bin/env python3
import argparse
import importlib.util
import re
import shutil
import subprocess
from pathlib import Path

LuaRuntime = None
if importlib.util.find_spec("lupa") is not None:
    from lupa import LuaRuntime

TOKEN_RE = re.compile(r"\.{3}|==|~=|<=|>=|[A-Za-z_][A-Za-z0-9_]*|\n|.")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
KEYWORDS = {"and","break","do","else","elseif","end","false","for","function","goto","if","in","local","nil","not","or","repeat","return","then","true","until","while"}


def strip_strings_comments(src: str) -> str:
    out=[]; i=0; n=len(src)
    while i<n:
        c=src[i]; n1=src[i+1] if i+1<n else ''
        if c=='-' and n1=='-':
            if i+3<n and src[i+2]=='[' and src[i+3]=='[':
                i+=4
                while i+1<n and not(src[i]==']' and src[i+1]==']'):
                    out.append('\n' if src[i]=='\n' else ' '); i+=1
                i+=2
            else:
                while i<n and src[i] != '\n': i+=1
            continue
        if c in ('"',"'"):
            q=c; out.append(' '); i+=1
            while i<n:
                if src[i]=='\\': i+=2; continue
                if src[i]==q: i+=1; break
                out.append('\n' if src[i]=='\n' else ' '); i+=1
            continue
        out.append(c); i+=1
    return ''.join(out)


def tokens(src: str):
    s=strip_strings_comments(src)
    line=1; arr=[]
    for m in TOKEN_RE.finditer(s):
        t=m.group(0)
        if t=='\n': line+=1; continue
        if t.isspace(): continue
        arr.append((t,line))
    return arr


def count_local_names(toks, i):
    n=0; j=i
    while j < len(toks):
        t=toks[j][0]
        if t in ('=', ';'): break
        if t == ',': j+=1; continue
        if IDENT_RE.match(t) and t not in KEYWORDS:
            n += 1
            j += 1
            continue
        break
    return n


def analyze(path: Path):
    source = path.read_text(encoding='utf-8')
    toks=tokens(source)
    block_stack=[]
    fn_stack=[]  # dict(line, locals)
    chunk_locals=0
    fn_reports=[]

    i=0
    while i < len(toks):
        tok,line=toks[i]
        in_fn = len(fn_stack) > 0
        if tok=='local':
            nxt=toks[i+1][0] if i+1<len(toks) else ''
            add = 1 if nxt=='function' else count_local_names(toks, i+1)
            if in_fn:
                fn_stack[-1]['locals'] += add
            else:
                chunk_locals += add
        elif tok=='for':
            add = count_local_names(toks, i+1)
            if in_fn:
                fn_stack[-1]['locals'] += add
            else:
                chunk_locals += add
        elif tok=='function':
            # count params as locals
            params=0; j=i+1
            while j<len(toks) and toks[j][0] != '(': j+=1
            j += 1
            while j<len(toks) and toks[j][0] != ')':
                t=toks[j][0]
                if (IDENT_RE.match(t) and t not in KEYWORDS) or t=='...': params += 1
                j += 1
            fn_stack.append({'line': line, 'locals': params})
            block_stack.append('function')
        elif tok in ('then','do'):
            block_stack.append('block')
        elif tok=='repeat':
            block_stack.append('repeat')
        elif tok=='until':
            while block_stack:
                b=block_stack.pop()
                if b=='repeat':
                    break
        elif tok=='end':
            if block_stack:
                b=block_stack.pop()
                if b=='function' and fn_stack:
                    fn_reports.append(fn_stack.pop())
        i += 1

    # Any unclosed functions are considered too risky.
    for frame in fn_stack:
        fn_reports.append(frame)
    return chunk_locals, fn_reports


def real_parse(path: Path, parser_mode: str):
    luajit = shutil.which("luajit")
    if luajit and parser_mode in ("any", "luajit"):
        proc = subprocess.run([luajit, "-b", str(path), "/dev/null"], capture_output=True, text=True)
        if proc.returncode == 0:
            return True, f"luajit:{luajit}", ""
        return False, f"luajit:{luajit}", (proc.stderr or proc.stdout or "").strip()

    lua = shutil.which("lua") or shutil.which("lua5.1") or shutil.which("lua5.2") or shutil.which("lua5.3") or shutil.which("lua5.4")
    if lua and parser_mode in ("any", "lua"):
        proc = subprocess.run([lua, "-e", "assert(loadfile(arg[1]))", str(path)], capture_output=True, text=True)
        if proc.returncode == 0:
            return True, f"lua:{lua}", ""
        return False, f"lua:{lua}", (proc.stderr or proc.stdout or "").strip()

    luac = shutil.which("luac") or shutil.which("luac5.1") or shutil.which("luac5.2") or shutil.which("luac5.3") or shutil.which("luac5.4")
    if luac and parser_mode in ("any", "luac"):
        proc = subprocess.run([luac, "-p", str(path)], capture_output=True, text=True)
        if proc.returncode == 0:
            return True, f"luac:{luac}", ""
        return False, f"luac:{luac}", (proc.stderr or proc.stdout or "").strip()

    if LuaRuntime is not None:
        if parser_mode == "luajit":
            return None, "none", "luajit parser requested but unavailable"
        if parser_mode == "luac":
            return None, "none", "luac parser requested but unavailable"
        try:
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.execute(f"assert(loadfile({path.as_posix()!r}))")
            return True, "lupa:loadfile", ""
        except Exception as exc:
            return False, "lupa:loadfile", str(exc)

    if parser_mode == "luajit":
        return None, "none", "luajit parser unavailable"
    if parser_mode == "lua":
        return None, "none", "lua parser unavailable"
    if parser_mode == "luac":
        return None, "none", "luac parser unavailable"
    return None, "none", "no luajit/lua/luac/lupa parser available"


def main():
    ap=argparse.ArgumentParser(description='Conservative CC parser guard for local-variable pressure')
    ap.add_argument('--file', action='append', dest='files', default=[])
    ap.add_argument('--chunk-limit', type=int, default=190)
    ap.add_argument('--function-limit', type=int, default=170)
    ap.add_argument('--max-bytes', type=int, default=120000)
    ap.add_argument('--require-real-parse', action='store_true', help='Require actual Lua parser success (luac or lupa.load)')
    ap.add_argument('--parser-mode', choices=['any', 'luajit', 'lua', 'luac'], default='any', help='Choose parser requirement for real parse checks')
    args=ap.parse_args()

    files=args.files or ['xreactor/nodes/rt/main.lua']
    failures=[]
    for f in files:
        p=Path(f)
        size=p.stat().st_size
        chunk_locals, funcs=analyze(p)
        max_fn=max((x['locals'] for x in funcs), default=0)
        print(f"{p}: bytes={size} chunk_locals={chunk_locals} max_function_locals={max_fn}")
        if size > args.max_bytes:
            failures.append(f"{p}: file size {size} > {args.max_bytes}")
        if chunk_locals > args.chunk_limit:
            failures.append(f"{p}: top-level locals {chunk_locals} > {args.chunk_limit}")
        for fn in funcs:
            if fn['locals'] > args.function_limit:
                failures.append(f"{p}: function at line {fn['line']} locals {fn['locals']} > {args.function_limit}")
        if args.require_real_parse:
            ok, parser_used, err = real_parse(p, args.parser_mode)
            if ok is None:
                failures.append(f"{p}: real parse unavailable ({err})")
            elif not ok:
                failures.append(f"{p}: real parse failed via {parser_used}: {err}")
            else:
                print(f"{p}: real_parse=ok parser={parser_used}")

    if failures:
        print('CC parse guard failed:')
        for f in failures:
            print(f'- {f}')
        raise SystemExit(1)

if __name__ == '__main__':
    main()
