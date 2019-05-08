#!/usr/bin/perl

# The full power of MTA-STS

# getmta is a subroutine that performs a MTA-STS lookup.
# This system will return a mode and a return value.
# The mode can be dane, none, enforce, testing or fail.
# If the result is enforce or testing, the return value will contain allowed mx servers.

sub getmta
{

	use strict;
	use LMDB_File qw(:flags :cursor_op);
	use File::Path qw(make_path remove_tree);
	use Mail::STS;
	use DateTime;
	use List::Util qw (any);
	my $domainname = lc shift;
	my $hostname = lc shift;

	my $TimeEpoch = DateTime->now()->epoch;
	my $path = '/var/spool/exim4/lmdb2';

# Fail quickly if there is no database or access to the database.
	eval { make_path( $path ); 1} or do { return ('fail'); };

	my $env = LMDB::Env->new($path, {
		mapsize => 100 * 1024 * 1024 * 1024,
		mode   => 0660,
	});

	my $txn = $env->BeginTxn();
	if (! $hostname) {
# Setup the vars and Mail::STS

		my $sts = Mail::STS->new;
		my $domain = $sts->domain($domainname);

		my ($DANE,$STSID, $Output, $policy, $domainReport, $policyMX, $policyMODE,
			$policyMAX, $policyMXArray, $ExpireTime, $idfromDB, $STSID, $BADID );

# Stop processing quickly if the domain has a TLSA record that identifies as DANE
		eval { $DANE = $domain->tlsa; };
		if ( $DANE ) {
			$txn->commit;
# Dane is primary. Exit out and depend on Dane
			return ('dane')
		;}

# Set the default of all good
		my $PolicyinDB = 1;
		my $PolicyinDBgood = 1;

# Setup the Databases

		my $mtaDB = $txn->OpenDB( {    # Open/Create a database for the Policy ID
			flags => MDB_CREATE
		});

# Use the Expiration time to check if the record in the db is proper.  Then check to see if it is expired.
		eval {
			$ExpireTime = $mtaDB->get("${domainname}:expire");
		 	$PolicyinDBgood = ($ExpireTime > $TimeEpoch) ? 1:0;
		} or do { $PolicyinDB = 0; };

# Use the STS id from the DNS to determind if there is an MTS-STS DNS Record
		eval {
			$domain->sts;
			$STSID = $domain->sts->id;
		} or do { $STSID = 0 };


# Only if there is a Policy in the DB and the MTA-STS version in the DNS is valid, check if the version numbers are the same.
# If not, reload the policy in the DB.
		if ( $PolicyinDB ) {
			$idfromDB = $mtaDB->get("${domainname}:id");
			if ( $STSID ) {
				if ($idfromDB != $STSID) { $PolicyinDBgood = 0 }
			}
		}

# No Policy in the DB or the policy in the DB is bad, load the policy into the DB only if the MTA-STS version in the DNS is valid.
# Fail if the Policy can't be read
		if ( (!$PolicyinDB || !$PolicyinDBgood) && $STSID ) {
			eval { $policy = $domain->policy; } or do {
				$txn->commit;
# Found a good MTA-STS DNS entry and no policy is available from the cache or http
				return ('fail');
			};
# Check for badly formatted Policy
			eval {
				$policyMXArray = $policy->mx;
				$policyMX = "@$policyMXArray";
				$policyMX =~s/ /:/g;
				$policyMODE = $policy->mode;
				$policyMAX = ($policy->max_age + $TimeEpoch);
			} or do {
				$txn->commit;
# Found some aspects of a policy, but it is badly formatted
				return ('fail');
			};

			eval { $domainReport = substr($domain->tlsrpt->rua,7); };

			$mtaDB->put("${domainname}:mode",$policyMODE,MDB_NODUPDATA);
			$mtaDB->put("${domainname}:mx","$policyMX",MDB_NODUPDATA);
			$mtaDB->put("${domainname}:expire",$policyMAX,MDB_NODUPDATA);
			$mtaDB->put("${domainname}:id",$STSID,MDB_NODUPDATA);
			$mtaDB->put("${domainname}:report",$domainReport,MDB_NODUPDATA);
			$txn->commit;
# Loaded the DB with a proper policy.  Send the current mode and have a nice day.
			return "$policyMODE";
		}

# Policy in the DB is good and it hasn't expired.
		if ( $PolicyinDB && $PolicyinDBgood ) {
			$policyMODE = $mtaDB->get("${domainname}:mode");
			$policyMX = $mtaDB->get("${domainname}:mx");
			$txn->commit;
# Current policy found in the DB.  Send the current mode.
			return "$policyMODE";
		}

# No Policy in the DB and there is no MTA-STS record in the DNS.
		$txn->commit;
		return ('none');
	} else {

# A hostname has been found in the options.  Check to see if the hostname is proper for the domainname.

		my $mtaDB = $txn->OpenDB( {    # Open/Create a database for the MX records in the Policy
	    		flags => MDB_CREATE
		});
		my $policyMX = $mtaDB->get("${domainname}:mx");
		$txn->commit;

		my %charmap = (
			'.' => '\.',
			'*' => '.*',
			':' => ':',
		);
		$policyMX =~ s{(.)} { $charmap{$1} || "\Q$1" }ge;
		my @HostNameListArray = split /:/, $policyMX;
		my $bool;
		$bool = any { $hostname=~$_ } @HostNameListArray;
		if ($bool) { return (""); }
 		return (0);
	}
}

# Simply return the MX records in the policy for limiting in EXIM
sub getmx
{
	use strict;
	use LMDB_File qw(:flags :cursor_op);
	my $domainname = lc shift;
	my $path = '/var/spool/exim4/lmdb2';

# Fail quickly if there is no database or access to the database.
	eval { make_path( $path ); 1} or do { return ('fail'); };

	my $env = LMDB::Env->new($path, {
		mapsize => 100 * 1024 * 1024 * 1024,
		mode   => 0660,
	});

	my $txn = $env->BeginTxn();
	my $mtaDB = $txn->OpenDB( {    # Open/Create a database for the MX records in the Policy
	    	flags => MDB_CREATE
	});

	my $mxReturn = $mtaDB->get("${domainname}:mx");
	$txn->commit;
	return ($mxReturn);
}
