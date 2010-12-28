#!/usr/bin/perl

use warnings;
use strict;

################################################################################

package EximQueue;

use constant DEFAULT_QUEUE_DIR => "/var/spool/exim4";

sub new
{
	my ($class, $dir) = @_;
	$dir = DEFAULT_QUEUE_DIR unless defined $dir;
	return bless {
		DIR => $dir,
	}, $class;
}

sub dir { $_[0]{DIR} }

sub scan
{
	my ($self, $callback) = @_;
	my $dir = $self->{DIR};

	opendir(my $dh, "$dir/input") or die $!;

	while (defined(my $id = readdir $dh))
	{
		$id =~ s/-H$// or next;

		my $body_fh;
		unless (open($body_fh, "<", "$dir/input/$id-D"))
		{
			next if $!{ENOENT};
			warn "open $id-D: $!\n";
			next;
		}
		scalar <$body_fh>;

		my $bytes = -s($body_fh);
		my $mtime = (stat _)[9];
		$bytes -= tell($body_fh);

		my $fh;
		unless (open($fh, "<", "$dir/input/$id-H"))
		{
			close $body_fh;
			next if $!{ENOENT};
			warn "open $id-H: $!\n";
			next;
		}

		my $ent = parse_h_fh($fh);
		close $fh;

		$ent->{queue} = $self;
		$ent->{full_path} = "$dir/input/$id-H";
		$ent->{message_id} = $id;

		my $p = {
			queue => $self,
			full_path => "$dir/input/$id-H",
			message_id => $id,
			body_fh => $body_fh,
			size => $bytes,
			mtime => $mtime,
			%$ent,
		};

		my $item = EximQueueItem->new($p);
		&$callback($item);
	}

	closedir($dh);
}

sub parse_h_fh
{
	my ($fh) = @_;
	my $ent = {};

	# See the Exim Spec, "Format of the -H file"

	my $top = do { local $/; <$fh> };
	$ent->{_all} = $top;

	$top =~ s/\A(\w{6}-\w{6}-\w{2})-H\n// or die "? $top";
	$ent->{id} = $1;

	# username uid gid
	$top =~ s/\A([\w-]+) (\d+) (\d+)\n// or die "? $top";

	# sender
	$top =~ s/\A<(.*)>\n// or die "? $top";
	$ent->{sender} = $1;

	# time received / number of delay warnings sent
	$top =~ s/\A(\d+) (\d+)\n// or die "? $top";

	# helo_name etc
	while ($top =~ s/\A-(\w+)(?: (.*))?\n//)
	{
		my ($k, $v) = ($1, $2);
		$v = "true" if not defined $v;

		if ($k eq "acl" and $v =~ /^(\d+) (\d+)$/)
		{
			my ($varnum, $length) = ($1, $2);
			$v = substr($top, 0, $length, '');
			defined($v) or die;
			$top =~ s/\A\n// or die "Newline missing after acl $varnum in $ent->{id}: $top";
			$k = ($varnum < 10 ? "acl_c_$varnum" : "acl_m_".($varnum-10));
		}

		if ($k =~ /^acl[mc]$/ and $v =~ /^(\d+) (\d+)$/)
		{
			my ($varnum, $length) = ($1, $2);
			$v = substr($top, 0, $length, '');
			defined($v) or die;
			$top =~ s/\A\n// or die "Newline missing after acl $varnum in $ent->{id}: $top";
			$k = "acl_".substr($k,3,1)."_$varnum";
		}

		$ent->{options}{$k} = $v;
	}

	my %done_recipients;
	unless ($top =~ s/\AXX\n//)
	{
		our $read_tree;
		$read_tree = sub {
			my ($indent) = (@_);
			$top =~ s/\A([YN])([YN]) (.*)\n// or die "error reading $ent->{id}: $top";
			my ($has_left, $has_right, $addr) = ($1, $2, $3);
			$done_recipients{$addr} = 1;

			my $out = "$addr\n";
			$out = &$read_tree("  ") . $out if $has_left eq "Y";
			$out = $out . &$read_tree("  ") if $has_right eq "Y";

			$out =~ s/^/$indent/mg;
			return $out;
		};
		$ent->{tree} = &$read_tree("");
	}

	$top =~ s/\A(\d+)\n// or die "? $top";
	my $num_recipients = $1;
	$ent->{num_recipients} = $num_recipients;

	my %r;
	for (1..$num_recipients)
	{
		$top =~ s/\A(\S+)\n// or die "? $top";
		$r{$1} = ($done_recipients{$1} ? 1 : 0);
	}
	$ent->{rcpt} = \%r;

	$top =~ s/\A\n// or die "? $top";

	if (($ent->{options}{host_address}||"") =~ /^(\d+\.\d+\.\d+\.\d+)\.(\d+)$/)
	{
		$ent->{ip} = $1;
	}

	$ent->{s} = $ent->{sender};
	$ent->{r} = $ent->{recipients};

	open(my $hfh, "<", \$top);
	($ent->{headers}, $ent->{last_headers}) = read_headers($hfh);

	# use Data::Dumper;
	# print Data::Dumper->Dump([ $ent ],[ 'ent' ]);

	return $ent;
}

sub read_headers
{
	my ($fh) = @_;
	my $all = do { local $/; <$fh> };

	my @h;
	my %last;

	while ($all)
	{
		$all =~ s/\A(\d+)(.) // or die "? $all";
		my ($len, $flag) = ($1, $2);
		$flag = "" if $flag eq " ";
		my $data = substr($all, 0, $len, "");
		chomp $data;

		push @h, $data;
		(my $tag, $data) = $data =~ /\A(.*?):\s*(.*)\z/s;
		# push @h, [ $tag, $data, $flag ];

		$data =~ s/\n\s+/ /g;
		$last{lc $tag} = $data;
	}

	return(\@h, \%last);
}

################################################################################

package EximQueueItem;

sub new
{
	my ($class, $p) = @_;
	return bless $p, $class;
}

sub get_header
{
	my ($self, $tag) = @_;
	return $self->{last_headers}{lc $tag},
	# TODO list context
}

sub get_sending_peer
{
	my ($self) = @_;
	return {
		ptr	=> $self->{options}{host_name},
		helo	=> $self->{options}{helo_name},
		ip	=> $self->{ip},
	}
}

sub move_to_queue
{
	my ($self, $todir) = @_;
	my $fromdir = $self->{queue}->dir;

	unless ((stat $fromdir)[0] == (stat $todir)[0])
	{
		die "Can't move messages across filesystems";
	}

	if ((stat $fromdir)[1] == (stat $todir)[1])
	{
		die "Target directory is the same as source directory\n";
	}

	my $lockfh = $self->lock
		or warn("Can't move locked message $self->{id}\n"), return;

	my @files = (
		"input/" . $self->{id} . "-H",
		"input/" . $self->{id} . "-D",
		"msglog/" . $self->{id},
	);

	# TODO how to claim and lock the ID in the target queue?
	die "ID $self->{id} already exists in $todir"
		if grep { -e "$todir/$_" } @files;

	for my $file (@files)
	{
		rename "$fromdir/$file", "$todir/$file"
			or warn "rename $fromdir/$file => $todir/$file: $!\n";
	}

	close $lockfh;
}

$^O eq "linux" or die "Unsupported platform";
*pack_fcntl = sub { pack "ssVVV", @_ };
use constant F_SETLK => 6; # Fcntl F_SETLK is actually F_SETLK64

sub lock
{
	my ($self) = @_;
	my $D = $self->{queue}->dir . "/input/" . $self->{id} . "-D";
	open(my $fh, "+<", $D)
		or die "open $D: $!";

	use Fcntl qw( F_WRLCK SEEK_SET );

	my $flock = pack_fcntl(
                F_WRLCK, # type
                SEEK_SET, # whence
                0, # start
                19, # len - length of an Exim ID (xxxxxx-yyyyyy-zz\n) plus a bit?
                0, # pid
        );

	if (fcntl($fh, F_SETLK, $flock))
	{
		return $fh;
	}

	if ($!{EAGAIN} or $!{EACCES})
	{
		return undef;
	}

	die "fcntl F_SETLK on $D: $!";
}

sub compile_filter
{
	my ($class, $filter) = @_;
	$filter =~ /\S/ or return undef;

	my %replace = (
		IP => '$peer->{ip}',
		ID => '$p->{message_id}',
		SIZE => '$p->{size}',
		SUBJECT => '$subject',
		SENDER => '$p->{sender}',
		RECIPIENTS => 'join("\n", keys %{ $p->{rcpt} })',
	);

	my $reIP = qr/\d+\.\d+\.\d+\.\d+/;
	$filter =~ s/^($reIP)$/IP eq '$1'/g;
	$filter =~ s/\b IP \s* (?:==?|eq) \s*($reIP) \b/IP eq '$1'/gx;
	$filter =~ s/\b IP \s* (?:!=|<>|ne) \s*($reIP) \b/IP ne '$1'/gx;

	my $re = join "|", keys %replace;
	$filter =~ s/\b($re)\b/$replace{$1}/g;

	warn "Using filter: $filter " if $ENV{DEBUG};

	my $sub = eval '
		sub {
		       	my $p = shift;
			my $r = $p->{rcpt};
			my $peer = $p->get_sending_peer;
			my $subject = $p->get_header("Subject");
			no warnings "uninitialized";
			' . $filter . '
		}
	';
	die "Failed to compile filter ($filter): $@" if $@;

	return $sub;
}

sub matches_filter
{
	my ($self, $filter) = @_;
	return 1 unless defined $filter;
	return &$filter($self);
}

################################################################################

unless (caller)
{
	my $q = EximQueue->new;
	$q->scan_remote(sub {
		my $p = shift;
		() = $p->get_sending_peer;
		$p->{subject} = $p->get_header("Subject");
		$p->{contenttype} = $p->get_header("Content-Type");
		use Data::Dumper;
		print Data::Dumper->Dump([ $p ],[ 'p' ]);
		print "\n";
	});
}

1;
# eof
