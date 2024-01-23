#!/bin/bash

# [Equivalent comments]

# Clear screen
clear

# Check for correct number of ARGS
if [ "$#" -ne 4 ]; then
    echo "Need four arguments..."
    exit 1
fi

# Set vars from ARGS
ipmode=$1
cmip=$2
cmrw=$3
pnmServerIp=$4

# Define CM IP address in correct notation
if [ "$ipmode" -eq 2 ]; then
    cmip="udp6:[$cmip]"
fi

# Configure prefixes for SNMP to make commands simplified
prefixSnmpGetCm="snmpget -v 2c -c $cmrw $cmip"
prefixSnmpGetCmRW="snmpget -v 2c -c $cmrw $cmip"
prefixSnmpSetCm="snmpset -v 2c -c $cmrw $cmip"
prefixSnmpWalkCm="snmpbulkwalk -v 2c -Cr1 -c $cmrw $cmip"

 ********************************************
# *** Use / Run CM Tests
# *** DOCS-PNM-MIB 
# ********************************************

# All returned data from the modem is done by TFTP bulk upload.  In order to get the TFTP file we must first set parameters
# First we must set the IP type, IPv4 = 1 or IPv6 = 2
# snmpset -v2c -c private 10.1.4.10 .1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0 i 1

echo "*******************************************************************"
echo "Configure basic settings on the Cable Modem and TFTP Server."
echo "*******************************************************************"
echo ""

echo "IP address of modem is: $cmip"
echo "Getting modem info:"
sysDescr='1.3.6.1.2.1.1.1.0'
modemInfo=$($prefixSnmpWalkCm $sysDescr)
echo "$modemInfo"

# This sets the IP type of TFTP server (1 = IPv4, 2 = IPv6)
docsPnmBulkDestIpAddrType='.1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0'
echo "IP Mode: $ipmode"

setIpType=$($prefixSnmpSetCm $docsPnmBulkDestIpAddrType i $ipmode)
echo "$docsPnmBulkDestIpAddrType"
echo "Setting the IP address type (1 = IPv4, 2 = IPv6):"
echo "$setIpType"

# Convert the PNM Server IP address from decimal to hex
hex_addr=0
if [ "${#pnmServerIp}" -gt 15 ]; then
    hex_addr=$pnmServerIp
else
    # Convert decimal IP to hex
    IFS='.' read -r -a ip_array <<< "$pnmServerIp"
    hex_addr=$(printf '%02X%02X%02X%02X' "${ip_array[@]}")
fi
echo "TFTP Server Hex Address is: $hex_addr"

# Set the Destination IP address of the PNM server in Hex format
docsPnmBulkDestIpAddr='.1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0'
setIP=$($prefixSnmpSetCm $docsPnmBulkDestIpAddr x 0x$hex_addr)
echo "Set TFTP Server Hex Set:"
echo "$setIP"

# Set the directory on the PNM server where TFTP files will be uploaded
dir=""
docsPnmBulkDestPath='.1.3.6.1.4.1.4491.2.1.27.1.1.1.3.0'
setPath=$($prefixSnmpSetCm $docsPnmBulkDestPath s "$dir")
echo "Set Path (Should be ''):"
echo "$setPath"

# Set TFTP upload on modem INTEGER { other ( 1 ), tftpUpload ( 2 ), cancelUpload ( 3 ), deleteFile ( 4 ) }
docsPnmBulkFileControl='.1.3.6.1.4.1.4491.2.1.27.1.1.2.1.3.0'
setAutoload=$($prefixSnmpSetCm $docsPnmBulkFileControl i 4)

# Set the upload control INTEGER {other(1), noAutoUpload(2), autoUpload(3)}
docsPnmBulkUploadControl='.1.3.6.1.4.1.4491.2.1.27.1.1.1.4.0'
setUpload=$($prefixSnmpSetCm $docsPnmBulkUploadControl i 3)
echo "Set upload to auto (Should = 3):"
echo "$setUpload"

# For configuring TFTP on the PNM server refer to:
# http://blog.zwiegnet.com/linux-server/configure-tftp-server-centos-6/

echo "*******************************************************************"
echo "Verify modems settings are configured:"
echo "*******************************************************************"

# Get IP address type
output=$($prefixSnmpWalkCm $docsPnmBulkDestIpAddrType)
echo "IP Address Type (1=IPv4, 2=IPv6):"
echo "$output"

# Get TFTP Server IP address
output=$($prefixSnmpWalkCm $docsPnmBulkDestIpAddr)
echo "TFTP Server IP Address in Hex Notation:"
echo "$output"

# Get TFTP Server directory
output=$($prefixSnmpWalkCm $docsPnmBulkDestPath)
echo "TFTP Server directory path (Should be blank):"
echo "$output"

# Get TFTP Upload status
output=$($prefixSnmpWalkCm $docsPnmBulkUploadControl)
echo "TFTP Upload Status (1=other, 2=noAutoUpload, 3=AutoUpload):"
echo "$output"

# Get Modem Upload type INTEGER { other ( 1 ), tftpUpload ( 2 ), cancelUpload ( 3 ), deleteFile ( 4 ) }
output=$($prefixSnmpWalkCm $docsPnmBulkFileControl)
echo "TFTP Upload Status (other ( 1 ), tftpUpload ( 2 ), cancelUpload ( 3 ), deleteFile ( 4 )):"
echo "$output"

docsPnmCmCtlTest='.1.3.6.1.4.1.4491.2.1.27.1.2.1.1'
docsPnmCmCtlTestDuration='.1.3.6.1.4.1.4491.2.1.27.1.2.1.2' # in seconds

docsPnmCmCtlStatus='.1.3.6.1.4.1.4491.2.1.27.1.2.1.3'
dsSpectrumAnalyzer='.1.3.6.1.4.1.4491.2.1.20.1.34.1.0'

# The remaining part about setting the mode on the modem for the test
# and getting DS OFDM Rx MER Per Sub Carrier is not included here.
# If needed, similar conversions can be applied as shown above.

echo "*******************************************************************"
echo "Set RxMER per Subcarrier Upload test."
echo "*******************************************************************"
echo ""

ifType='1.3.6.1.2.1.2.2.1.3'
ofdm='([0-9]+) = INTEGER: 277'
echo "Getting the index for the OFDM channel"

# Fetch the row indexes and find the one matching OFDM interface
rowIndex=$($prefixSnmpWalkCm $ifType)
preIndex=""
for row in $rowIndex; do
    if [[ $row =~ $ofdm ]]; then
       preIndex=$row
       break
    fi
done

echo "The full index is: $preIndex"
echo "Now we just need to get the .x from this to append as an index"

# Extract the index number
if [[ $preIndex =~ $ofdm ]]; then
    index=${BASH_REMATCH[1]}
fi
echo "The index we want is: $index"

docsPnmCmDsOfdmRxMerFileName=".1.3.6.1.4.1.4491.2.1.27.1.2.5.1.8.$index" # Set DS Rx MER file name
dsOfdmRxMERPerSubCarEnable=".1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1.$index"   # Enables DS Rx MER

# Set filename of test
filename='RxMerData'
fileset=$($prefixSnmpSetCm $docsPnmCmDsOfdmRxMerFileName s $filename)
echo "RxMER filename:"
echo "$fileset"

# Enable the desired test - Here we will enable dsOfdmRxMERPerSubCar(6)
enable=$($prefixSnmpSetCm $dsOfdmRxMERPerSubCarEnable i 1)
echo "RxMER is enabled (Result should be 1):"
echo "$enable"

# Read test status to verify it is enabled (should return value of 6 - dsOfdmRxMERPerSubCar)
currentTest=$($prefixSnmpWalkCm $docsPnmCmCtlTest)
echo "Current Tests value is (should be 6 for RxMER):"
echo "$currentTest"

# Check upload status
docsPnmBulkFileUploadStatus='.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.7'
output=$($prefixSnmpWalkCm $docsPnmBulkFileUploadStatus)
echo "Upload status availableForUpload(2), uploadInProgress(3), Completed(4), uploadPending(5), uploadCancelled(6), error(7):"
echo "$output"
