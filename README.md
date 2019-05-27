# MTASTS-EXIM-PERL
## Perl script designed to be used by Exim for RFC 8461 MTA-STS compliance.

### Perl Dependancies:
```
File::Path
DateTime
List::Util
cpan: Mail::STS
      LMDB_File
```    


This script is designed to work with the Exim Perl interpreter.
On demand, this script will check if MTA-STS data is in a LMDB database.  If it is not then it will poll a domain for MTA-STS info and put the info into the database.  Then, respond to EXIM with required info for processing the outgoing email.

This script provides reboot resistant caching of MTA-STS data.  And if the database is not found, it will reconstruct the database and restart the caching.

There are two different subroutines:

### getmta:
#### getmta (DomainName) (HostName)
  If the HostName is not provided, this script will check the MTA-STS dns record and HTTP record. And will put the MTA-STS record into an LMDB database. The return will be "enforce", "testing", "none", "dane" or "fail".  A "fail" means that there is a problem with the MTA-STS information.
  
  If the Domain name is not in the database, the MTA-STS dns and http will be polled and checked.  The data will be placed into the LMDB database.
  
  If the Domain name is in the database, the expiration of the info will be checked.  If the info has expired, it will attempt to get a new record and put the data into the database.
  
  When the HostName is present, the script will check the LMDB database to determine if the hostname is within the MTA-STS mx records.  If it is not the return is a zero ("0"). Else nothing is returned.
  
### getmx:
#### getmx (domainname)
  Returns the MX list from the MTA-STS record as a colon seperated list.
  
Per RFC 8461, testing allows for an mta-sts failure.  So, this will only be logged at EXIM.  In the future, this can be used with the TLSRPT feature to provide a report to the server admin.
  
### LMDB Info
This database was chosen due to the speed and concurrency.  It is a Key-Value store system.
There are no named databases within the LMDB structure.

Any software that can access LMDB databse shouldn't have a problem accessing the data provided the application has rights.

The data structue is as follows:

- domainname.tld:mx
  - Contains a colon seperated list of domain names listed in the MTA-STS HTML record.  This may contain wildcards.
- domainname.tld:mode
  - Contains the mode the MTA-STS record is in.  This may be one of the following "enforce","testing" or "none"
- domainname.tld:expire
  - This contains the Unix Time that this record expires in seconds.
- domainname.tld:id
  - This is the MTA-STS id located in the MTA-STS DNS TXT record.
- domainname.tld:report
  - This is the contact URL for the RFC 8460 TLSRPT.  When it comes to the MTA-STS RFC 8461, this is only required if the mode/policy is set to "testing" and the sending server sends regular reports. At this time, the mailto: gets stripped and this only contains an email address.
	
### A few notes:
Ensure the path variable is set to someplace your Exim can read/write.  In my case it's /var/spool/exim4.

Gmail.com works perfectly as "enforced".

Outlook.com and Office365.com works as "testing" without a TLSRPT.

Yahoo.com works as "testing" with a TLSRPT.

NBC.com seems to use a wildcard in their DNS server to allow *.nbc.com TXT to respond with "inbound".  It may create failures in the MAIL::STS module. Can someone fix Comcast/NBC?

My distros LWP defaults to the system root certificates.  This may need to be adjusted for your system.   

Exim has a an experimental LMDB lookup.  This may reduce the need of the getmx script.


### Exim Configs:
```
  perl_startup = do '(Path of script)/mta-lmdb.pl'
  perl_at_start = true
```  
#### Example Exim Routers:

```
dnslookup_mtasts_enforce:
  debug_print = "R: dnslookup-mtasts-enforce for $local_part@$domain"
  driver = dnslookup
# This condition uses the getmta subroutine and returns the MTA-STS policy.  If the policy is enforce continue with this router.
  condition = ${if eq{${perl{getmta}{$domain}}}{enforce}}
  domains = ! +local_domains
# Push the mail to the remote_smtp_mtasts_enforce transport
  transport = remote_smtp_mtasts_enforce
  same_domain_copy_routing = yes
  # ignore private rfc1918 and APIPA addresses
  ignore_target_hosts = 0.0.0.0 : 127.0.0.0/8 : 192.168.0.0/16 :\
                        172.16.0.0/12 : 10.0.0.0/8 : 169.254.0.0/16 :\
			255.255.255.255
  dnssec_request_domains = *
  no_more
```
```
dnslookup_mtasts_testing:
  debug_print = "R: dnslookup-mtasts-testing for $local_part@$domain"
  driver = dnslookup
# This condition uses the getmta subroutine and returns the MTA-STS policy.  If the policy is testing continue with this router.
  condition = ${if eq{${perl{getmta}{$domain}}}{testing}}
  domains = ! +local_domains
# Push the email to the remote_smtp_mtasts_testing transport
  transport = remote_smtp_mtasts_testing
  same_domain_copy_routing = yes
  # ignore private rfc1918 and APIPA addresses
  ignore_target_hosts = 0.0.0.0 : 127.0.0.0/8 : 192.168.0.0/16 :\
                        172.16.0.0/12 : 10.0.0.0/8 : 169.254.0.0/16 :\
			255.255.255.255
  dnssec_request_domains = *
  no_more
```
```
redirect_mtasts_fail:
  debug_print = "R: redirect-mtasts-failure for $local_part@$domain $address_data"
  driver = redirect
# This condition uses the getmta subroutine and returns the MTA-STS policy.  If the policy is fail continue with this router.
  condition = ${if eq{${perl{getmta}{$domain}}}{fail}}
  domains = ! +local_domains
# Per RFC 8461 defer for another attempt later.  Hopefully the receiving agency will fix their MTA-STS.
  allow_defer
  data = :defer: MTA-STS Failure $address_data
  no_more
```

#### Example Transports (Modified from Debian):
```
remote_smtp_mtasts_enforce:
  debug_print = "T: remote_smtp_mtasts_enforce for $local_part@$domain"
  driver = smtp
# Do a full cert check on the MTA-STS mx host names
  tls_verify_cert_hostnames = {${perl{getmx}{$domain}}}
  tls_tempfail_tryclear = false
# Do not connect to any servers that are not listed in the MTA-STS mx.
  event_action = ${if eq {tcp:connect}{$event_name}{${perl{getmta}{$domain}{$host}}} {}}
.ifndef IGNORE_SMTP_LINE_LENGTH_LIMIT
  message_size_limit = ${if > {$max_received_linelength}{998} {1}{0}}
.endif
.ifdef REMOTE_SMTP_HOSTS_AVOID_TLS
  hosts_avoid_tls = REMOTE_SMTP_HOSTS_AVOID_TLS
.endif
.ifdef REMOTE_SMTP_HEADERS_REWRITE
  headers_rewrite = REMOTE_SMTP_HEADERS_REWRITE
.endif
.ifdef REMOTE_SMTP_RETURN_PATH
  return_path = REMOTE_SMTP_RETURN_PATH
.endif
.ifdef REMOTE_SMTP_HELO_DATA
  helo_data=REMOTE_SMTP_HELO_DATA
.endif
.ifdef DKIM_DOMAIN
dkim_domain = DKIM_DOMAIN
.endif
.ifdef DKIM_SELECTOR
dkim_selector = DKIM_SELECTOR
.endif
.ifdef DKIM_PRIVATE_KEY
dkim_private_key = DKIM_PRIVATE_KEY
.endif
.ifdef DKIM_CANON
dkim_canon = DKIM_CANON
.endif
.ifdef DKIM_STRICT
dkim_strict = DKIM_STRICT
.endif
.ifdef DKIM_SIGN_HEADERS
dkim_sign_headers = DKIM_SIGN_HEADERS
.endif
.ifdef TLS_DH_MIN_BITS
tls_dh_min_bits = TLS_DH_MIN_BITS
.endif
.ifdef REMOTE_SMTP_TLS_CERTIFICATE
tls_certificate = REMOTE_SMTP_TLS_CERTIFICATE
.endif
.ifdef REMOTE_SMTP_PRIVATEKEY
tls_privatekey = REMOTE_SMTP_PRIVATEKEY
.endif
.ifndef REMOTE_SMTP_DISABLE_DANE
dnssec_request_domains = *
hosts_try_dane = *
.endif
```
```
remote_smtp_mtasts_testing:
# This is just a duplicate of normal sending.  Per RFC 8461, Don't defer or delay if an MTA-STS deivery has failed if the policy is testing.
# So, don't do anything.  This would be the place for a reporting mechanism.
  debug_print = "T: remote_smtp_mtasts_testing for $local_part@$domain"
  driver = smtp
.ifndef IGNORE_SMTP_LINE_LENGTH_LIMIT
  message_size_limit = ${if > {$max_received_linelength}{998} {1}{0}}
.endif
.ifdef REMOTE_SMTP_HOSTS_AVOID_TLS
  hosts_avoid_tls = REMOTE_SMTP_HOSTS_AVOID_TLS
.endif
.ifdef REMOTE_SMTP_HEADERS_REWRITE
  headers_rewrite = REMOTE_SMTP_HEADERS_REWRITE
.endif
.ifdef REMOTE_SMTP_RETURN_PATH
  return_path = REMOTE_SMTP_RETURN_PATH
.endif
.ifdef REMOTE_SMTP_HELO_DATA
  helo_data=REMOTE_SMTP_HELO_DATA
.endif
.ifdef DKIM_DOMAIN
dkim_domain = DKIM_DOMAIN
.endif
.ifdef DKIM_SELECTOR
dkim_selector = DKIM_SELECTOR
.endif
.ifdef DKIM_PRIVATE_KEY
dkim_private_key = DKIM_PRIVATE_KEY
.endif
.ifdef DKIM_CANON
dkim_canon = DKIM_CANON
.endif
.ifdef DKIM_STRICT
dkim_strict = DKIM_STRICT
.endif
.ifdef DKIM_SIGN_HEADERS
dkim_sign_headers = DKIM_SIGN_HEADERS
.endif
.ifdef TLS_DH_MIN_BITS
tls_dh_min_bits = TLS_DH_MIN_BITS
.endif
.ifdef REMOTE_SMTP_TLS_CERTIFICATE
tls_certificate = REMOTE_SMTP_TLS_CERTIFICATE
.endif
.ifdef REMOTE_SMTP_PRIVATEKEY
tls_privatekey = REMOTE_SMTP_PRIVATEKEY
.endif
.ifndef REMOTE_SMTP_DISABLE_DANE
dnssec_request_domains = *
hosts_try_dane = *
.endif
```
  
