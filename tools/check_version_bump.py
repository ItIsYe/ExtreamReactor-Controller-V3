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
    args = parser.parse_args()

    cur = get_version("HEAD")
    prev = get_version("HEAD~1")

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
