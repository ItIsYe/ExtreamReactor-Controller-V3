#!/usr/bin/env python3
"""Prueft dass manifest_version nie sinkt (Rollback-Guard).

--no-bump-required   Fehler nur wenn Version kleiner als HEAD~1 wird.
"""
import sys, re, subprocess, argparse, os

def get_version(ref="HEAD"):
    try:
        src = subprocess.check_output(
            ["git", "show", f"{ref}:xreactor/release.lua"],
            stderr=subprocess.DEVNULL).decode()
        m = re.search(r'manifest_version\s*=\s*(\d+)', src)
        return int(m.group(1)) if m else None
    except:
        return None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-bump-required", action="store_true")
    parser.add_argument("--base", default=None, help="base git ref/sha to compare")
    parser.add_argument("--head", default=None, help="head git ref/sha to compare")
    args = parser.parse_args()

    head_ref = args.head or "HEAD"
    base_ref = args.base or "HEAD~1"
    cur = get_version(head_ref)
    prev = get_version(base_ref)

    if cur is None:
        print("WARN: cannot read current manifest_version")
        sys.exit(0)

    if prev is None:
        print(f"OK: first commit or no parent, version={cur}")
        sys.exit(0)

    if cur < prev:
        print(f"ERROR: version rollback detected: {prev} -> {cur}", file=sys.stderr)
        sys.exit(1)

    if not args.no_bump_required and cur == prev:
        print(f"WARN: version unchanged ({cur})")

    print(f"OK: version {prev} -> {cur}")

if __name__ == "__main__":
    main()
