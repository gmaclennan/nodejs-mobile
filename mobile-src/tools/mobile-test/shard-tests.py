#!/usr/bin/env python3
"""Split the device test suite into shards that take roughly equal time.

`test.py --run=i,N` shards round-robin over a sorted list, which balances by
*count*. Test durations are not uniform — the median is about a second and the
tail runs to half a minute — so a round-robin split drifts badly: a measured
4-way split of test/parallel came out 18.8, 19.3, 33.5 and 20.3 minutes, against
a 19.3-minute ideal. The whole job waits on the slowest shard, so that tail is
pure wasted wall-clock.

This assigns tests to shards longest-first, each to whichever shard is currently
lightest (LPT), which for this distribution lands every shard within a few
percent of the mean.

Two inputs, and the awkward part is that both have to be right:

  * which tests will actually run — taken from test.py itself, by running the
    suite against a shell that only echoes the filename. That respects every
    .status skip and every condition in it, so this cannot drift from the real
    run the way a reimplementation of the status parser would.
  * how long each takes — tier2b-durations.tsv, recorded from a real sweep.
    Anything absent (a test upstream added since) gets the median, so a stale
    table degrades the balance slightly instead of dropping tests.

Usage:
    shard-tests.py --arch android --shards 4 --shard 2      # emit one shard
    shard-tests.py --record android=a.log,b.log --arch ios  # refresh the table
"""

import argparse
import os
import re
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TABLE = os.path.join(ROOT, 'tools', 'mobile-test', 'tier2b-durations.tsv')
SUITES = ('parallel', 'sequential')
PLATFORMS = ('android', 'ios')


def load_table():
    """name -> {platform: seconds}."""
    out = {}
    if not os.path.exists(TABLE):
        return out
    with open(TABLE, encoding='utf-8') as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) != 3:
                continue
            name, android, ios = parts
            out[name] = {}
            for plat, raw in (('android', android), ('ios', ios)):
                if raw not in ('', '-'):
                    out[name][plat] = float(raw)
    return out


def write_table(durations):
    with open(TABLE, 'w', encoding='utf-8') as handle:
        handle.write('# Per-test wall-clock in seconds, measured on a device, used by\n')
        handle.write('# shard-tests.py to balance Tier 2b shards. Columns: test, android, ios.\n')
        handle.write('# "-" means never measured on that platform (it gets the median).\n')
        handle.write('# Refresh from a full sweep:  shard-tests.py --record android=<logs>\n')
        for name in sorted(durations):
            row = durations[name]
            handle.write('%s\t%s\t%s\n' % (
                name,
                ('%.1f' % row['android']) if 'android' in row else '-',
                ('%.1f' % row['ios']) if 'ios' in row else '-'))


def durations_from_log(path):
    """test.py prints one progress line per completed test, stamped with elapsed
    time; the gap between consecutive lines is that test's wall-clock."""
    seen = {}
    prev = None
    with open(path, encoding='utf-8', errors='ignore') as handle:
        text = handle.read().replace('\r', '\n')
    for line in text.split('\n'):
        match = re.match(r'\[(\d+):(\d+)\|[^\]]*\]: release ([a-z0-9._-]+)', line)
        if not match:
            continue
        stamp = int(match.group(1)) * 60 + int(match.group(2))
        name = match.group(3)
        if prev is not None:
            delta = stamp - prev[0]
            # A negative gap means a new log; an implausible one means the run
            # stalled on something other than the test (device wedge, retry).
            if 0 <= delta < 300:
                seen[prev[1]] = float(delta)
        prev = (stamp, name)
    return seen


def runnable_tests(arch):
    """Ask test.py which tests it would run, via a shell that only names them."""
    with tempfile.TemporaryDirectory() as tmp:
        names = os.path.join(tmp, 'names')
        shell = os.path.join(tmp, 'name-shell')
        with open(shell, 'w', encoding='utf-8') as handle:
            handle.write('#!/bin/sh\n'
                         'for a in "$@"; do case "$a" in /*.js|/*.mjs)'
                         ' echo "$a" >> "$NAMEFILE" ;; esac; done\nexit 0\n')
        os.chmod(shell, 0o755)
        env = dict(os.environ, NAMEFILE=names)
        subprocess.run(
            [sys.executable, 'tools/test.py', '-j', '8', '--shell', shell,
             '--arch', arch, *SUITES],
            cwd=ROOT, env=env, capture_output=True, check=False)
        if not os.path.exists(names):
            raise SystemExit(f'could not enumerate tests for {arch}')
        out = set()
        for line in open(names, encoding='utf-8'):
            path = line.strip()
            if not path:
                continue
            suite = os.path.basename(os.path.dirname(path))
            stem = os.path.splitext(os.path.basename(path))[0]
            if suite in SUITES:
                out.add(f'{suite}/{stem}')
        return sorted(out)


def partition(tests, weights, shards):
    """Longest-processing-time first: each test to the lightest shard so far."""
    bins = [[] for _ in range(shards)]
    load = [0.0] * shards
    # Sort by weight desc, then name, so the split is identical run to run.
    for name in sorted(tests, key=lambda n: (-weights[n], n)):
        i = load.index(min(load))
        bins[i].append(name)
        load[i] += weights[name]
    return bins, load


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--arch', choices=PLATFORMS, required=True)
    parser.add_argument('--shards', type=int, default=4)
    parser.add_argument('--shard', type=int)
    parser.add_argument('--record', metavar='PLAT=log[,log...]',
                        help='fold sweep logs into the duration table and exit')
    parser.add_argument('--summary', action='store_true',
                        help='print the projected balance instead of a shard')
    args = parser.parse_args()

    table = load_table()

    if args.record:
        plat, _, logs = args.record.partition('=')
        if plat not in PLATFORMS:
            raise SystemExit(f'--record needs one of {PLATFORMS}')
        merged = {}
        for path in logs.split(','):
            merged.update(durations_from_log(path))
        for name, seconds in merged.items():
            table.setdefault(name, {})[plat] = seconds
        write_table(table)
        print(f'recorded {len(merged)} {plat} durations into {os.path.relpath(TABLE, ROOT)}')
        return

    tests = runnable_tests(args.arch)
    known = [row[args.arch] for row in table.values() if args.arch in row]
    median = statistics.median(known) if known else 1.0

    weights = {}
    for name in tests:
        stem = name.split('/')[-1]
        row = table.get(stem, {})
        weights[name] = row.get(args.arch, median)

    bins, load = partition(tests, weights, args.shards)

    if args.summary or args.shard is None:
        total = sum(load)
        print(f'{args.arch}: {len(tests)} tests, {total/60:.1f} min total, '
              f'{args.shards} shards')
        for i, secs in enumerate(load):
            print(f'  shard {i}: {len(bins[i]):5d} tests  {secs/60:5.1f} min')
        print(f'  spread: {(max(load)-min(load))/60:.1f} min '
              f'({100*(max(load)-min(load))/(sum(load)/len(load)):.1f}% of mean)')
        return

    for name in sorted(bins[args.shard]):
        print(name)


if __name__ == '__main__':
    main()
