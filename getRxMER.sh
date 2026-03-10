#!/usr/bin/env bash
#
# getRxMER.sh — DOCSIS 3.1 RxMER Per Subcarrier PNM Tool
#
# Copyright (c) 2017-2026 Brady Volpe, Volpe Firm — volpefirm.com
# Originally developed 2017-01-06. Updated 2021-05-27. Overhauled 2026.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Triggers an RxMER per-subcarrier measurement on a DOCSIS 3.1 cable modem
# via SNMP (DOCS-PNM-MIB) and retrieves the resulting binary data file via
# TFTP upload to a specified PNM server.
#
# SNMP MIB: DOCS-PNM-MIB (CableLabs OID space: 1.3.6.1.4.1.4491.2.1.27)
# Reference: CM-SP-CM-OSSIv3.1 §PNM, SCTE 285
#
# Usage:
#   ./getRxMER.sh [--help] [-v] <ipmode> <cm_ip> <community_rw> <pnm_server_ip>
#
#   ipmode         1 = IPv4, 2 = IPv6
#   cm_ip          Cable modem IP address (IPv4 dotted-decimal or IPv6)
#   community_rw   SNMP v2c read-write community string
#   pnm_server_ip  IP address of TFTP / PNM collection server
#
# Examples:
#   ./getRxMER.sh 1 192.168.100.1 private <tftp_server_ip>
#   ./getRxMER.sh 2 <ipv6_address> <community_string> <tftp_server_ip>
#
# Prerequisites:
#   net-snmp tools: snmpget, snmpset, snmpbulkwalk
#   A running TFTP server reachable by the modem at <pnm_server_ip>
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

getRxMER.sh — DOCSIS 3.1 RxMER Per-Subcarrier PNM Tool
Copyright (c) 2017-2026 Brady Volpe, Volpe Firm <volpefirm.com>

USAGE:
  ./getRxMER.sh [OPTIONS] <ipmode> <cm_ip> <community_rw> <pnm_server_ip>

ARGUMENTS:
  ipmode         IP address family: 1 = IPv4, 2 = IPv6
  cm_ip          Cable modem management IP address
  community_rw   SNMP v2c read-write community string
  pnm_server_ip  IP address of the TFTP / PNM collection server

OPTIONS:
  -v, --verbose  Print detailed SNMP commands and responses
  -h, --help     Show this help and exit

EXAMPLES:
  ./getRxMER.sh 1 192.168.100.1 private <tftp_server_ip>
  ./getRxMER.sh -v 1 10.2.4.100 <community_string> <tftp_server_ip>
  ./getRxMER.sh 2 <ipv6_address> <community_string> <tftp_server_ip>

PREREQUISITES:
  - net-snmp tools (snmpget, snmpset, snmpbulkwalk) in PATH
  - A TFTP server running on <pnm_server_ip> with write access
  - Modem locked to a DOCSIS 3.1 OFDM downstream channel (ifType 277)

OUTPUT:
  A binary RxMER data file (default: 'RxMerData') uploaded via TFTP to
  <pnm_server_ip>. Use visualize_rxmer.py to parse and plot the results.

USAGE
}

# ---------------------------------------------------------------------------
# Parse flags (before positional args)
# ---------------------------------------------------------------------------

VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 4 ]]; then
    echo "ERROR: Expected four positional arguments." >&2
    usage >&2
    exit 1
fi

ipmode="$1"
cmip="$2"
cmrw="$3"
pnmServerIp="$4"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

validate_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    if [[ ${#octets[@]} -ne 4 ]]; then return 1; fi
    for octet in "${octets[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || (( octet > 255 )); then return 1; fi
    done
    return 0
}

if [[ "$ipmode" != "1" && "$ipmode" != "2" ]]; then
    echo "ERROR: ipmode must be 1 (IPv4) or 2 (IPv6). Got: '$ipmode'" >&2
    exit 1
fi

if [[ -z "$cmrw" ]]; then
    echo "ERROR: SNMP community string must not be empty." >&2
    exit 1
fi

if [[ "$ipmode" == "1" ]]; then
    if ! validate_ipv4 "$cmip"; then
        echo "ERROR: cm_ip '$cmip' is not a valid IPv4 address." >&2
        exit 1
    fi
    if ! validate_ipv4 "$pnmServerIp"; then
        echo "ERROR: pnm_server_ip '$pnmServerIp' is not a valid IPv4 address." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# SNMP command prefixes
# ---------------------------------------------------------------------------

# Format the CM IP target for net-snmp tools
if [[ "$ipmode" -eq 2 ]]; then
    snmp_target="udp6:[$cmip]"
else
    snmp_target="$cmip"
fi

# -t 5 = 5s timeout per attempt, -r 2 = 2 retries (important in high-latency HFC plant)
SNMP_OPTS="-v 2c -t 5 -r 2 -c '$cmrw'"
prefixSnmpGetCm="snmpget  $SNMP_OPTS $snmp_target"
prefixSnmpSetCm="snmpset  $SNMP_OPTS $snmp_target"
prefixSnmpWalkCm="snmpbulkwalk -Cr1 $SNMP_OPTS $snmp_target"

# ---------------------------------------------------------------------------
# DOCS-PNM-MIB OID definitions
# All OIDs from DOCS-PNM-MIB (CableLabs, 1.3.6.1.4.1.4491.2.1.27)
# Reference: https://mibs.cablelabs.com/MIBs/DOCSIS/DOCS-PNM-MIB.txt
# ---------------------------------------------------------------------------

# Bulk data control scalars (suffix .0 for scalar instance)
OID_BulkDestIpAddrType='.1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0'  # InetAddressType: 1=IPv4, 2=IPv6
OID_BulkDestIpAddr='.1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0'       # InetAddress (hex-encoded)
OID_BulkDestPath='.1.3.6.1.4.1.4491.2.1.27.1.1.1.3.0'         # String path on TFTP server
OID_BulkUploadControl='.1.3.6.1.4.1.4491.2.1.27.1.1.1.4.0'    # 1=other,2=noAutoUpload,3=autoUpload

# Bulk file table (per-row — ifIndex appended at runtime)
OID_BulkFileUploadStatus='.1.3.6.1.4.1.4491.2.1.27.1.1.2.1.3' # base OID

# CM control test objects
OID_CmCtlTest='.1.3.6.1.4.1.4491.2.1.27.1.2.1.1'   # Current test type (6=dsOfdmRxMERPerSubCar)
OID_CmCtlStatus='.1.3.6.1.4.1.4491.2.1.27.1.2.1.3' # MeasStatusType

# DS OFDM RxMER table objects (ifIndex appended at runtime)
OID_DsOfdmRxMerEnable='.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1'    # Enable/trigger RxMER test
OID_DsOfdmRxMerFileName='.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.8'  # Output filename for TFTP

# IF-MIB::ifType — used to locate the OFDM downstream interface
# ifType 277 = docsOfdmDownstream (DOCSIS 3.1 OFDM channel)
OID_IfType='1.3.6.1.2.1.2.2.1.3'

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

section() {
    echo ""
    printf '=%.0s' {1..65}; echo ""
    echo "  $1"
    printf '=%.0s' {1..65}; echo ""
}

vprint() {
    [[ "$VERBOSE" -eq 1 ]] && echo "  [verbose] $*"
}

snmp_set() {
    local oid_val="$1"
    local cmd="$prefixSnmpSetCm $oid_val"
    vprint "SNMP SET: $cmd"
    local out
    out=$(eval "$cmd" 2>&1) || {
        echo "WARNING: SNMP SET failed. Command: $cmd" >&2
        echo "  Output: $out" >&2
    }
    echo "$out"
}

snmp_walk() {
    local oid="$1"
    local cmd="$prefixSnmpWalkCm $oid"
    vprint "SNMP WALK: $cmd"
    local out
    out=$(eval "$cmd" 2>&1) || {
        echo "WARNING: SNMP WALK failed. Command: $cmd" >&2
        echo "  Output: $out" >&2
    }
    echo "$out"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

section "Configure Cable Modem and TFTP Server"

echo "Modem IP:     $snmp_target"
echo "PNM server:   $pnmServerIp"
echo "Querying modem sysDescr..."
sysDescr='1.3.6.1.2.1.1.1.0'
modemInfo=$(snmp_walk "$sysDescr")
echo "Modem info:   $modemInfo"
echo ""

# Step 1: Set IP address type for TFTP server destination
# docsPnmBulkDestIpAddrType: 1=IPv4, 2=IPv6
# This tells the CM which IP family to use when connecting to the TFTP server
vprint "Setting TFTP server IP address type ($ipmode)..."
setIpType=$(snmp_set "$OID_BulkDestIpAddrType i $ipmode")
echo "Set TFTP IP address type (1=IPv4, 2=IPv6): $setIpType"

# Step 2: Convert PNM server IP from dotted-decimal to hex, then set it
# docsPnmBulkDestIpAddr takes an InetAddress — for IPv4 this is 4 hex bytes
if [[ ${#pnmServerIp} -gt 15 ]]; then
    # IPv6 — pass the address string directly
    hex_addr="$pnmServerIp"
    vprint "Using IPv6 address directly: $hex_addr"
else
    # IPv4 — convert dotted-decimal to 4-byte hex (e.g., <tftp_server_ip> → 0x0a0100b0)
    IFS='.' read -r -a ip_array <<< "$pnmServerIp"
    hex_addr=$(printf '0x%02X%02X%02X%02X' "${ip_array[@]}")
    vprint "Converted $pnmServerIp → $hex_addr"
fi
echo "TFTP server hex address: $hex_addr"

# Step 3: Set TFTP server destination IP on the modem
setIP=$(snmp_set "$OID_BulkDestIpAddr x $hex_addr")
echo "Set TFTP server IP: $setIP"

# Step 4: Set TFTP upload destination path (empty string = TFTP root)
# docsPnmBulkDestPath: path on the server where the CM will deposit the file
dir='""'
setPath=$(snmp_set "$OID_BulkDestPath s $dir")
echo "Set TFTP path (empty = TFTP root): $setPath"

# Step 5: Set upload control to autoUpload (3)
# docsPnmBulkUploadControl: 3=autoUpload — modem automatically uploads when measurement is ready
setUpload=$(snmp_set "$OID_BulkUploadControl i 3")
echo "Set autoUpload (should = 3): $setUpload"

# ---------------------------------------------------------------------------
# Verify settings read back correctly
# ---------------------------------------------------------------------------

section "Verify Modem TFTP Configuration"

val=$(snmp_walk "$OID_BulkDestIpAddrType")
echo "IP address type (1=IPv4, 2=IPv6): $val"

val=$(snmp_walk "$OID_BulkDestIpAddr")
echo "TFTP server IP (hex): $val"

val=$(snmp_walk "$OID_BulkDestPath")
echo "TFTP path (should be empty): $val"

val=$(snmp_walk "$OID_BulkUploadControl")
echo "Upload control (3=autoUpload): $val"

# ---------------------------------------------------------------------------
# Discover the OFDM downstream interface index
# ---------------------------------------------------------------------------

section "Discover OFDM Downstream Interface Index"

# Walk IF-MIB::ifType to find the interface whose type = 277 (docsOfdmDownstream)
# DOCSIS 3.1 OFDM channels appear in the IF table with ifType 277
echo "Walking ifType table to find OFDM downstream channel..."
if_walk_output=$(eval "$prefixSnmpWalkCm $OID_IfType" 2>&1) || {
    echo "ERROR: SNMP walk of ifType failed. Check SNMP access to modem $snmp_target." >&2
    echo "  Output: $if_walk_output" >&2
    exit 1
}

ofdm_index=""
while IFS= read -r line; do
    # Match patterns like:
    #   IF-MIB::ifType.77 = INTEGER: docsOfdmDownstream(277)
    #   IF-MIB::ifType.77 = INTEGER: 277
    if [[ "$line" =~ ifType\.([0-9]+)[[:space:]]*=.*277 ]]; then
        ofdm_index="${BASH_REMATCH[1]}"
        vprint "Found OFDM interface at ifIndex $ofdm_index: $line"
        break
    fi
done <<< "$if_walk_output"

if [[ -z "$ofdm_index" ]]; then
    echo "ERROR: No OFDM downstream interface (ifType 277) found on modem $snmp_target." >&2
    echo "  Verify the modem is locked to a DOCSIS 3.1 OFDM downstream channel." >&2
    echo "  ifType walk output:" >&2
    echo "$if_walk_output" >&2
    exit 1
fi

echo "OFDM downstream ifIndex: $ofdm_index"

# Append the interface index to the per-row OIDs
oidEnable="${OID_DsOfdmRxMerEnable}.${ofdm_index}"
oidFileName="${OID_DsOfdmRxMerFileName}.${ofdm_index}"

# ---------------------------------------------------------------------------
# Initiate RxMER per-subcarrier measurement
# ---------------------------------------------------------------------------

section "Initiate RxMER Per-Subcarrier Measurement"

# Set the output filename for the RxMER binary data file
# Default naming by the modem uses MAC address + timestamp; override for predictability
filename='RxMerData'
fileset=$(snmp_set "$oidFileName s $filename")
echo "Set RxMER output filename to '$filename': $fileset"

# Enable the DS OFDM RxMER per-subcarrier test on the identified interface
# Setting dsOfdmRxMerEnable = 1 triggers the measurement.
# The modem captures RxMER (in 0.25 dB resolution) for every active OFDM subcarrier
# (~3800–7600 subcarriers depending on channel bandwidth and subcarrier spacing)
# and writes results to a binary TFTP file.
vprint "Enabling DS OFDM RxMER per-subcarrier measurement on ifIndex $ofdm_index..."
enable=$(snmp_set "$oidEnable i 1")
echo "RxMER enabled (should be 1): $enable"

# Verify the control test OID reflects dsOfdmRxMERPerSubCar (value 6)
currentTest=$(snmp_walk "$OID_CmCtlTest")
echo "Active test type (6 = dsOfdmRxMERPerSubCar): $currentTest"

# ---------------------------------------------------------------------------
# Poll for upload completion
# ---------------------------------------------------------------------------

section "Monitor TFTP Upload Status"

# docsPnmBulkFileUploadStatus values:
#   1=other  2=availableForUpload  3=uploadInProgress
#   4=uploadCompleted  5=uploadPending  6=uploadCancelled  7=error
echo "Polling for upload status (up to 60 seconds)..."
max_polls=30
poll_interval=2
upload_done=0

for (( i=1; i<=max_polls; i++ )); do
    sleep "$poll_interval"
    status_raw=$(snmp_walk "$OID_BulkFileUploadStatus")
    vprint "Poll $i/$max_polls — status: $status_raw"

    if echo "$status_raw" | grep -qiE 'uploadCompleted|INTEGER: 4[^0-9]'; then
        echo "Upload completed successfully (poll $i)."
        upload_done=1
        break
    elif echo "$status_raw" | grep -qiE 'error|INTEGER: 7[^0-9]'; then
        echo "ERROR: TFTP upload reported error state. Status: $status_raw" >&2
        echo "  Check: Is TFTP server running at $pnmServerIp? Does it have write permissions?" >&2
        break
    elif echo "$status_raw" | grep -qiE 'uploadCancelled|INTEGER: 6[^0-9]'; then
        echo "WARNING: Upload was cancelled. Status: $status_raw" >&2
        break
    fi
done

if [[ "$upload_done" -eq 0 ]]; then
    final_status=$(snmp_walk "$OID_BulkFileUploadStatus")
    echo "WARNING: Upload did not complete within $((max_polls * poll_interval)) seconds." >&2
    echo "  Final status: $final_status" >&2
    echo "  Check TFTP server connectivity and modem SNMP access." >&2
fi

echo ""
echo "Done. Binary RxMER file '$filename' should be in the TFTP root on $pnmServerIp."
echo "Use visualize_rxmer.py to parse and plot the per-subcarrier data."
echo ""
