#!/usr/bin/env python3
"""Choose the Tier 2a subset by where mobile risk actually is.

Tier 2a is the fast gate on every PR. What it is *for* is narrow: this fork
always sits on an upstream release tag, so every test in it already passes on a
desktop build. The only thing Tier 2a can catch is a regression introduced by
this fork -- the patch series, the build flags, or the platform underneath.

The list it replaces did not reflect that. It was 195 tests, of which 139 (71%)
were buffer, url, whatwg-url, path, querystring, string_decoder and util --
pure JS over V8 builtins, which no patch in the series touches -- and 26 (13%)
were anything to do with the platform boundary. Sixty-four buffer tests cannot
fail unless V8 itself is broken, and if V8 is broken the first five will say so.

So weight by blast radius instead, taken from patches/files.map:

    0006/0007  src/node.cc, node_credentials.cc  -> process, credentials, and
               everything downstream of SafeGetenv (os.tmpdir, TZ, NODE_PATH)
    0008       src/node_env_var.cc               -> worker environment
    0010       src/crypto/crypto_context.cc      -> tls, crypto
    0011       deps/uv                           -> fs, net, dgram, timers, os
    0012       deps/v8 trap handler              -> vm, wasm
    0013       deps/cares                        -> dns
    0019       WebAssembly polyfill              -> wasm, fetch

plus the platform integration an embedder actually leans on (sockets including
unix domain, http/http2, streams, zlib, workers), plus every fork-only
test-mobile-* since those gate patches directly.

Selection is deterministic: within a module the candidates are sorted and taken
at an even stride, so the sample spreads across the module rather than clustering
on whatever sorts first, and re-running with the same inputs gives the same list.

Usage:
    select-tier2a.py --budget 480        # seconds per platform, prints the list
    select-tier2a.py --explain           # show the per-module picture
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DURATIONS = os.path.join(ROOT, 'tools', 'mobile-test', 'tier2b-durations.tsv')
SUITES = ('parallel', 'sequential')

# module -> (weight, cap). Weight orders the fill; cap stops one module eating
# the budget. A module absent here is "no known mobile risk" and gets LOW.
RISK = {
    # libuv, the single largest patched dependency
    'fs': (10, 40), 'net': (10, 25), 'dgram': (10, 15), 'timers': (9, 12),
    'os': (9, 10), 'process': (9, 20),
    # crypto_context.cc + the system trust store
    'tls': (10, 25), 'crypto': (9, 30), 'https': (8, 10),
    # c-ares
    'dns': (10, 12),
    # v8 trap handler / jitless
    'vm': (8, 12), 'wasm': (10, 8),
    # env clone
    'worker': (9, 25),
    # what an embedder leans on
    'http': (7, 20), 'http2': (6, 15), 'stream': (7, 15), 'zlib': (7, 10),
    'module': (6, 10), 'async': (6, 10), 'child': (5, 5),
    # keep a token smoke of the pure-JS surface: enough to notice V8 being
    # broken, not 64 of them
    'buffer': (2, 6), 'url': (2, 4), 'whatwg': (2, 4), 'path': (2, 4),
    'querystring': (1, 2), 'string': (1, 2), 'util': (2, 4), 'events': (2, 4),
    'assert': (2, 3), 'eventtarget': (1, 2),
}
LOW = (1, 25)   # the '_other' bucket: broad but shallow


def module_of(name):
    """Second token of the test name, but only when it is a module we have a
    risk opinion about. Everything else lands in one bucket: the tail of the
    suite is ~150 distinct second-tokens (abort, als, arm, bad, c, ...), and
    treating each as a module lets the long tail win the round-robin and starve
    fs and net down to a handful."""
    parts = name.split('-')
    mod = parts[1] if len(parts) > 1 else name
    return mod if mod in RISK else '_other'


def runnable(arch):
    """Ask test.py what it would run, so this can never disagree with .status."""
    with tempfile.TemporaryDirectory() as tmp:
        names = os.path.join(tmp, 'n')
        shell = os.path.join(tmp, 's')
        with open(shell, 'w', encoding='utf-8') as handle:
            handle.write('#!/bin/sh\nfor a in "$@"; do case "$a" in /*.js|/*.mjs)'
                         ' echo "$a" >> "$NAMEFILE" ;; esac; done\nexit 0\n')
        os.chmod(shell, 0o755)
        subprocess.run([sys.executable, 'tools/test.py', '-j', '8', '--shell', shell,
                        '--arch', arch, *SUITES],
                       cwd=ROOT, env=dict(os.environ, NAMEFILE=names),
                       capture_output=True, check=False)
        out = set()
        for line in open(names, encoding='utf-8'):
            p = line.strip()
            if not p:
                continue
            suite = os.path.basename(os.path.dirname(p))
            if suite in SUITES:
                out.add(f'{suite}/{os.path.splitext(os.path.basename(p))[0]}')
        return out


def durations():
    table = {}
    if not os.path.exists(DURATIONS):
        return table
    for line in open(DURATIONS, encoding='utf-8'):
        if line.startswith('#') or not line.strip():
            continue
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 3:
            vals = [float(v) for v in parts[1:] if v not in ('', '-')]
            if vals:
                table[parts[0]] = max(vals)   # cost on the slower platform
    return table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--budget', type=float, default=480.0,
                        help='seconds of device time per platform')
    parser.add_argument('--explain', action='store_true')
    args = parser.parse_args()

    # Both platforms must be able to run it: a one-platform entry makes the gate
    # asymmetric, and the whole point is that a regression fails the same named
    # test on both.
    both = runnable('android') & runnable('ios')
    dur = durations()
    median = sorted(dur.values())[len(dur) // 2] if dur else 1.0

    must = sorted(n for n in both if n.split('/')[-1].startswith('test-mobile-'))
    # Unix domain sockets: an embedder-critical surface with a silent failure
    # mode (a path that grew too long), and nothing else in the suite covers it.
    must += sorted(n for n in both
                   if re.search(r'unix-socket|pipe-(address|stream|writev)|'
                                r'net-server-listen-path|net-pingpong', n.split('/')[-1]))

    chosen = list(dict.fromkeys(must))
    spent = sum(dur.get(n.split('/')[-1], median) for n in chosen)

    bymod = {}
    for n in both:
        if n in chosen:
            continue
        bymod.setdefault(module_of(n.split('/')[-1]), []).append(n)

    # Pre-compute each module's candidate order once: an even stride, so the
    # sample spans the module rather than clustering on whatever sorts first
    # (all the -abort- tests, say).
    order = {}
    for mod, cands in bymod.items():
        cands = sorted(cands)
        cap = min(RISK.get(mod, LOW)[1], len(cands))
        step = max(1, len(cands) // cap) if cap else 1
        order[mod] = cands[::step][:cap]

    # Fill in rounds rather than draining the highest-weight module first.
    # Greedy-by-weight spends the whole budget on fs/net/tls and leaves vm, wasm,
    # zlib and the pure-JS smoke with nothing — breadth matters here, because a
    # module with no test at all is a module where a regression is invisible.
    # Weight still decides how fast each module fills and who wins the last
    # seconds of budget.
    picked = {}
    mods = sorted(order, key=lambda m: (-RISK.get(m, LOW)[0], m))
    idx = {m: 0 for m in mods}
    progress = True
    while progress and spent < args.budget:
        progress = False
        for mod in mods:
            weight = RISK.get(mod, LOW)[0]
            for _ in range(max(1, weight // 3)):
                i = idx[mod]
                if i >= len(order[mod]):
                    break
                n = order[mod][i]
                cost = dur.get(n.split('/')[-1], median)
                if spent + cost > args.budget:
                    continue
                idx[mod] += 1
                chosen.append(n)
                spent += cost
                picked[mod] = picked.get(mod, 0) + 1
                progress = True

    if args.explain:
        print(f'{len(chosen)} tests, ~{spent/60:.1f} min per platform '
              f'(budget {args.budget/60:.1f})')
        print(f'  must-have (fork-only + unix sockets): {len(must)}')
        for mod in sorted(picked, key=lambda m: (-RISK.get(m, LOW)[0], m)):
            w = RISK.get(mod, LOW)[0]
            print(f'  risk {w:2d}  {mod:<14} {picked[mod]:3d}')
        return

    for n in sorted(chosen):
        print(n)


if __name__ == '__main__':
    main()
