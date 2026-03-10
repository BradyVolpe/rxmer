#!/usr/bin/env python3
"""
getRxMER.py — DOCSIS 3.1 RxMER Per Subcarrier PNM Tool

Copyright (c) 2017-2026 Brady Volpe, Volpe Firm — volpefirm.com
Licensed under the Apache License, Version 2.0

Triggers an RxMER per-subcarrier measurement on a DOCSIS 3.1 cable modem
via SNMP (DOCS-PNM-MIB) and retrieves the resulting binary data file via
TFTP upload to a specified PNM server.

SNMP MIB: DOCS-PNM-MIB (CableLabs OID: 1.3.6.1.4.1.4491.2.1.27)
Reference: CM-SP-CM-OSSIv3.1 §PNM, SCTE 285

Usage:
    python3 getRxMER.py [options] <ipmode> <cm_ip> <community_rw> <pnm_server_ip>

Examples:
    python3 getRxMER.py 1 192.168.100.1 private <tftp_server_ip>
    python3 getRxMER.py -v 2 <ipv6_address> <community_string> <tftp_server_ip>
    python3 getRxMER.py --filename CustomName 1 10.2.4.100 private <tftp_server_ip>
"""

import argparse
import ipaddress
import logging
import socket
import struct
import sys
import time

from pysnmp.hlapi import (
    CommunityData,
    ContextData,
    Integer32,
    IpAddress,
    ObjectIdentity,
    ObjectType,
    OctetString,
    SnmpEngine,
    UdpTransportTarget,
    Udp6TransportTarget,
    getCmd,
    setCmd,
    nextCmd,
)
from pysnmp.error import PySnmpError

# ---------------------------------------------------------------------------
# Logging configuration
# ---------------------------------------------------------------------------

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    level=logging.INFO,
)
logger = logging.getLogger("getRxMER")

# ---------------------------------------------------------------------------
# DOCS-PNM-MIB OID definitions
# All from DOCS-PNM-MIB (CableLabs, 1.3.6.1.4.1.4491.2.1.27)
# Reference: https://mibs.cablelabs.com/MIBs/DOCSIS/DOCS-PNM-MIB.txt
# ---------------------------------------------------------------------------

# Bulk data control scalars (suffix .0 for scalar instance)
OID_BulkDestIpAddrType  = (1,3,6,1,4,1,4491,2,1,27,1,1,1,1,0)  # InetAddressType: 1=IPv4, 2=IPv6
OID_BulkDestIpAddr      = (1,3,6,1,4,1,4491,2,1,27,1,1,1,2,0)  # InetAddress (raw bytes for IPv4)
OID_BulkDestPath        = (1,3,6,1,4,1,4491,2,1,27,1,1,1,3,0)  # String path on TFTP server
OID_BulkUploadControl   = (1,3,6,1,4,1,4491,2,1,27,1,1,1,4,0)  # 1=other,2=noAutoUpload,3=autoUpload

# Bulk file table base OIDs (append .<fileIndex>)
OID_BulkFileUploadStatus_base = (1,3,6,1,4,1,4491,2,1,27,1,1,2,1,3)  # upload status per file

# CM control test objects
OID_CmCtlTest   = (1,3,6,1,4,1,4491,2,1,27,1,2,1,1)   # Current test type (6=dsOfdmRxMERPerSubCar)
OID_CmCtlStatus = (1,3,6,1,4,1,4491,2,1,27,1,2,1,3)   # MeasStatusType

# DS OFDM RxMER table base OIDs (append .<ifIndex>)
OID_DsOfdmRxMerEnable_base   = (1,3,6,1,4,1,4491,2,1,27,1,2,5,1,1)  # Enable/trigger RxMER test
OID_DsOfdmRxMerFileName_base = (1,3,6,1,4,1,4491,2,1,27,1,2,5,1,8)  # Output filename for TFTP

# IF-MIB ifType — OFDM downstream = 277 (docsOfdmDownstream)
OID_IfType_base = (1,3,6,1,2,1,2,2,1,3)   # append .<ifIndex>
OID_SysDescr    = (1,3,6,1,2,1,1,1,0)

# Upload status enum values
UPLOAD_STATUS = {
    1: "other",
    2: "availableForUpload",
    3: "uploadInProgress",
    4: "uploadCompleted",
    5: "uploadPending",
    6: "uploadCancelled",
    7: "error",
}


# ---------------------------------------------------------------------------
# SNMP helpers
# ---------------------------------------------------------------------------

class SnmpClient:
    """
    Thin wrapper around pysnmp hlapi for SNMP v2c get/set/walk operations.
    Automatically handles IPv4 vs IPv6 transport targets.
    """

    def __init__(self, host: str, community: str, ipv6: bool = False,
                 timeout: int = 5, retries: int = 2):
        self.community = CommunityData(community, mpModel=1)  # mpModel=1 = SNMPv2c
        self.engine    = SnmpEngine()
        self.context   = ContextData()
        self.ipv6      = ipv6

        # Strip protocol prefix if present (e.g., "udp6:[...]")
        host = host.lstrip("udp6:[").rstrip("]")

        if ipv6:
            self.transport = Udp6TransportTarget((host, 161), timeout=timeout, retries=retries)
        else:
            self.transport = UdpTransportTarget((host, 161), timeout=timeout, retries=retries)

    def get(self, oid: tuple):
        """Perform an SNMP GET. Returns the value or raises on error."""
        error_indication, error_status, _, var_binds = next(
            getCmd(self.engine, self.community, self.transport, self.context,
                   ObjectType(ObjectIdentity(oid)))
        )
        if error_indication:
            raise RuntimeError(f"SNMP GET error: {error_indication}")
        if error_status:
            raise RuntimeError(f"SNMP GET error-status: {error_status.prettyPrint()}")
        return var_binds[0][1]

    def set(self, oid: tuple, value):
        """Perform an SNMP SET. Returns the response value or raises on error."""
        error_indication, error_status, _, var_binds = next(
            setCmd(self.engine, self.community, self.transport, self.context,
                   ObjectType(ObjectIdentity(oid), value))
        )
        if error_indication:
            raise RuntimeError(f"SNMP SET error: {error_indication}")
        if error_status:
            raise RuntimeError(f"SNMP SET error-status: {error_status.prettyPrint()}")
        return var_binds[0][1]

    def walk(self, base_oid: tuple) -> list:
        """
        Walk the subtree under base_oid. Returns a list of (oid_tuple, value) pairs.
        """
        results = []
        for (error_indication, error_status, _, var_binds) in nextCmd(
            self.engine, self.community, self.transport, self.context,
            ObjectType(ObjectIdentity(base_oid)),
            lexicographicMode=False,
        ):
            if error_indication:
                logger.warning("SNMP WALK error: %s", error_indication)
                break
            if error_status:
                logger.warning("SNMP WALK error-status: %s", error_status.prettyPrint())
                break
            for var_bind in var_binds:
                results.append(var_bind)
        return results


def ipv4_to_hex_bytes(ip_str: str) -> bytes:
    """
    Convert a dotted-decimal IPv4 address to 4 raw bytes.
    e.g., '<tftp_server_ip>' → b'\\x0a\\x01\\x00\\xb0'
    """
    return socket.inet_aton(ip_str)


def section(title: str):
    """Print a section header."""
    bar = "=" * 65
    logger.info(bar)
    logger.info("  %s", title)
    logger.info(bar)


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

def run(args: argparse.Namespace) -> int:
    """
    Execute the full RxMER collection workflow:
      1. Configure TFTP destination on the modem
      2. Discover the OFDM downstream interface index
      3. Trigger the RxMER per-subcarrier measurement
      4. Poll for upload completion
    Returns 0 on success, 1 on failure.
    """
    ipmode   = int(args.ipmode)
    cm_ip    = args.cm_ip
    cmrw     = args.community
    pnm_ip   = args.pnm_server_ip
    filename = args.filename

    is_ipv6 = (ipmode == 2)

    # -----------------------------------------------------------------------
    # Instantiate SNMP client
    # -----------------------------------------------------------------------
    logger.debug("Connecting to modem %s (SNMP v2c, community redacted)", cm_ip)
    try:
        snmp = SnmpClient(cm_ip, cmrw, ipv6=is_ipv6,
                          timeout=args.timeout, retries=args.retries)
    except Exception as exc:
        logger.error("Failed to create SNMP client: %s", exc)
        return 1

    section("Configure Cable Modem and TFTP Server")

    # Query modem sysDescr for identification
    try:
        descr = snmp.get(OID_SysDescr)
        logger.info("Modem IP:      %s", cm_ip)
        logger.info("Modem sysDescr: %s", descr.prettyPrint())
    except RuntimeError as exc:
        logger.error("Cannot reach modem via SNMP: %s", exc)
        logger.error("  Check: Is the modem reachable? Is community '%s' correct?",
                     "[redacted]")
        return 1

    # -----------------------------------------------------------------------
    # Step 1: Set TFTP server IP address type
    # docsPnmBulkDestIpAddrType: 1=IPv4, 2=IPv6
    # This tells the CM which IP family to use when connecting to the TFTP server
    # -----------------------------------------------------------------------
    logger.info("Setting TFTP server IP address type: %d (%s)", ipmode, "IPv6" if is_ipv6 else "IPv4")
    try:
        result = snmp.set(OID_BulkDestIpAddrType, Integer32(ipmode))
        logger.debug("  → %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to set IP address type: %s", exc)
        return 1

    # -----------------------------------------------------------------------
    # Step 2: Set TFTP server IP address
    # docsPnmBulkDestIpAddr: for IPv4 this is a 4-byte OctetString (raw hex)
    # -----------------------------------------------------------------------
    if is_ipv6:
        # For IPv6, pass the packed 16-byte address
        addr_bytes = socket.inet_pton(socket.AF_INET6, pnm_ip)
        logger.info("TFTP server IPv6 address: %s", pnm_ip)
    else:
        addr_bytes = ipv4_to_hex_bytes(pnm_ip)
        logger.info("TFTP server IPv4 address: %s (hex: %s)",
                    pnm_ip, addr_bytes.hex())

    try:
        result = snmp.set(OID_BulkDestIpAddr, OctetString(addr_bytes))
        logger.debug("  → %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to set TFTP server IP: %s", exc)
        return 1

    # -----------------------------------------------------------------------
    # Step 3: Set TFTP destination path
    # docsPnmBulkDestPath: empty string = TFTP root directory
    # -----------------------------------------------------------------------
    logger.info("Setting TFTP destination path to '' (root)")
    try:
        result = snmp.set(OID_BulkDestPath, OctetString(b""))
        logger.debug("  → %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to set TFTP path: %s", exc)
        return 1

    # -----------------------------------------------------------------------
    # Step 4: Set upload control to autoUpload (3)
    # docsPnmBulkUploadControl: 3=autoUpload — CM automatically uploads when
    # the measurement file is ready
    # -----------------------------------------------------------------------
    logger.info("Setting upload control to autoUpload (3)")
    try:
        result = snmp.set(OID_BulkUploadControl, Integer32(3))
        logger.debug("  → %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to set upload control: %s", exc)
        return 1

    # -----------------------------------------------------------------------
    # Verify TFTP settings
    # -----------------------------------------------------------------------
    section("Verify Modem TFTP Configuration")
    for oid, label in [
        (OID_BulkDestIpAddrType, "IP address type (1=IPv4, 2=IPv6)"),
        (OID_BulkDestIpAddr,     "TFTP server IP (raw)"),
        (OID_BulkDestPath,       "TFTP path (should be empty)"),
        (OID_BulkUploadControl,  "Upload control (3=autoUpload)"),
    ]:
        try:
            val = snmp.get(oid)
            logger.info("  %s: %s", label, val.prettyPrint())
        except RuntimeError as exc:
            logger.warning("  Could not read %s: %s", label, exc)

    # -----------------------------------------------------------------------
    # Discover OFDM downstream interface index
    # Walk IF-MIB::ifType looking for ifType = 277 (docsOfdmDownstream)
    # DOCSIS 3.1 OFDM channels are distinct IF entries from SC-QAM channels
    # -----------------------------------------------------------------------
    section("Discover OFDM Downstream Interface Index")
    logger.info("Walking ifType table to find OFDM downstream (ifType 277)...")

    try:
        if_rows = snmp.walk(OID_IfType_base)
    except Exception as exc:
        logger.error("SNMP walk of ifType failed: %s", exc)
        return 1

    ofdm_index = None
    for var_bind in if_rows:
        oid, val = var_bind
        if int(val) == 277:
            # Extract the ifIndex from the last OID component
            ofdm_index = int(oid[-1])
            logger.debug("Found OFDM interface: ifType[%d] = %d", ofdm_index, int(val))
            break

    if ofdm_index is None:
        logger.error("No OFDM downstream interface (ifType 277) found on modem %s.", cm_ip)
        logger.error("  Verify the modem is locked to a DOCSIS 3.1 OFDM downstream channel.")
        logger.error("  ifType rows found: %s", [(str(v[0]), int(v[1])) for v in if_rows[:10]])
        return 1

    logger.info("OFDM downstream ifIndex: %d", ofdm_index)

    # Build per-row OIDs by appending the ifIndex
    oid_enable   = OID_DsOfdmRxMerEnable_base   + (ofdm_index,)
    oid_filename = OID_DsOfdmRxMerFileName_base  + (ofdm_index,)

    # -----------------------------------------------------------------------
    # Initiate RxMER per-subcarrier measurement
    # -----------------------------------------------------------------------
    section("Initiate RxMER Per-Subcarrier Measurement")

    # Set the output filename for the RxMER binary data file
    logger.info("Setting RxMER output filename to '%s'", filename)
    try:
        result = snmp.set(oid_filename, OctetString(filename.encode()))
        logger.debug("  → %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to set RxMER filename: %s", exc)
        return 1

    # Enable the DS OFDM RxMER per-subcarrier test
    # Setting dsOfdmRxMerEnable = 1 triggers the measurement.
    # The modem captures RxMER (in 0.25 dB resolution) for every active OFDM
    # subcarrier (~3800–7600 subcarriers depending on channel bandwidth and
    # subcarrier spacing) and writes results to a binary TFTP file.
    logger.info("Triggering DS OFDM RxMER per-subcarrier measurement on ifIndex %d...",
                ofdm_index)
    try:
        result = snmp.set(oid_enable, Integer32(1))
        logger.info("RxMER enabled (should be 1): %s", result.prettyPrint())
    except RuntimeError as exc:
        logger.error("Failed to enable RxMER measurement: %s", exc)
        return 1

    # Verify the control test OID reflects dsOfdmRxMERPerSubCar (value 6)
    try:
        test_rows = snmp.walk(OID_CmCtlTest)
        for vb in test_rows:
            logger.info("Active test type (6 = dsOfdmRxMERPerSubCar): %s",
                        vb[1].prettyPrint())
    except RuntimeError as exc:
        logger.warning("Could not read CmCtlTest: %s", exc)

    # -----------------------------------------------------------------------
    # Poll for upload completion
    # docsPnmBulkFileUploadStatus:
    #   1=other  2=availableForUpload  3=uploadInProgress
    #   4=uploadCompleted  5=uploadPending  6=uploadCancelled  7=error
    # -----------------------------------------------------------------------
    section("Monitor TFTP Upload Status")
    logger.info("Polling for upload completion (up to 60 seconds)...")

    upload_done  = False
    max_polls    = 30
    poll_interval = 2.0  # seconds

    for i in range(1, max_polls + 1):
        time.sleep(poll_interval)
        try:
            status_rows = snmp.walk(OID_BulkFileUploadStatus_base)
        except RuntimeError as exc:
            logger.warning("Poll %d/%d — SNMP error: %s", i, max_polls, exc)
            continue

        for vb in status_rows:
            status_val = int(vb[1])
            status_name = UPLOAD_STATUS.get(status_val, f"unknown({status_val})")
            logger.debug("Poll %d/%d — upload status: %d (%s)", i, max_polls,
                         status_val, status_name)

            if status_val == 4:  # uploadCompleted
                logger.info("Upload completed successfully (poll %d).", i)
                upload_done = True
                break
            elif status_val == 7:  # error
                logger.error("TFTP upload reported error state (status=7).")
                logger.error("  Check: Is TFTP server running at %s?", pnm_ip)
                logger.error("  Does the TFTP root directory have write permissions?")
                break
            elif status_val == 6:  # uploadCancelled
                logger.warning("Upload was cancelled (status=6).")
                break

        if upload_done:
            break

    if not upload_done:
        logger.warning(
            "Upload did not complete within %d seconds.",
            int(max_polls * poll_interval),
        )
        logger.warning("  Check TFTP server connectivity and modem SNMP access.")
        return 1

    logger.info("")
    logger.info("Done. Binary RxMER file '%s' should be in the TFTP root on %s.",
                filename, pnm_ip)
    logger.info("Use visualize_rxmer.py to parse and plot the per-subcarrier data.")
    return 0


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="getRxMER.py",
        description=(
            "DOCSIS 3.1 RxMER Per Subcarrier PNM Tool\n"
            "Triggers an RxMER measurement on a cable modem via SNMP/TFTP.\n\n"
            "Copyright (c) 2017-2026 Brady Volpe, Volpe Firm — volpefirm.com"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python3 getRxMER.py 1 192.168.100.1 private <tftp_server_ip>\n"
            "  python3 getRxMER.py -v 1 10.2.4.100 <community_string> <tftp_server_ip>\n"
            "  python3 getRxMER.py 2 <ipv6_address> <community_string> <tftp_server_ip>\n"
        ),
    )

    parser.add_argument(
        "ipmode",
        choices=["1", "2"],
        help="IP address family: 1 = IPv4, 2 = IPv6",
    )
    parser.add_argument(
        "cm_ip",
        metavar="cm_ip",
        help="Cable modem management IP address",
    )
    parser.add_argument(
        "community",
        metavar="community_rw",
        help="SNMP v2c read-write community string",
    )
    parser.add_argument(
        "pnm_server_ip",
        metavar="pnm_server_ip",
        help="IP address of the TFTP / PNM collection server",
    )
    parser.add_argument(
        "-f", "--filename",
        default="RxMerData",
        help="Output filename on the TFTP server (default: RxMerData)",
    )
    parser.add_argument(
        "-t", "--timeout",
        type=int,
        default=5,
        help="SNMP request timeout in seconds (default: 5)",
    )
    parser.add_argument(
        "-r", "--retries",
        type=int,
        default=2,
        help="SNMP request retry count (default: 2)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose/debug output",
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    else:
        logging.getLogger().setLevel(logging.INFO)

    # Validate IP addresses
    ipmode = int(args.ipmode)
    try:
        if ipmode == 1:
            ipaddress.IPv4Address(args.cm_ip)
            ipaddress.IPv4Address(args.pnm_server_ip)
        else:
            ipaddress.IPv6Address(args.cm_ip)
    except ValueError as exc:
        logger.error("Invalid IP address: %s", exc)
        sys.exit(1)

    sys.exit(run(args))


if __name__ == "__main__":
    main()
