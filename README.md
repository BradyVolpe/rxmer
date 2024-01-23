# RxMER per Subcarrier Test Script

This repository contains scripts for configuring a DOCSIS 3.1 modem, locked to a downstream OFDM channel, to return RxMER per subcarrier data as a TFTP file to a defined TFTP server. The scripts are available in both Perl and Bash versions. A TFTP server setup is required for these scripts to function correctly. Instructions for configuring a TFTP server on a Linux system are provided for reference.

## Dependencies
- Perl (for Perl script)
- Bash (for Bash script)
- Required Perl Modules:
  - Data::Dumper
  - Net::Ping
  - Getopt::Std
  - Net::SNMP
- TFTP server setup
- Open network ports as needed
- Ensure the cable modem and CMTS are configured to allow TFTP file transfers

### Installation for CentOS / RHEL 7
yum install perl perl-Data-Dumper
yum install cpan -y
cpan
install "Net::Ping"
install "Getopt::Std"
install "Net::SNMP"

## Usage

### Perl Script
Run the Perl file with the following command:
perl getRxMER.pl <IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>

Example:
perl getRxMER.pl 1 10.2.4.100 public 10.1.0.71


### Bash Script
Run the Bash script with similar arguments:
./getRxMER.sh <IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>


When run against a valid modem, you will see output of each MIB (OID). The final OID will display the upload status indicating the TFTP file status.

### TFTP Server Configuration
Refer to the following steps for a suggested TFTP server configuration:

1. Install TFTP server:
    ```
    yum install tftp-server
    ```

2. Create and configure a TFTP user:
    ```
    adduser tftpd
    chown tftpd:tftpd /var/lib/tftpboot
    ```

3. Configure and enable the TFTP service:
    Edit `/etc/xinetd.d/tftpd` and set:
    ```
    disable = no
    server_args = -c -p -u tftpd -U 117 -s /var/lib/tftpboot
    ```

4. Start the TFTP service:
    ```
    service xinetd start
    ```

5. Adjust firewall settings as necessary, for example:
    ```
    iptables -I INPUT -p udp --dport 69 -j ACCEPT
    service iptables save
    chkconfig xinetd on
    ```

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
