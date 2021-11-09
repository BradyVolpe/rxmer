#!/usr/bin/perl

# Author: Brady Volpe
# Date: January 6, 2017
# Updated May 27, 2021
# © Nimble This LLC 2013
# All Rights Reserved
# No part of this website or any of its contents may be reproduced, copied, modified or adapted,
# without the prior written consent of the author, unless otherwise indicated for stand-alone materials.
#
# Configure TFTP Server: https://n40lab.wordpress.com/2013/01/29/centos-6-3-installing-a-tftpd-server-for-uploading-configuration-files/


# This script gets RxMER data from a DOCSIS 3.1 cable modem

# Clear screen on start
print "\033[2J";    #clear the screen
print "\033[0;0H";  #jump to 0,0

# Check for correct number of ARGS
if (@ARGV < 4) {
 print "Need four arguments, \n";
 print "<IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>\n";
 # Example: perl getRxMER.pl 2 2604:3d00:43f:5:c015:7c91:ca96:b923 ENG007 10.143.254.130
 exit;
}

# Set vars from ARGS
my $ipmode      = $ARGV[0];
my $cmip        = $ARGV[1];
my $cmrw        = $ARGV[2];
my $pnmServerIp = $ARGV[3];

# Imports
use Data::Dumper;
use Net::Ping;
use Getopt::Std;
use Net::SNMP qw(:snmp);


# Define CM IP address in correct notation
#my $cmip = '0';
if ($ipmode eq '2') {
    $cmip    = "udp6:[$cmip]";
} else {
    $cmip    = $cmip;
}

my $prefixSnmpGetCm     = "snmpget -v 2c -c $cmrw $cmip ";
my $prefixSnmpGetCmRW   = "snmpget -v 2c -c $cmrw $cmip ";
my $prefixSnmpSetCm     = "snmpset -v 2c -c $cmrw $cmip ";
my $prefixSnmpWalkCm    = "snmpbulkwalk -v 2c -Cr1 -c $cmrw $cmip ";


# ********************************************
# *** Use / Run CM Tests
# *** DOCS-PNM-MIB 
# ********************************************

# All returned data from the modem is done by TFTP bulk upload.  In order to get the TFTP file we must first set parameters
# First we must set the IP type, IPv4 = 1 or IPv6 = 2
# snmpset -v2c -c private 10.1.4.10 .1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0 i 1
print("******************************************************************* \n");
print("Configure basic settings on the Cable Modem and TFTP Server. \n");
print("******************************************************************* \n\n");

print("IP address of modem is: " . $cmip . "\n");
print("Getting modem info: \n");
my $sysDescr = '1.3.6.1.2.1.1.1.0';
my $modemInfo = `$prefixSnmpWalkCm $sysDescr`;
print($modemInfo . "\n");

# This sets the the IP type of TFTP server (1 = IPv4, 2 = IPv6)
my $docsPnmBulkDestIpAddrType = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0';
print "IP Mode: $ipmode \n";

my $setIpType = `$prefixSnmpSetCm $docsPnmBulkDestIpAddrType i $ipmode`;
print "$$docsPnmBulkDestIpAddrType";
print("Setting the IP address type (1 = IPv4, 2 = IPv6): \n " . $setIpType);

# First we must convert the PNM Server IP address from decimal to hex:
$hex_addr = 0;
if (length($pnmServerIp) > 15){
    $hex_addr = $pnmServerIp;
} else {
    $hex_addr = unpack('H*', pack('C*', split ('\.', $pnmServerIp)));
}
print("TFTP Server Hex Address is: "   . $hex_addr . "\n");


# Next we must set the Destination IP address of the PNM server in Hex format
# snmpset -v2c -c private 13.41.0.69 .1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0 x 0x0ae1c661
my $docsPnmBulkDestIpAddr = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0';
my $setIP = `$prefixSnmpSetCm $docsPnmBulkDestIpAddr x $hex_addr`;
print("Set TFTP Server Hex Set: \n" .  $setIP . "\n");

# Next we must set the directory on the PNM server where TFTP files will be uploaded
# snmpset -v2c -c private 13.41.0.69 .1.3.6.1.4.1.4491.2.1.27.1.1.1.3.0 s "/"
my $dir = "";
my $docsPnmBulkDestPath = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.3.0';
my $setPath = `$prefixSnmpSetCm $docsPnmBulkDestPath s $dir`;
print ("Set Path (Should be ''): \n" . $setPath . "\n");

# Set TFTP upload on modem INTEGER  { other ( 1 ) , tftpUpload ( 2 ) , cancelUpload ( 3 ) , deleteFile ( 4 ) } 
my $docsPnmBulkFileControl = '.1.3.6.1.4.1.4491.2.1.27.1.1.2.1.3.0';
my $setAutoload = `$prefixSnmpSetCm $docsPnmBulkFileControl i 4`;

# Then set the upload control INTEGER {other(1), noAutoUpload(2), autoUpload(3)}
# snmpset -v2c -c private 13.41.0.69 .1.3.6.1.4.1.4491.2.1.27.1.1.1.4.0 i 3
my $docsPnmBulkUploadControl = '.1.3.6.1.4.1.4491.2.1.27.1.1.1.4.0';
my $setUpload = `$prefixSnmpSetCm $docsPnmBulkUploadControl i 3`;
print ("Set upload to auto (Should = 3): \n" . $setUpload . "\n\n");

# In order for TFTP to work on the PNM server we must enable TFTP to do so follow this URL:
# http://blog.zwiegnet.com/linux-server/configure-tftp-server-centos-6/

print("******************************************************************* \n");
print("Verify modems settings are configured: \n");
print("******************************************************************* \n");

# Get IP address type
my $output = `$prefixSnmpWalkCm $docsPnmBulkDestIpAddrType`;
print("IP Address Type (1=IPv4, 2=IPv6): \n" . $output . "\n");

# Get TFTP Server IP address
$output = `$prefixSnmpWalkCm $docsPnmBulkDestIpAddr`;
print("TFTP Server IP Address in Hex Notation: \n" . $output . "\n");

# Get TFTP Server directory
$output = `$prefixSnmpWalkCm $docsPnmBulkDestPath`;
print("TFTP Server directory path (Should be blank): \n" . $output . "\n");

# Get TFTP Upload status   
$output = `$prefixSnmpWalkCm $docsPnmBulkUploadControl`;
print("TFTP Upload Status (1=other, 2=noAutoUpload, 3=AutoUpload): \n" . $output . "\n");

# Get Modem Upload type INTEGER  { other ( 1 ) , tftpUpload ( 2 ) , cancelUpload ( 3 ) , deleteFile ( 4 ) } 
$output = `$prefixSnmpWalkCm $docsPnmBulkFileControl`;

print("TFTP Upload Status (other ( 1 ) , tftpUpload ( 2 ) , cancelUpload ( 3 ) , deleteFile ( 4 )): \n" . $output . "\n\n");

my $docsPnmCmCtlTest = '.1.3.6.1.4.1.4491.2.1.27.1.2.1.1';
my $docsPnmCmCtlTestDuration    = '.1.3.6.1.4.1.4491.2.1.27.1.2.1.2'; # in seconds

# INTEGER  { other ( 1 ) , ready ( 2 ) , testInProgress ( 3 ) , tempReject ( 4 ) } 
my $docsPnmCmCtlStatus          = '.1.3.6.1.4.1.4491.2.1.27.1.2.1.3';
my $dsSpectrumAnalyzer = '.1.3.6.1.4.1.4491.2.1.20.1.34.1.0';

# First set the mode on the modem for the the test from the list above
# In the first test we will get DS OFDM Rx MER Per Sub Carrier
# dsOfdmRxMERPerSubCar(6)

print("******************************************************************* \n");
print("Set RxMER per Subcarrier UPload test. \n");
print("******************************************************************* \n\n");

# Find modem row index number with CAble TeleVision (CATV) downstream Orthogonal 
# Frequency Division Multiplexing (OFDM) interface
# IF-MIB::ifType = INTEGER: 277
my $ifType  = '1.3.6.1.2.1.2.2.1.3';
my $ofdm    = '([0-9]+) = INTEGER: 277';
#my $index   = '$1';
print("Getting the index for the OFDM channel \n");
my @rowIndex = `$prefixSnmpWalkCm $ifType`;
foreach (@rowIndex) {
    if ($_ =~ m/$ofdm/) {
       $preIndex =  $_;     
    }
}
print("The full index is:" . $preIndex . "\n");
print("Now we just need to get the .x from this to append as an index \n\n");

# Use substr to get just the index number
#my $index = substr $preIndex, 15, 1; 
$preIndex =~ m/$ofdm/;
my $index = $1;
print("The index we want is: " . $index . "\n\n");

my $docsPnmCmDsOfdmRxMerFileName = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.8.'.$index; # Set DS Rx MER file name
my $dsOfdmRxMERPerSubCarEnable = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1.'.$index; # Enables DS Rx MER
#my $dsOfdmRxMERPerSubCarEnable = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1.77';

# Set filename of test
my $filename = 'RxMerData';
my $fileset = `$prefixSnmpSetCm $docsPnmCmDsOfdmRxMerFileName s $filename`;
print("RxMER filename: \n " . $fileset ."\n\n");

# Enable the desired test - Here we will enable dsOfdmRxMERPerSubCar(6)
my $enable = `$prefixSnmpSetCm $dsOfdmRxMERPerSubCarEnable i 1`;
print("RxMER is enabled (Result should be 1): \n " . $enable ."\n\n");

# Read test status to verify it is enabled (should return value of 6 - dsOfdmRxMERPerSubCar)
my $currentTest = `$prefixSnmpWalkCm $docsPnmCmCtlTest`;
print("Current Tests value is (should be 6 for RxMER): \n" . $currentTest ."\n\n");

# Check upload status
my $docsPnmBulkFileUploadStatus = '.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.7';
$output = `$prefixSnmpWalkCm $docsPnmBulkFileUploadStatus`;
print("Upload status availableForUpload(2), uploadInProgress(3), Completed(4), uploadPending(5), uploadCancelled(6), error(7) : \n" . $output . "\n");
