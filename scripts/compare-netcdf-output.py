#!/usr/bin/env python3
"""
compare-netcdf-output.py

Binary-compare corresponding NetCDF files in two directories, variable by
variable. Useful for validating that a code change (e.g. adding OpenACC
directives that should be inert) produces bitwise-identical output.

Usage:
    python3 compare-netcdf-output.py <dir_a> <dir_b>
    python3 compare-netcdf-output.py <dir_a> <dir_b> --pattern "history.*.nc"
    python3 compare-netcdf-output.py <dir_a> <dir_b> --tolerance 0  (bitwise)
    python3 compare-netcdf-output.py <dir_a> <dir_b> --tolerance 1e-12

Exit codes:
    0 = all files match within tolerance
    1 = differences found
    2 = missing files or other structural issues

Requires: netCDF4, numpy
"""

import argparse
import fnmatch
import hashlib
import sys
from pathlib import Path

import netCDF4
import numpy as np


def variables_match(ds_a, ds_b, var_name, tolerance):
    """Return (matches, summary_str). matches is bool."""
    v_a = ds_a.variables[var_name]
    v_b = ds_b.variables[var_name]

    if v_a.shape != v_b.shape:
        return False, f"shape mismatch: {v_a.shape} vs {v_b.shape}"

    a = v_a[:]
    b = v_b[:]

    # Handle masked arrays by filling
    if np.ma.isMaskedArray(a):
        a = a.filled(np.nan)
    if np.ma.isMaskedArray(b):
        b = b.filled(np.nan)

    if a.dtype != b.dtype:
        return False, f"dtype mismatch: {a.dtype} vs {b.dtype}"

    if tolerance == 0:
        # equal_nan only valid for float types
        if np.issubdtype(a.dtype, np.floating):
            if np.array_equal(a, b, equal_nan=True):
                return True, "bitwise identical"
        else:
            if np.array_equal(a, b):
                return True, "bitwise identical"
        try:
            diff_count = int(np.sum(a != b))
            return False, f"bitwise differs ({diff_count} elements)"
        except Exception:
            return False, "bitwise differs (can't count elements)"

    # Approximate comparison for floats
    if np.issubdtype(a.dtype, np.floating):
        diff = np.abs(a - b)
        max_diff = float(np.nanmax(diff))
        if max_diff <= tolerance:
            return True, f"max_abs_diff={max_diff:.3e} (<= {tolerance})"
        mean_diff = float(np.nanmean(diff))
        diff_count = int(np.sum(diff > tolerance))
        return False, (
            f"max_abs_diff={max_diff:.3e} mean={mean_diff:.3e} "
            f"elements_over_tol={diff_count}/{a.size}"
        )

    # Integers: must be exact
    if np.array_equal(a, b):
        return True, "exact integer match"
    return False, "integer mismatch"


def compare_files(path_a, path_b, tolerance):
    """Return (all_match, report_lines, var_count, diff_var_count)."""
    lines = []
    try:
        ds_a = netCDF4.Dataset(path_a, "r")
        ds_b = netCDF4.Dataset(path_b, "r")
    except Exception as e:
        return False, [f"open failed: {e}"], 0, 0

    vars_a = set(ds_a.variables)
    vars_b = set(ds_b.variables)
    only_a = vars_a - vars_b
    only_b = vars_b - vars_a
    common = sorted(vars_a & vars_b)

    if only_a:
        lines.append(f"  variables only in A: {sorted(only_a)}")
    if only_b:
        lines.append(f"  variables only in B: {sorted(only_b)}")

    diff_vars = []
    for vname in common:
        matches, summary = variables_match(ds_a, ds_b, vname, tolerance)
        if not matches:
            diff_vars.append((vname, summary))

    if diff_vars:
        lines.append(f"  {len(diff_vars)} of {len(common)} variables differ:")
        for vname, summary in diff_vars[:10]:
            lines.append(f"    {vname}: {summary}")
        if len(diff_vars) > 10:
            lines.append(f"    ... and {len(diff_vars) - 10} more")
    else:
        lines.append(f"  all {len(common)} shared variables match")

    ds_a.close()
    ds_b.close()

    all_match = not diff_vars and not only_a and not only_b
    return all_match, lines, len(common), len(diff_vars)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dir_a", type=Path)
    parser.add_argument("dir_b", type=Path)
    parser.add_argument(
        "--pattern",
        default="*.nc",
        help="glob pattern for files to compare (default: *.nc)",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.0,
        help="absolute tolerance for float comparison (default 0 = bitwise)",
    )
    args = parser.parse_args()

    if not args.dir_a.is_dir():
        print(f"error: {args.dir_a} is not a directory", file=sys.stderr)
        sys.exit(2)
    if not args.dir_b.is_dir():
        print(f"error: {args.dir_b} is not a directory", file=sys.stderr)
        sys.exit(2)

    files_a = {p.name for p in args.dir_a.iterdir() if fnmatch.fnmatch(p.name, args.pattern)}
    files_b = {p.name for p in args.dir_b.iterdir() if fnmatch.fnmatch(p.name, args.pattern)}

    only_a = sorted(files_a - files_b)
    only_b = sorted(files_b - files_a)
    common = sorted(files_a & files_b)

    if only_a:
        print(f"files only in {args.dir_a}: {only_a}")
    if only_b:
        print(f"files only in {args.dir_b}: {only_b}")
    if not common:
        print("no common files to compare")
        sys.exit(2)

    print(f"comparing {len(common)} files (tolerance={args.tolerance})")
    print()

    total_match = True
    per_file_stats = []
    for fname in common:
        path_a = args.dir_a / fname
        path_b = args.dir_b / fname
        print(f"{fname}:")
        all_match, lines, n_vars, n_diff = compare_files(path_a, path_b, args.tolerance)
        for line in lines:
            print(line)
        per_file_stats.append((fname, all_match, n_vars, n_diff))
        total_match = total_match and all_match and not only_a and not only_b
        print()

    print("summary:")
    for fname, match, n_vars, n_diff in per_file_stats:
        status = "MATCH" if match else f"DIFF ({n_diff}/{n_vars} vars)"
        print(f"  {fname}: {status}")
    print()
    if total_match:
        print("OVERALL: all files match")
        sys.exit(0)
    print("OVERALL: differences found")
    sys.exit(1)


if __name__ == "__main__":
    main()
