#!/bin/bash

# Example usage: sh getRxMer.sh 1 10.2.4.100 private 10.1.0.176

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

# ********************************************
# *** Use / Run CM Tests
# *** DOCS-PNM-MIB
# ********************************************

# All returned data from the modem is done by TFTP bulk upload.  In order to get the TFTP file we must first set parameters
# First we must set the IP type, IPv4 = 1 or IPv6 = 2
# snmpset -v2c -c private 10.1.4.10 .1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0 i 1

echo "*******************************************************************"
echo "Configure basic settings on the Cable Modem and TFTP Server."
echo -e "*******************************************************************\n"

echo "IP address of modem is: $cmip"
echo "Getting modem info:"
sysDescr='1.3.6.1.2.1.1.1.0'
modemInfo=$($prefixSnmpWalkCm $sysDescr)
echo -e "$modemInfo\n"

# This sets the IP type of TFTP server (1 = IPv4, 2 = IPv6)
docsPnmBulkDestIpAddrType='.1.3.6.1.4.1.4491.2.1.27.1.1.1.1.0'
echo -e "IP Mode: $ipmode\n"

setIpType=$($prefixSnmpSetCm $docsPnmBulkDestIpAddrType i $ipmode)
echo "Setting the IP address type (1 = IPv4, 2 = IPv6):"
echo -e "$setIpType\n"

# Convert the PNM Server IP address from decimal to hex
hex_addr=0
if [ "${#pnmServerIp}" -gt 15 ]; then
    hex_addr=$pnmServerIp
else
    # Convert decimal IP to hex
    IFS='.' read -r -a ip_array <<< "$pnmServerIp"
    hex_addr=$(printf '0x%02X%02X%02X%02X' "${ip_array[@]}")
fi
echo -e "TFTP Server Hex Address is: $hex_addr \n"

# Set the Destination IP address of the PNM server in Hex format
docsPnmBulkDestIpAddr='.1.3.6.1.4.1.4491.2.1.27.1.1.1.2.0'
setIP=$($prefixSnmpSetCm $docsPnmBulkDestIpAddr x $hex_addr)
echo "Set TFTP Server Hex Set:"
echo -e "$setIP\n"

# Set the directory on the PNM server where TFTP files will be uploaded --> Defaults to TFTP root
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
echo -e "$setUpload\n"

# For configuring TFTP on the PNM server refer to:
# http://blog.zwiegnet.com/linux-server/configure-tftp-server-centos-6/

echo "*******************************************************************"
echo "Verify modems settings are configured:"
echo "*******************************************************************"

# Get IP address type
output=$($prefixSnmpWalkCm $docsPnmBulkDestIpAddrType)
echo "IP Address Type (1=IPv4, 2=IPv6):"
echo -e "$output\n"

# Get TFTP Server IP address
output=$($prefixSnmpWalkCm $docsPnmBulkDestIpAddr)
echo "TFTP Server IP Address in Hex Notation:"
echo -e "$output\n"

# Get TFTP Server directory
output=$($prefixSnmpWalkCm $docsPnmBulkDestPath)
echo "TFTP Server directory path (Should be blank):"
echo -e "$output\n"

# Get TFTP Upload status
output=$($prefixSnmpWalkCm $docsPnmBulkUploadControl)
echo "TFTP Upload Status (1=other, 2=noAutoUpload, 3=AutoUpload):"
echo -e "$output\n"

# Get Modem Upload type INTEGER { other ( 1 ), tftpUpload ( 2 ), cancelUpload ( 3 ), deleteFile ( 4 ) }
output=$($prefixSnmpWalkCm $docsPnmBulkFileControl)
echo "TFTP Upload Status (other ( 1 ), tftpUpload ( 2 ), cancelUpload ( 3 ), deleteFile ( 4 )):"
echo -e "$output\n"

docsPnmCmCtlTest='.1.3.6.1.4.1.4491.2.1.27.1.2.1.1'
docsPnmCmCtlTestDuration='.1.3.6.1.4.1.4491.2.1.27.1.2.1.2' # in seconds

docsPnmCmCtlStatus='.1.3.6.1.4.1.4491.2.1.27.1.2.1.3'
dsSpectrumAnalyzer='.1.3.6.1.4.1.4491.2.1.20.1.34.1.0'

# The remaining part about setting the mode on the modem for the test
# and getting DS OFDM Rx MER Per Sub Carrier is not included here.
# If needed, similar conversions can be applied as shown above.

echo "*******************************************************************"
echo "Set RxMER per Subcarrier Upload test."
echo -e "*******************************************************************\n"


ifType='1.3.6.1.2.1.2.2.1.3'
ofdm='docsOfdmDownstream\(277\)'
echo "Getting the index for the OFDM channel..."

# Temporary file to hold the processed SNMP walk output
tempFile=$(mktemp)

# Ensure temporary file gets deleted on script exit
trap "rm -f $tempFile" EXIT

# Process the SNMP walk output and store it in a temporary file
$prefixSnmpWalkCm $ifType | tr -d '\n' | sed 's/IF-MIB::ifType\./\nIF-MIB::ifType\./g' > $tempFile
index=""
<<'END_COMMENT'
# Read from the temporary file
while IFS= read -r line; do
    echo $line
    if [[ $line =~ $ofdm ]]; then
        if [[ $line =~ IF-MIB::ifType\.([0-9]+) ]]; then
            index="${BASH_REMATCH[1]}"
            echo "OFDM channel index found: $index"
            break
        fi
    fi
done < "$tempFile"

# Use index as needed...
if [ -z "$index" ]; then
    echo "No OFDM channel index found."
else
    echo "OFDM channel index: $index"
fi

END_COMMENT

index="79"

docsPnmCmDsOfdmRxMerFileName=".1.3.6.1.4.1.4491.2.1.27.1.2.5.1.8.$index" # Set DS Rx MER file name
echo $docsPnmCmDsOfdmRxMerFileName
dsOfdmRxMERPerSubCarEnable=".1.3.6.1.4.1.4491.2.1.27.1.2.5.1.1.$index"   # Enables DS Rx MER

# Set filename of test --> Default will provide modem MAC
#filename='RxMerData'
#fileset=$($prefixSnmpSetCm $docsPnmCmDsOfdmRxMerFileName s $filename)
#echo "RxMER filename:"
#echo "$fileset\n"

# Enable the desired test - Here we will enable dsOfdmRxMERPerSubCar(6)
enable=$($prefixSnmpSetCm $dsOfdmRxMERPerSubCarEnable i 1)
echo "RxMER is enabled (Result should be 1):"
echo -e "$enable\n"

# Read test status to verify it is enabled (should return value of 6 - dsOfdmRxMERPerSubCar)
currentTest=$($prefixSnmpWalkCm $docsPnmCmCtlTest)
echo "Current Tests value is (should be 6 for RxMER):"
echo -e "$currentTest\n"

# Check upload status
docsPnmBulkFileUploadStatus='.1.3.6.1.4.1.4491.2.1.27.1.2.5.1.7'
output=$($prefixSnmpWalkCm $docsPnmBulkFileUploadStatus)
echo "Upload status availableForUpload(2), uploadInProgress(3), Completed(4), uploadPending(5), uploadCancelled(6), error(7):"
echo -e "$output\n"