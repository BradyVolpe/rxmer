# RxMER per subcarrier Test File
This Perl script configure a DOCSIS 3.1 modem that is locked to a downstream OFDM channel and instructs the modem to return an RxMER per subcarrier data as a TFTP file to the defined TFTP server. You must setup a TFTP server, usually done on a Linux server. Configuration of a TFTP server is included as a reference in this document, but it is up to the user to complete this task (NimbleThis does not support TFTP server configuration).

The following diagram provides a high level concept of the flow between the PNM server and cable modem.
![Architecture](https://github.com/BradyVolpe/rxmer/blob/main/Architecture.png)

## Dependencies
- Perl
- Data::Dumper
- Net::Ping
- Getopt::Std
- Net::SNMP
- TFTP server
- Make sure you open ports
- Ensure the cable modem and CMTS have allowed the modem to send TFTP file to TFTP server

### CentOS / RHEL 7
    yum install perl perl-Data-Dumper
    yum install cpan -y
    cpan
        install "Net::Ping"
        install "Getopt::Std"
        install "Net::SNMP"

## Usage
Now run the perl file:

Example arguments:
    
    perl getRxMER.pl <IP MODE 1=IPv4, 2=IPv6> <CMT IP Address> <CM RW String> <PNM Server IP>

Example usage:
    
    perl getRxMER.pl 1 10.2.4.100 public 10.1.0.71

When run against a valid modem, you will see output of each MIB (OID). The very final OID will display the following:

    Upload status availableForUpload(2), uploadInProgress(3), Completed(4), uploadPending(5), uploadCancelled(6), error(7) :
    SNMPv2-SMI::enterprises.4491.2.1.27.1.2.5.1.7.3 = INTEGER: 4

Note that an Integer value of 4 is a success from the cable modem indicating that the TFTP file containing RxMER data has been "Completed" and sent to the TFTP server defined in the arguments. Next you must check the destination directory defined in the TFTP server. In the example shown below, this is:

    /var/lib/tftpboot

Looking the /var/lib/tftpboot directory we can see the file has been uploaded as:
    
    [bradyv@dev1 ~]$ cd /var/lib/tftpboot/
    [bradyv@dev1 tftpboot]$ ll
    -rw-rw----. 1 poller poller 1902 Nov  9 15:09 RxMerData

Where "RxMerData" is the filename set in the Perl script. If the file does not show up in the TFTP server, then one fo the following is occuring:
- The TFTP server is incorrectly configured
- A firewall is blocking the TFTP file
- The modem has ACLs blocking the TFTP file
- The CMTS has ACLs blocking the TFTP file
    

## TFTP suggested configuration

    yum install tftp-server
    adduser tftpd
    chown tftpd:tftpd /var/lib/tftpboot

If you are running iptables and want to save your firewall rules
    
    iptables -I INPUT -p udp --dport 69 -j ACCEPT
    service iptables save

If you want xinetd/tftpd start on boot
    
    chkconfig xinetd on

I’ve created a tftpd user and added some parameters suggested in the /usr/share/doc/tftp-server-0.49/README.security. As I want to be able to upload files I need -c and -p arguments and I’ve set the umask for the new files 117 (read write permissions for tftpd user and group). These are the lines I’ve modified in the /etc/xinitd.d/tftpd :

    disable = no
    server_args = -c -p -u tftpd -U 117 -s /var/lib/tftpboot

Finally start the xinetd service:

    service xinetd start

Your TFTPD server will be running in the UDP 69 port.
