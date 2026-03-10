#!/usr/bin/perl
#
# getRxMER.pl — DOCSIS 3.1 RxMER Per Subcarrier PNM Tool
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
#   perl getRxMER.pl [--help] [-v] <ipmode> <cm_ip> <community_rw> <pnm_server_ip>
#
#   ipmode         1 = IPv4, 2 = IPv6
#   cm_ip          Cable modem IP address (IPv4 dotted-decimal or IPv6)
#   community_rw   SNMP v2c read-write community string
#   pnm_server_ip  IP address of TFTP / PNM collection server
#
# Examples:
#   perl getRxMER.pl 1 192.168.100.1 private <tftp_server_ip>
#   perl getRxMER.pl 2 <ipv6_address> <community_string> <tftp_server_ip>
#
# Prerequisites:
#   Perl modules: Net::SNMP, Net::Ping, Data::Dumper, Getopt::Std
#   System tools: snmpget, snmpset, snmpbulkwalk (net-snmp package)
#   A running TFTP server reachable by the modem at <pnm_server_ip>
#

use strict;
use warnings;

use Data::Dumper;
use Net::Ping;
use Getopt::Long qw(:config pass_through);
use Net::SNMP qw(:snmp);

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------

my $verbose = 0;
my $help    = 0;

GetOptions(
    'verbose|v' => \$verbose,
    'help|h'    => \$help,
) or usage_and_exit(1);

if ($help) {
    usage_and_exit(0);
}

if (@ARGV < 4) {
    print STDERR "ERROR: Expected four positional arguments.\n\n";
    usage_and_exit(1);
}

my ($ipmode, $cmip, $cmrw, $pnmServerIp) = @ARGV;

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

unless ($ipmode eq '1' || $ipmode eq '2') {
    die "ERROR: ipmode must be 1 (IPv4) or 2 (IPv6). Got: '$ipmode'\n";
}

if ($ipmode eq '1') {
    unless ($cmip =~ /^(\d{1,3}\.){3}\d{1,3}$/ && valid_ipv4($cmip)) {
        die "ERROR: cm_ip '$cmip' is not a valid IPv4 address.\n";
    }
    unless ($pnmServerIp =~ /^(\d{1,3}\.){3}\d{1,3}$/ && valid_ipv4($pnmServerIp)) {
        die "ERROR: pnm_server_ip '$pnmServerIp' is not a valid IPv4 address.\n";
    }
}

unless (length($cmrw) > 0) {
    die "ERROR: SNMP community string must not be empty.\n";
}

# ---------------------------------------------------------------------------
# Build SNMP command prefixes
# ---------------------------------------------------------------------------

# Format the CM IP target for net-snmp tools
my $snmp_target = ($ipmode eq '2') ? "udp6:[$cmip]" : $cmip;

# SNMP v2c timeout (-t) and retries (-r) added for robustness in lossy plant
my $snmp_opts        = "-v 2c -t 5 -r 2 -c '$cmrw'";
my $prefixSnmpGetCm  = "snmpget  $snmp_opts $snmp_target";
my $prefixSnmpSetCm  = "snmpset  $snmp_opts $snmp_target";
my $prefixSnmpWalkCm = "snmpbulkwalk -Cr1 $snmp_opts $snmp_target";

# ---------------------------------------------------------------------------
# DOCS-PNM-MIB OID definitions
# All OIDs are from DOCS-PNM-MIB (CableLabs, 1.3.6.1.4.1.4491.2.1.27)
# Reference: https://mibs.cablelabs.com/MIBs/DOCSIS/DOCS-PNM-MIB.txt
# ---------------------------------------------------------------------------

# Bulk data control objects (scalar — appended with .0)
# docsPnmBulkCtl ::= { docsPnmBulkData 1 } = .27.1.1.1
my $OID_BulkDestIpAddrType  = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0'; # InetAddressType: 1=IPv4, 2=IPv6
my $OID_BulkDestIpAddr      = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0'; # InetAddress (hex-encoded)
my $OID_BulkDestPath        = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.3.0'; # String path on TFTP server
my $OID_BulkUploadControl   = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.4.0'; # 1=other,2=noAutoUpload,3=autoUpload

# Bulk file table objects (per-file row — index is appended at runtime)
# docsPnmBulkFileTable ::= { docsPnmBulkData 2 } = .27.1.1.2
my $OID_BulkFileControl      = '.1.3.6.1.4.1.4491.2.1.27.1.1.2.1.2'; # base — append .<fileIdx>
my $OID_BulkFileUploadStatus = '.1.3.6.1.4.1.4491.2.1.27.1.1.2.1.3'; # base — append .<fileIdx>

# CM control test objects (scalar — appended with .0)
# docsPnmCmCtl ::= { docsPnmCmObjects 1 } = .27.1.2.1
my $OID_CmCtlTest         = '.1.3.6.1.4.1.4491.2.1.27.1.2.1.1';  # walk — returns current test type (6=RxMER)
my $OID_CmCtlStatus       = '.1.3.6.1.4.1.4491.2.1.27.1.2.1.3';  # walk — MeasStatusType

# DS OFDM RxMER table objects (per-interface row — OFDM ifIndex appended)
# docsPnmCmDsOfdmRxMerTable ::= { docsPnmCmObjects 5 } = .27.1.2.5
my $OID_DsOfdmRxMerEnable   = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1'; # base — append .<ifIndex>
my $OID_DsOfdmRxMerFileName = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.8'; # base — append .<ifIndex>

# IF-MIB::ifType — used to locate the OFDM downstream interface index
# OFDM downstream = ifType 277 (docsOfdmDownstream)
my $OID_IfType = '1.3.6.1.2.1.2.2.1.3';

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print "\n";
section("Configure Cable Modem and TFTP Server");

# Identify the modem (sysDescr)
vprint("Querying modem sysDescr...\n");
my $modemInfo = snmp_walk($OID_IfType);  # Will do sysDescr separately
my $sysDescr  = '1.3.6.1.2.1.1.1.0';
my $modemDescr = snmp_walk($sysDescr);
print "Modem IP:      $snmp_target\n";
print "Modem sysDescr: $modemDescr\n\n";

# Step 1: Set IP address type for TFTP server
# docsPnmBulkDestIpAddrType: 1 = IPv4, 2 = IPv6
# This tells the modem which IP family to use when connecting to the TFTP server
vprint("Setting TFTP server IP address type ($ipmode = " . ($ipmode eq '1' ? 'IPv4' : 'IPv6') . ")...\n");
my $setIpType = snmp_set("$OID_BulkDestIpAddrType i $ipmode");
print "Set TFTP IP address type: $setIpType\n";

# Step 2: Convert PNM server IP from dotted-decimal to hex, then set it
# docsPnmBulkDestIpAddr takes an InetAddress — for IPv4 this is 4 hex bytes
my $hex_addr;
if (length($pnmServerIp) > 15) {
    # IPv6 — pass the address string directly
    $hex_addr = $pnmServerIp;
    vprint("Using IPv6 address directly: $hex_addr\n");
} else {
    # IPv4 — convert dotted-decimal to 4-byte hex (e.g., <tftp_server_ip> → 0x0a0100b0)
    $hex_addr = unpack('H*', pack('C*', split(/\./, $pnmServerIp)));
    vprint("Converted $pnmServerIp → 0x$hex_addr\n");
}
print "TFTP server hex address: 0x$hex_addr\n";

# Step 3: Set TFTP server destination IP on the modem
my $setIP = snmp_set("$OID_BulkDestIpAddr x $hex_addr");
print "Set TFTP server IP: $setIP\n";

# Step 4: Set TFTP upload destination path (empty string = TFTP root)
# docsPnmBulkDestPath: path on the server where the CM will deposit the file
my $dir    = q{""};
my $setPath = snmp_set("$OID_BulkDestPath s $dir");
print "Set TFTP path (empty = root): $setPath\n";

# Step 5: Set upload control to autoUpload (3)
# docsPnmBulkUploadControl: 3 = autoUpload — modem automatically uploads when data is ready
my $setUpload = snmp_set("$OID_BulkUploadControl i 3");
print "Set autoUpload: $setUpload\n\n";

# ---------------------------------------------------------------------------
# Verify TFTP settings read back correctly
# ---------------------------------------------------------------------------

section("Verify Modem TFTP Configuration");

my $val;
$val = snmp_walk($OID_BulkDestIpAddrType);
print "IP address type (1=IPv4, 2=IPv6): $val\n";

$val = snmp_walk($OID_BulkDestIpAddr);
print "TFTP server IP (hex): $val\n";

$val = snmp_walk($OID_BulkDestPath);
print "TFTP path (should be empty): $val\n";

$val = snmp_walk($OID_BulkUploadControl);
print "Upload control (3=autoUpload): $val\n\n";

# ---------------------------------------------------------------------------
# Discover the OFDM downstream interface index
# ---------------------------------------------------------------------------

section("Discover OFDM Downstream Interface Index");

# Walk IF-MIB::ifType to find the interface whose type = 277 (docsOfdmDownstream)
# DOCSIS 3.1 OFDM channels appear in the IF table with ifType 277
print "Walking ifType table to find OFDM downstream channel...\n";
my @ifTypeRows = `$prefixSnmpWalkCm $OID_IfType 2>&1`;
if ($?) {
    die "ERROR: SNMP walk of ifType failed. Check SNMP access to modem $snmp_target.\n"
      . "  Output: " . join('', @ifTypeRows) . "\n";
}

my $ofdm_index;
foreach my $row (@ifTypeRows) {
    chomp $row;
    # Match patterns like:
    #   IF-MIB::ifType.77 = INTEGER: docsOfdmDownstream(277)
    #   IF-MIB::ifType.77 = INTEGER: 277
    if ($row =~ /ifType\.(\d+)\s*=\s*INTEGER:.*?277/) {
        $ofdm_index = $1;
        vprint("Found OFDM interface at ifIndex $ofdm_index: $row\n");
        last;
    }
}

unless (defined $ofdm_index) {
    die "ERROR: No OFDM downstream interface (ifType 277) found on modem $snmp_target.\n"
      . "  Verify the modem is locked to a DOCSIS 3.1 OFDM downstream channel.\n"
      . "  Walk output:\n" . join('', @ifTypeRows) . "\n";
}

print "OFDM downstream ifIndex: $ofdm_index\n\n";

# Append the interface index to the per-row OIDs
my $oidEnable   = "$OID_DsOfdmRxMerEnable.$ofdm_index";
my $oidFileName = "$OID_DsOfdmRxMerFileName.$ofdm_index";

# ---------------------------------------------------------------------------
# Initiate RxMER per-subcarrier measurement
# ---------------------------------------------------------------------------

section("Initiate RxMER Per-Subcarrier Measurement");

# Set the output filename for the RxMER binary data file
# Default is modem MAC + timestamp; override here for predictability
my $filename = 'RxMerData';
my $fileset  = snmp_set("$oidFileName s $filename");
print "Set RxMER output filename to '$filename': $fileset\n";

# Enable the DS OFDM RxMER per-subcarrier test
# docsPnmCmDsOfdmRxMerEnable = 1 triggers the measurement
# The modem will capture RxMER for every active OFDM subcarrier (~3800–7600 subcarriers
# depending on channel width and subcarrier spacing) and write results to the binary file
vprint("Enabling DS OFDM RxMER per-subcarrier measurement on ifIndex $ofdm_index...\n");
my $enable = snmp_set("$oidEnable i 1");
print "RxMER enabled (should be 1): $enable\n";

# Verify the control test OID reflects RxMER test (value 6 = dsOfdmRxMERPerSubCar)
# docsPnmCmCtlTest returns the currently active test type
my $currentTest = snmp_walk($OID_CmCtlTest);
print "Active test type (6 = dsOfdmRxMERPerSubCar): $currentTest\n\n";

# ---------------------------------------------------------------------------
# Poll for upload completion
# ---------------------------------------------------------------------------

section("Monitor TFTP Upload Status");

# docsPnmBulkFileUploadStatus values:
#   1=other  2=availableForUpload  3=uploadInProgress
#   4=uploadCompleted  5=uploadPending  6=uploadCancelled  7=error
print "Polling for upload status...\n";
my $max_polls = 30;
my $poll_interval = 2;  # seconds
my $upload_done   = 0;

for my $i (1..$max_polls) {
    sleep($poll_interval);
    my $status_raw = snmp_walk($OID_BulkFileUploadStatus);
    chomp $status_raw;
    vprint("Poll $i/$max_polls — status: $status_raw\n");

    if ($status_raw =~ /uploadCompleted|= INTEGER: 4\b/) {
        print "Upload completed successfully (poll $i).\n";
        $upload_done = 1;
        last;
    } elsif ($status_raw =~ /error|= INTEGER: 7\b/) {
        print STDERR "ERROR: TFTP upload reported error state. Status: $status_raw\n";
        print STDERR "  Check: TFTP server running at $pnmServerIp? Write permissions on TFTP root?\n";
        last;
    } elsif ($status_raw =~ /uploadCancelled|= INTEGER: 6\b/) {
        print STDERR "WARNING: Upload was cancelled. Status: $status_raw\n";
        last;
    }
}

unless ($upload_done) {
    print STDERR "WARNING: Upload did not complete within " . ($max_polls * $poll_interval) . " seconds.\n";
    print STDERR "  Final status: " . snmp_walk($OID_BulkFileUploadStatus) . "\n";
    print STDERR "  Check TFTP server and modem SNMP access.\n";
}

print "\nDone. Binary RxMER file '$filename' should be in the TFTP root on $pnmServerIp.\n";
print "Use visualize_rxmer.py to parse and plot the per-subcarrier data.\n\n";

# ---------------------------------------------------------------------------
# Helper subroutines
# ---------------------------------------------------------------------------

sub snmp_set {
    my ($oid_and_value) = @_;
    my $cmd = "$prefixSnmpSetCm $oid_and_value 2>&1";
    vprint("  SNMP SET: $cmd\n");
    my $out = `$cmd`;
    if ($? != 0 || $out =~ /Error|Timeout|No response/i) {
        warn "SNMP SET warning — command: $cmd\n  Output: $out\n";
    }
    chomp $out;
    return $out;
}

sub snmp_walk {
    my ($oid) = @_;
    my $cmd = "$prefixSnmpWalkCm $oid 2>&1";
    vprint("  SNMP WALK: $cmd\n");
    my $out = `$cmd`;
    if ($? != 0 || $out =~ /Timeout|No response/i) {
        warn "SNMP WALK warning — command: $cmd\n  Output: $out\n";
    }
    chomp $out;
    return $out;
}

sub section {
    my ($title) = @_;
    print "=" x 65 . "\n";
    print "  $title\n";
    print "=" x 65 . "\n";
}

sub vprint {
    my ($msg) = @_;
    print $msg if $verbose;
}

sub valid_ipv4 {
    my ($ip) = @_;
    my @octets = split(/\./, $ip);
    return 0 unless @octets == 4;
    for my $o (@octets) {
        return 0 unless $o >= 0 && $o <= 255;
    }
    return 1;
}

sub usage_and_exit {
    my ($exit_code) = @_;
    print <<'END_USAGE';

getRxMER.pl — DOCSIS 3.1 RxMER Per-Subcarrier PNM Tool
Copyright (c) 2017-2026 Brady Volpe, Volpe Firm <volpefirm.com>

USAGE:
  perl getRxMER.pl [OPTIONS] <ipmode> <cm_ip> <community_rw> <pnm_server_ip>

ARGUMENTS:
  ipmode         IP address family: 1 = IPv4, 2 = IPv6
  cm_ip          Cable modem management IP address
  community_rw   SNMP v2c read-write community string
  pnm_server_ip  IP address of the TFTP / PNM collection server

OPTIONS:
  -v, --verbose  Print detailed SNMP commands and responses
  -h, --help     Show this help and exit

EXAMPLES:
  perl getRxMER.pl 1 192.168.100.1 private <tftp_server_ip>
  perl getRxMER.pl -v 1 10.2.4.100 <community_string> <tftp_server_ip>
  perl getRxMER.pl 2 <ipv6_address> <community_string> <tftp_server_ip>

PREREQUISITES:
  - net-snmp tools (snmpget, snmpset, snmpbulkwalk) in PATH
  - Perl modules: Net::SNMP, Net::Ping, Data::Dumper, Getopt::Long
  - A TFTP server running on <pnm_server_ip> with write access
  - Modem locked to a DOCSIS 3.1 OFDM downstream channel (ifType 277)

OUTPUT:
  A binary RxMER data file (default: 'RxMerData') uploaded via TFTP to
  <pnm_server_ip>. Use visualize_rxmer.py to parse and plot the results.

END_USAGE
    exit($exit_code);
}
