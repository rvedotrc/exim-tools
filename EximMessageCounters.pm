#!/usr/bin/perl
# vi: set ts=4 sw=4 :

use warnings;
use strict;

use FindBin;
use lib $FindBin::Bin;

sub main::get_exim_counters
{
	# Format of state file: four lines of text, namely:
	# (i) seek (ii) message count (iii) recipient count (iv) completed count
	my $state_file = "/var/local/exim-counters.state";

	my @files = qw(
		/var/log/exim/main.log.4
		/var/log/exim/main.log.3
		/var/log/exim/main.log.2
		/var/log/exim/main.log.1
		/var/log/exim/main.log
	);

	@files = grep { -f $_ } @files;

	use TieMultiFile;
	tie *FH, "TieMultiFile", \@files, read_all_if_got_lost => 1
		or die "tie: $!";

	my ($seek, $messages, $recipients, $completed) = (0, undef, undef, undef);

	if (open(my $fh, "<", $state_file))
	{
		($seek, $messages, $recipients, $completed) = <$fh>;
		close $fh;
		chomp($seek, $messages, $recipients, $completed);
		(tied *FH)->SEEK($seek, 0);
	} else {
		die "open $state_file: $!" unless $!{ENOENT};
	}

	my $reTimestamp = qr/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/;
	my $reMessageID = qr/\w{6}-\w{6}-\w{2}/;

	while (<FH>)
	{
		# TODO modulo 2**32?
		++$messages if /^$reTimestamp $reMessageID <= /;
		++$recipients if /^$reTimestamp $reMessageID (=>|->|\*\*) /;
		++$completed if /^$reTimestamp $reMessageID Completed$/;
	}

	$seek = tell FH;

	my $state = "$seek\n$messages\n$recipients\n$completed\n";

	my $tmp_file = "$state_file.new";

	open(my $fh, ">", $tmp_file) or die "open >$tmp_file: $!";
	use Fcntl qw( LOCK_EX );
	flock($fh, LOCK_EX) or die "flock: $!";
	print $fh $state or die "print: $!";
	truncate($fh, length($state)) or die "truncate: $!";
	rename $tmp_file, $state_file or die "rename: $!";
	close $fh or die "close: $!";

	return($messages, $recipients, $completed);
}

# Show in MRTG `backtick` format (can only show two of the counters)
printf "%s\n%s\n\n\n", get_exim_counters() unless caller;

1;
# eof EximMessageCounters.pm
