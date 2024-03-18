# RxMER per Subcarrier Test Scripts

This repository contains two scripts for configuring a DOCSIS 3.1 modem, locked to a downstream OFDM channel, to return RxMER (Receiver Modulation Error Ratio) per subcarrier data as a TFTP (Trivial File Transfer Protocol) file to a defined TFTP server. The scripts are implemented in Perl and Bash, providing similar functionality across different scripting environments. A TFTP server setup is required for these scripts to function correctly. Instructions for configuring a TFTP server on a Linux system are provided for reference.

## Table of Contents
- [Dependencies](#dependencies)
- [Installation](#installation)
  - [CentOS / RHEL 7](#installation-for-centos--rhel-7)
- [Usage](#usage)
  - [Perl Script](#perl-script)
  - [Bash Script](#bash-script)
- [TFTP Server Configuration](#tftp-server-configuration)
- [License](#license)

## Dependencies
- Perl (for the Perl script)
- Bash (for the Bash script)
- Required Perl Modules (for the Perl script):
  - `Data::Dumper`
  - `Net::Ping`
  - `Getopt::Std`
  - `Net::SNMP`
- TFTP server setup
- Open network ports as needed
- Ensure the cable modem and CMTS (Cable Modem Termination System) are configured to allow TFTP file transfers

## Installation

### Installation for CentOS / RHEL 7
To prepare your system for running the scripts, install the necessary packages and Perl modules:
```bash
yum install perl perl-Data-Dumper
yum install cpan -y
cpan
install Net::Ping
install Getopt::Std
install Net::SNMP
```
## Usage

Both scripts are designed to obtain RxMER per subcarrier data from a cable modem. Use the appropriate script based on your scripting environment or preference.

### Perl Script

To run the Perl script, use the following command:

```Perl
perl getRxMER.pl <IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>
```
To run the bash script, use the following command:

```bash
sh getRxMER.sh <IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>

```Example 
sh getRxMER.sh 1 10.2.4.100 private 10.1.0.176

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
