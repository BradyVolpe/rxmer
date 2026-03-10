#!/usr/bin/env python3
"""
visualize_rxmer.py — DOCSIS 3.1 RxMER Per-Subcarrier Data Visualizer

Copyright (c) 2017-2026 Brady Volpe, Volpe Firm — volpefirm.com
Licensed under the Apache License, Version 2.0

Parses the binary RxMER data file produced by a DOCSIS 3.1 cable modem
(via the DOCS-PNM-MIB TFTP upload mechanism) and generates a plot of
RxMER (dB) per subcarrier index.

File Format
-----------
The PNM binary file header follows CM-SP-CM-OSSIv3.1 §PNM (CableLabs):

  Offset  Length  Field
  ------  ------  -----
  0       4       File type ID: 0x504E4D05  (PNM\x05 = RxMER per subcarrier)
  4       4       Capture time (Unix epoch, uint32 big-endian)
  8       1       Channel ID (uint8)
  9       6       CM MAC address (6 bytes)
  15      4       First active subcarrier index (uint32 big-endian)
  19      4       Last active subcarrier index (uint32 big-endian)
  23      4       Number of subcarrier RxMER values (uint32 big-endian)
  27      N*2     RxMER data: N × uint16 big-endian, units = 1/4 dB
                  A value of 0xFFFF indicates a pilot or excluded subcarrier.

The RxMER value in dB = raw_value / 4.0 (quarter-dB resolution).

Notes:
  - The file type ID 0x504E4D05 is specific to RxMER per subcarrier.
    Other PNM file types use different IDs (e.g., 0x504E4D09 for spectrum
    analysis). This parser validates the file type before proceeding.
  - The exact header layout above is consistent with commonly deployed CM
    firmware implementing CM-OSSIv3.1. Some vendors may use a slightly
    different header; if parsing fails, use --raw to skip header validation
    and attempt raw uint16 interpretation.
  - Subcarrier spacing for DOCSIS 3.1 OFDM: 25 kHz or 50 kHz.
    A 192 MHz channel at 25 kHz spacing has up to 7680 subcarriers.
    Excluded and pilot subcarriers are reported as 0xFFFF.

References:
  CM-SP-CM-OSSIv3.1 — CableLabs
  CM-SP-PHYv3.1      — CableLabs (subcarrier spacing, channel structure)
  SCTE 285           — DOCSIS 3.1 RxMER PNM Test Validation

Usage:
    python3 visualize_rxmer.py [options] <rxmer_file>

Examples:
    python3 visualize_rxmer.py RxMerData
    python3 visualize_rxmer.py --threshold 30 --output rxmer_plot.png RxMerData
    python3 visualize_rxmer.py --raw RxMerData           # skip header, raw uint16
    python3 visualize_rxmer.py --spacing 50 RxMerData    # 50 kHz subcarrier spacing
"""

import argparse
import logging
import os
import struct
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Optional matplotlib import — give a clear error if not installed
# ---------------------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")   # Non-interactive backend; safe in headless environments
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    level=logging.INFO,
)
logger = logging.getLogger("visualize_rxmer")

# PNM file type ID for RxMER per subcarrier
PNM_FILE_TYPE_RXMER = 0x504E4D05

# Sentinel value indicating pilot/excluded subcarrier
EXCLUDED_SENTINEL = 0xFFFF

# Header struct: file_type(4) + capture_time(4) + channel_id(1) + mac(6) +
#                first_sc(4) + last_sc(4) + num_sc(4) = 27 bytes
HEADER_FORMAT = ">I I B 6s I I I"
HEADER_SIZE   = struct.calcsize(HEADER_FORMAT)  # 27 bytes


def parse_header(data: bytes) -> dict:
    """
    Parse the PNM RxMER binary file header.
    Returns a dict with parsed fields, or raises ValueError on format mismatch.
    """
    if len(data) < HEADER_SIZE:
        raise ValueError(
            f"File too short for PNM header: got {len(data)} bytes, need {HEADER_SIZE}."
        )

    (file_type, capture_time, channel_id,
     mac_bytes, first_sc, last_sc, num_sc) = struct.unpack_from(HEADER_FORMAT, data, 0)

    if file_type != PNM_FILE_TYPE_RXMER:
        raise ValueError(
            f"Unexpected PNM file type: 0x{file_type:08X} "
            f"(expected 0x{PNM_FILE_TYPE_RXMER:08X} for RxMER per subcarrier).\n"
            "  Use --raw to attempt parsing without header validation."
        )

    mac_str = ":".join(f"{b:02X}" for b in mac_bytes)

    try:
        ts = datetime.fromtimestamp(capture_time, tz=timezone.utc).isoformat()
    except (OSError, OverflowError, ValueError):
        ts = f"<invalid timestamp: {capture_time}>"

    return {
        "file_type":    f"0x{file_type:08X}",
        "capture_time": ts,
        "channel_id":   channel_id,
        "cm_mac":       mac_str,
        "first_sc":     first_sc,
        "last_sc":      last_sc,
        "num_sc":       num_sc,
    }


def parse_rxmer_values(data: bytes, header: dict) -> tuple[list[int], list[float]]:
    """
    Parse the RxMER per-subcarrier values from the binary payload.

    Returns:
        (subcarrier_indices, rxmer_db_values)
        Excluded subcarriers (sentinel 0xFFFF) are omitted.
    """
    num_sc    = header["num_sc"]
    first_sc  = header["first_sc"]
    offset    = HEADER_SIZE
    expected_bytes = num_sc * 2

    if len(data) < offset + expected_bytes:
        actual = len(data) - offset
        logger.warning(
            "File contains %d RxMER bytes, expected %d (%d subcarriers). "
            "Parsing available data.",
            actual, expected_bytes, num_sc
        )
        num_sc = actual // 2

    raw_values = struct.unpack_from(f">{num_sc}H", data, offset)

    indices = []
    rxmer_db = []
    for i, raw in enumerate(raw_values):
        if raw == EXCLUDED_SENTINEL:
            continue   # Pilot tone or excluded subcarrier
        indices.append(first_sc + i)
        rxmer_db.append(raw / 4.0)    # Quarter-dB resolution

    return indices, rxmer_db


def parse_raw_uint16(data: bytes) -> tuple[list[int], list[float]]:
    """
    Fallback parser: interpret the entire file as packed uint16 big-endian values.
    Skips the 0xFFFF sentinel. Use when the header does not match.
    """
    num_values = len(data) // 2
    raw_values = struct.unpack_from(f">{num_values}H", data, 0)

    indices  = []
    rxmer_db = []
    for i, raw in enumerate(raw_values):
        if raw == EXCLUDED_SENTINEL:
            continue
        indices.append(i)
        rxmer_db.append(raw / 4.0)

    logger.warning("Raw mode: parsed %d uint16 values (%d non-excluded).",
                   num_values, len(indices))
    return indices, rxmer_db


def print_stats(indices: list[int], rxmer_db: list[float], spacing_khz: int):
    """Print summary statistics for the RxMER dataset."""
    if not rxmer_db:
        logger.warning("No valid RxMER values to summarize.")
        return

    n          = len(rxmer_db)
    mean_val   = sum(rxmer_db) / n
    min_val    = min(rxmer_db)
    max_val    = max(rxmer_db)
    min_idx    = indices[rxmer_db.index(min_val)]
    max_idx    = indices[rxmer_db.index(max_val)]
    below_30   = sum(1 for v in rxmer_db if v < 30.0)
    below_25   = sum(1 for v in rxmer_db if v < 25.0)

    print("")
    print("RxMER Summary Statistics")
    print("-" * 40)
    print(f"  Active subcarriers:  {n}")
    print(f"  Subcarrier spacing:  {spacing_khz} kHz")
    print(f"  Mean RxMER:          {mean_val:.2f} dB")
    print(f"  Min  RxMER:          {min_val:.2f} dB  (subcarrier {min_idx})")
    print(f"  Max  RxMER:          {max_val:.2f} dB  (subcarrier {max_idx})")
    print(f"  Subcarriers < 30 dB: {below_30}  ({100*below_30/n:.1f}%)")
    print(f"  Subcarriers < 25 dB: {below_25}  ({100*below_25/n:.1f}%)")
    print("")


def plot_rxmer(indices: list[int], rxmer_db: list[float],
               spacing_khz: int, threshold: float | None,
               output_path: str, header: dict | None):
    """
    Generate a matplotlib plot of RxMER vs subcarrier index.
    Optionally overlays a minimum threshold line.
    """
    if not HAS_MATPLOTLIB:
        logger.error(
            "matplotlib is not installed. Cannot generate plot.\n"
            "  Install with: pip install matplotlib"
        )
        return

    fig, ax = plt.subplots(figsize=(14, 5))

    # Convert subcarrier index to frequency (MHz) for the secondary x-axis
    # This gives a more intuitive view aligned with plant spectrum displays
    ax.plot(indices, rxmer_db, linewidth=0.6, color="#1f77b4", alpha=0.85,
            label="RxMER per subcarrier")

    if threshold is not None:
        ax.axhline(y=threshold, color="red", linestyle="--", linewidth=1.0,
                   label=f"Threshold: {threshold:.1f} dB")

    # Annotations
    ax.set_xlabel(f"Subcarrier Index ({spacing_khz} kHz spacing)", fontsize=11)
    ax.set_ylabel("RxMER (dB)", fontsize=11)

    title = "DOCSIS 3.1 DS OFDM — RxMER Per Subcarrier"
    if header:
        title += f"\nCapture: {header['capture_time']}  |  CM: {header['cm_mac']}"
    ax.set_title(title, fontsize=11)

    ax.yaxis.set_minor_locator(mticker.AutoMinorLocator())
    ax.xaxis.set_minor_locator(mticker.AutoMinorLocator())
    ax.grid(True, which="major", linestyle="-", linewidth=0.4, alpha=0.5)
    ax.grid(True, which="minor", linestyle=":", linewidth=0.2, alpha=0.3)
    ax.legend(fontsize=9)

    # Sensible y-axis range
    if rxmer_db:
        y_min = max(0.0, min(rxmer_db) - 2.0)
        y_max = max(rxmer_db) + 2.0
        ax.set_ylim(y_min, y_max)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    logger.info("Plot saved to: %s", os.path.abspath(output_path))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog="visualize_rxmer.py",
        description=(
            "DOCSIS 3.1 RxMER Per-Subcarrier Visualizer\n"
            "Parses a PNM binary RxMER file and plots RxMER vs subcarrier index.\n\n"
            "Copyright (c) 2017-2026 Brady Volpe, Volpe Firm — volpefirm.com"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python3 visualize_rxmer.py RxMerData\n"
            "  python3 visualize_rxmer.py --threshold 30 --output plot.png RxMerData\n"
            "  python3 visualize_rxmer.py --raw RxMerData\n"
        ),
    )
    parser.add_argument(
        "rxmer_file",
        help="Path to the binary RxMER data file from TFTP",
    )
    parser.add_argument(
        "-o", "--output",
        default="rxmer_plot.png",
        help="Output plot filename (default: rxmer_plot.png)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=None,
        metavar="DB",
        help="Overlay a minimum RxMER threshold line at this dB value",
    )
    parser.add_argument(
        "--spacing",
        type=int,
        choices=[25, 50],
        default=25,
        metavar="KHZ",
        help="Subcarrier spacing in kHz: 25 or 50 (default: 25)",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Skip header validation; interpret entire file as packed uint16 values",
    )
    parser.add_argument(
        "--no-plot",
        action="store_true",
        help="Print statistics only; do not generate a plot",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose/debug output",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Read the binary file
    try:
        with open(args.rxmer_file, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        logger.error("File not found: %s", args.rxmer_file)
        sys.exit(1)
    except OSError as exc:
        logger.error("Cannot read file: %s", exc)
        sys.exit(1)

    logger.info("Read %d bytes from '%s'", len(data), args.rxmer_file)

    header = None
    if args.raw:
        logger.info("Raw mode: skipping header, parsing as packed uint16 big-endian")
        indices, rxmer_db = parse_raw_uint16(data)
    else:
        try:
            header = parse_header(data)
            logger.info("Header parsed:")
            for k, v in header.items():
                logger.info("  %-18s %s", k + ":", v)

            indices, rxmer_db = parse_rxmer_values(data, header)
        except ValueError as exc:
            logger.error("Header parse failed: %s", exc)
            logger.info("Retry with --raw to skip header validation.")
            sys.exit(1)

    if not indices:
        logger.error("No valid RxMER values found in file.")
        sys.exit(1)

    logger.info("Parsed %d active subcarriers (excluded/pilot subcarriers omitted).",
                len(indices))

    print_stats(indices, rxmer_db, args.spacing)

    if not args.no_plot:
        plot_rxmer(indices, rxmer_db, args.spacing, args.threshold,
                   args.output, header)


if __name__ == "__main__":
    main()
