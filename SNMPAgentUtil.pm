#!/usr/bin/perl

use warnings;
use strict;

package SNMPAgentUtil;

=head1 NAME

SNMPAgentUtil - class for creating pass_persist SNMP agents

=head1 SYNOPSIS

	# Generic use
	SNMPAgentUtil->run(%options);

	# Using get/getnext handlers:
	SNMPAgentUtil->run(
		get => sub {
			my ($oid, $self) = @_;
			...
			return($oid, $type, $value);
		},
		getnext => sub {
			my ($oid, $self) = @_;
			...
			return($oid, $type, $value);
		},
	);

	# Using a prepare_responses handler:
	SNMPAgentUtil->run(
		prepare_responses => sub {
			my ($self) = @_;
			$self->set_responses(@list_of_triplets);
		},
	);

=head1 DESCRIPTION

=head2 Contructor options

=over 4

=item in_fh => filehandle

Where requests are read from.  Defaults to C<STDIN>.

=item out_fh => filehandle

Where responses are written to.  Defaults to C<STDOUT>.

=item log_fh => filehandle

Where logging is written to, or C<undef> for no logging.  Defaults to C<undef>.

=item log_to => filename

A shortcut for opening C<filename> in "append" mode, and using that filehandle as C<log_fh>.

=item get => coderef

Sets the "get" handler.  See below.

=item getnext => coderef

Sets the "getnext" handler.  See below.

=item prepare_responses => coderef

Sets the "prepare_responses" handler.  See below.

=item idle_timeout => seconds

Sets the idle timeout, in seconds.  Default is 60.

If no requests are received after the specified time, and the most recent
request was not C<PING>, then the agent exits.  If C<idle_timeout> is zero,
this behaviour is disabled.

=back

=head2 get/getnext handlers vs. the prepare_responses handler

When a GET or GETNEXT request is received, then the C<get> or C<getnext>
handler will be used, if one was provided; otherwise, the C<prepare_responses>
handler is used; otherwise, an error occurs.

=over 4

=item get, getnext

The C<get> / C<getnext> handlers are called with two arguments: the OID in
question, and the C<$self> agent object.  The handler should return a list of
three items, namely C<$oid, $type, $value>.  Once the handler has returns
this triplet, the agent validates it (providing basic sanity checking);
if this check fails, the agent will return the response "NONE".

C<$type> must be one of: string, integer, unsigned, objectid, timeticks, ipaddress, counter, gauge

Example:

	sub my_get
	{
		my ($oid, $self) = @_;
		return(".1.3.6.1.4.1.1234", "integer", time());
	}

=item prepare_responses

If the appropriate C<get> or C<getnext> handler is missing, then the
C<prepare_responses> handler will be called instead, with three arguments:
the agent object C<$self>, the request verb (either "get" or "getnext"),
and the OID in question.

The handler should in turn call the C<set_responses> method of the agent,
passing a list of OID / type / value triplets.  For example:

	$self->set_responses(
		".1.3.6.1.4.1.1234", "integer", time(),
		".1.3.6.1.4.1.1234.11", "string", "eleven",
		".1.3.6.1.4.1.1234.2", "string", "two",
	);

Once the handler has returned the agent will then select the appropriate
triplet from the list to use as a response.

The C<prepare_responses> method is intended to be used in cases where
there is a high cost to calculating responses; for example, connecting
to a database (slow) and fetching several values (fast).  It almost
certainly makes sense to cache C<prepare_responses>, perhaps as follows:

	my $response_expires = undef;

	sub my_prepare_responses
	{
		my ($self) = @_;
		return if defined($response_expires)
			and time() < $response_expires;
		$self->set_responses(...);
		$response_expires = time() + 30;
	}

=back

=head2 Protocol Extensions

In addition to the pass_persist protocol supported by C<snmpd>, this agent
also supports the commands C<QUIT> and C<EXIT> (which are synonymous).  On
receiving these commands, or on seeing C<EOF> if at a terminal, the response
C<BYE> is given and the agent exits.

=cut

sub run
{
	my ($class, %opts) = @_;

	if (my $n = delete $opts{'log_to'})
	{
		open(my $fh, ">>$n") or die $!;
		$opts{log_fh} = $fh;
	}

	my $self = bless {
		in_fh => \*STDIN,
		out_fh => \*STDOUT,
		log_fh => undef,
		idle_timeout => 60,
		%opts,
	}, $class;

	require IO::Handle;
	$self->{out_fh}->autoflush;
	$self->{log_fh}->autoflush if $self->{log_fh};

	$self->loop;
}

sub log
{
	my $self = shift;
	my $fh = $self->{log_fh} or return;
	print $fh join "", map { "$_\n" } @_;
}

sub getline
{
	my $self = shift;
	my $fh = $self->{in_fh};

	my $l = <$fh>;
	$self->log("> <eof>"), return undef
		if not defined $l;
	chomp $l;
	$self->log("> $l");
	return $l;
}

sub putline
{
	my $self = shift;
	my $fh = $self->{out_fh};

	$self->log(map { "< $_" } @_);
	print $fh join "", map { "$_\n" } @_;
}

sub loop
{
	my $self = shift;

	$self->log("agent started");
	my $just_been_pinged = 0;
	my $idle_timeout = $self->{idle_timeout} || 0;

	for (;;)
	{
		my $l = eval {
			alarm(0);
			local $SIG{ALRM} = sub { die "TIMEOUT\n" };
			alarm($idle_timeout) if $idle_timeout and not $just_been_pinged;
			$self->getline();
		};
		alarm(0);
		exit 2 if $@ eq "TIMEOUT\n";

		# Extension:
		$self->putline("BYE"), return
		       	if not defined($l)
			or (-t $self->{in_fh} and $l =~ /^(EXIT|QUIT)$/);

		$just_been_pinged = 1, $self->putline("PONG"), next if $l eq "PING";
		$just_been_pinged = 0;

		$self->do_get($self->getline), next if $l eq "get";
		$self->do_getnext($self->getline), next if $l eq "getnext";

		$self->putline("Unknown command ($l)");
	}

	$self->log("agent finished");
}

sub do_get
{
	my $self = shift;
	my $oid = shift;

	if (my $handler = $self->{get})
	{
		my @l = &$handler($oid, $self);
		$self->validate_get_response(\@l);
		$self->putline(@l);
		return;
	}

	if (my $prepare = $self->{prepare_responses})
	{
		&$prepare($self, "get", $oid);
		my $pack = join "", pack "N*", $oid =~ /(\d+)/g;
		for my $entry (@{ $self->{responses} })
		{
			next if $entry->[0] lt $pack;
			last if $entry->[0] gt $pack;
			$self->putline(@$entry[1,2,3]);
			return;
		}
		$self->putline("NONE");
		return;
	}

	$self->log("No 'get' handler");
	$self->putline("NONE");
}

sub do_getnext
{
	my $self = shift;
	my $oid = shift;

	if (my $handler = $self->{get_next})
	{
		my @l = &$handler($oid, $self);
		$self->validate_get_response(\@l);
		$self->putline(@l);
		return;
	}

	if (my $prepare = $self->{prepare_responses})
	{
		&$prepare($self, "getnext", $oid);
		my $pack = join "", pack "N*", $oid =~ /(\d+)/g;
		for my $entry (@{ $self->{responses} })
		{
			next if $entry->[0] le $pack;
			$self->putline(@$entry[1,2,3]);
			return;
		}
		$self->putline("NONE");
		return;
	}

	$self->log("No 'get_next' handler");
	$self->putline("NONE");
}

sub validate_get_response
{
	my ($self, $lines) = @_;

	if (not @$lines)
	{
		$self->log("Replacing empty response with NONE");
		goto MAKENONE;
	}

	unless (@$lines == 3)
	{
		$self->log("Replacing invalid response '@$lines' by NONE");
		goto MAKENONE;
	}

	unless ($lines->[1] =~ /^(string|integer|unsigned|objectid|timeticks|ipaddress|counter|gauge)$/)
	{
		$self->log("Replacing invalid response '@$lines' by NONE");
		goto MAKENONE;
	}

	return;

MAKENONE:
	@$lines = "NONE";
	return;
}

sub set_responses
{
	my $self = shift;
	my @responses;

	while (@_)
	{
		my ($oid, $type, $value) = splice(@_, 0, 3);
		my $pack = join "", pack "N*", $oid =~ /(\d+)/g;
		push @responses, [ $pack, $oid, $type, $value, (unpack "H*", $pack) ];
	}

	@responses = sort { $a->[0] cmp $b->[0] } @responses;
	$self->{responses} = \@responses;
}

# Reminder doc fragment...
() = <<'EOF';

                     The first line of stdout should be the  MIB  OID  of  the
                     returning  value.   The second line should be the TYPE of
                     value returned, where TYPE is one of  the  text  strings:
                     string,  integer,  unsigned,  objectid,  timeticks, ipad-
                     dress, counter, or  gauge.   The  third  line  of  stdout
                     should be the VALUE corresponding with the returned TYPE.

                     For instance, if a script was to return the value integer
                     value   "42"   when  a  request  for  .1.3.6.1.4.100  was
                     requested, the  script  should  return  the  following  3
                     lines:

                       .1.3.6.1.4.100
                       integer
		       42

EOF

1;
# eof
