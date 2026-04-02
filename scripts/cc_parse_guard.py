#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

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


def main():
    ap=argparse.ArgumentParser(description='Conservative CC parser guard for local-variable pressure')
    ap.add_argument('--file', action='append', dest='files', default=[])
    ap.add_argument('--chunk-limit', type=int, default=190)
    ap.add_argument('--function-limit', type=int, default=170)
    ap.add_argument('--max-bytes', type=int, default=120000)
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

    if failures:
        print('CC parse guard failed:')
        for f in failures:
            print(f'- {f}')
        raise SystemExit(1)

if __name__ == '__main__':
    main()
