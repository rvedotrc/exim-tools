#!/usr/bin/perl

use warnings;
use strict;

package TieMultiFile;

use POSIX qw( SEEK_SET SEEK_END );

=pod

=head1 NAME

TieMultiFile - treat an ordered list of files as a single file

=head1 SYNOPSIS

	require TieMultiFile;
	tie *LOG, 'TieMultiFile', [qw( log.3 log.2 log.1 log )];

	while (<LOG>) { ... }

	$pos = tell(LOG);
	# save_to_non_volatile_storage($pos);

Later on, in another run....

	require TieMultiFile;
	tie *LOG, 'TieMultiFile', [qw( log.3 log.2 log.1 log )];

	# $pos = get_pos_from_non_volatile_storage();
	(tied *LOG)->SEEK($pos);

	# carry on reading from where we left off, even if the log files
	# have been rotated.

=head1 DESCRIPTION

C<TieMultiFile> is intended to be used to read log files which get rotated,
e.g. C</var/log/messages>.  Compressed files are not supported.  The general
technique is that you name all of the files which you want to read, in
oldest-to-newest order, then use C<tie> to group them together into a single
filehandle:

	@files = qw(
		/var/log/messages.4
		/var/log/messages.3
		/var/log/messages.2
		/var/log/messages.1
		/var/log/messages
	);
	tie *MESSAGES, "TieMultiFile", \@files;

Once you have the tied filehandle, use the usual "readline" loop to read lines,
usually until you hit end-of-file:

	while (<MESSAGES>)
	{
		...
	}

You can then save your position using C<tell>:

	save_to_non_volatile_storage(tell(MESSAGES));

On a subsequent run, you can seek back to the same position (which might now be
in one of the "rotated" files) and continue reading:

	use POSIX qw( SEEK_SET );
	$pos = get_pos_from_non_volatile_storage();
	(tied *HANDLE)->SEEK($pos, SEEK_SET);

	while (<MESSAGES>)
	{
		...
	}

=head2 METHODS

=over 4

=item constructor

	tie(*HANDLE, 'TieMultiFile', \@log_files, %opts);

Recognised options are:

=over 4

=item read_all_if_got_lost

If we read off end-of-file of one of the files and can't work out
which file is next (for example the file we were reading got unlinked while we
were reading it), then the behaviour is controlled by C<read_all_if_got_lost>.
If true, then reading continues from the start of the oldest file.  If false,
reading continues from the end of the newest file.

=back

=cut

sub TIEHANDLE
{
	my ($class, $files, %opts) = @_;
	my $self = bless {
		%opts,
		FILES => [ reverse @$files ],
		FH => undef,
	}, $class;
	return $self;
}

sub debug
{
	my $old = $_[0]{debug};
	$_[0]{debug} = $_[1] if @_ > 1;
	return $old;
}

sub log
{
	my ($self, $msg) = @_;
	warn "$msg\n" if $self->{debug};
}

sub logf
{
	my ($self, $fmt, @args) = @_;
	$self->log(sprintf $fmt, @args);
}

=item SEEK

	(tied *HANDLE)->SEEK($pos, $type);

The value returned by C<tell(HANDLE)> is not just an integer (in the way that it
is for "normal" files); rather, it is an opaque value.  However whereas Perl's
tied filehandle interface allows C<tell> to return an opaque value, it does not
allow an opaque value to be passed back to C<seek(HANDLE, ...)>.  Hence, we have to
use the technique above.

Seeking to start-of-file (C< 0, SEEK_SET >) seeks to the start of the oldest file.
Seeking to end-of-file (C< 0, SEEK_END >) seeks to the end of the newest file.
Seeking to an opaque value as returned by C<tell> (C< $opaque, SEEK_SET >) seeks to
that position.  All other seeks are unsupported.

=cut

sub SEEK
{
	my ($self, $to, $type) = @_;
	my $to_n = do { no warnings; 0+$to };

	$self->logf("SEEK(%s=%s,%s)", $to, $to_n, $type);

	if ($type == SEEK_SET and my ($pos, $dev, $ino) = $to =~ /\A(\d+) (\d+) (\d+)\z/)
	{
		my $fh = $self->open_dev_ino($dev, $ino)
			or die "Seek ($dev, $ino, $self->{FILES}[0]) failed (file not found)";
		seek($fh, $pos, SEEK_SET)
			or die $!;
		return $self->TELL;
	}

	if ($type == SEEK_SET and $to_n == 0)
	{
		$self->open_oldest;
		return $self->TELL;
	}

	if ($type == SEEK_END and $to_n == 0)
	{
		$self->open_newest;
		return $self->TELL;
	}

	die "Unsupported seek (bad type; to=$to type=$type)";
}

=item tell(HANDLE)

C<tell> returns an opaque value which can be used to C<seek> back to the same
position in the same file later on, even if the log files got rotated.  See C<SEEK>.

=cut

sub TELL
{
	my ($self) = @_;
	my $fh = $self->{FH}
		or return '0 but true';
	return sprintf "%s %s %s",
		0+tell($fh), (stat $fh)[0,1];
}

=item $line = <HANDLE>

Use the "readline" interface to read the next line, e.g.

	while (<HANDLE>) { ... }

If no C<SEEK> has yet been performed, then an implicit seek to the start of the
oldest file is done first.

If end-of-file is reached on one of the files, an attempt is made to open and next
file along (and start reading from the beginning of that file).  If there are no
more files (i.e. we reached EOF of the newest file), then C<undef> is returned.
If we couldn't work out which file is "next", then the behaviour depends on
C<read_all_if_got_lost>.

=cut

sub READLINE
{
	my ($self) = @_;
	die if wantarray;

	my $fh = ($self->{FH} || $self->open_oldest)
		or return undef;
	my $line = <$fh>;
	return $line if defined $line;

	# We have reached EOF
	$self->log("EOF read");

	# Are we at the newest file already?
	my @cur_stat = stat $fh;
	my @new_stat = stat $self->{FILES}->[0];
	$self->logf("cur=%d/%d newest=%d/%d", @cur_stat[0,1], @new_stat[0,1]);
	if (@cur_stat and @new_stat
			and $cur_stat[0] == $new_stat[0]
			and $cur_stat[1] == $new_stat[1]
	) {
		# Yes; reset the EOF condition and return undef
		$self->log("Reached end of newest file");
		seek($fh, tell($fh), 0) or die $!;
		$self->logf("Reset to %s", $self->TELL);
		return undef;
	}

	# No, there are more files.
	$self->log("Reached end of non-newest file");
	# Work out which is the next newest file and start at the beginning of
	# that one
	my @f = @{ $self->{FILES} };
	for my $i (1..$#f)
	{
		my @stat = stat $f[$i]
			or next;
		next unless $stat[0] == $cur_stat[0] and $stat[1] == $cur_stat[1];
		$self->logf("Reached end of file #%d '%s' - next file is '%s'", $i, $f[$i], $f[$i-1]);
		my $next_file = $f[$i-1];
		open(my $fh, "<", $next_file)
			or die $!;
		close($self->{FH});
		$self->{FH} = $fh;
		$self->logf("New pos is %s", $self->TELL);
		return scalar <$fh>;
	}

	# We reached the end of some file, but it doesn't seem to be any of the
	# files we know about.  Maybe the files got rotated faster than we read
	# them (or maybe the file simply got deleted).

	if ($self->{read_all_if_got_lost})
	{
		$self->log("Got lost: reading from BOF of oldest file");
		$fh = $self->open_oldest;
	} else {
		$self->log("Got lost: reading from EOF of newest file");
		$fh = $self->open_newest;
	}

	$self->logf("pos is now %s", $self->TELL);

	$fh or return undef;
	return scalar <$fh>;
}

sub open_oldest
{
	my ($self) = @_;
	$self->close;

	for my $file (reverse @{ $self->{FILES} })
	{
		if (open(my $fh, "<", $file))
		{
			return($self->{FH} = $fh);
		}
		warn "open $file: $!" unless $!{ENOENT};
	}

	return($self->{FH} = undef);
}

sub open_newest
{
	my ($self) = @_;
	$self->close;

	for my $file ($self->{FILES}->[0])
	{
		if (open(my $fh, "<", $file))
		{
			seek($fh, 0, SEEK_END) or die $!;
			return($self->{FH} = $fh);
		}
		warn "open $file: $!" unless $!{ENOENT};
	}

	return($self->{FH} = undef);
}

sub open_dev_ino
{
	my ($self, $dev, $ino) = @_;

	if (my $fh = $self->{FH})
	{
		return $fh
			if stat($fh)
			and (stat _)[0] == $dev
			and (stat _)[1] == $ino;
	}

	for my $file (reverse @{ $self->{FILES} })
	{
		if (open(my $fh, "<", $file))
		{
			my @s = stat $fh or die $!;
			close($fh), next unless $s[0] == $dev and $s[1] == $ino;
			return($self->{FH} = $fh);
		}
		warn "open $file: $!" unless $!{ENOENT};
	}

	return($self->{FH} = undef);
}

sub close
{
	my ($self) = @_;
	my $fh = delete $self->{FH}
		or return;
	close $fh;
}

=pod

=back

=head2 Unsupported Methods

C<eof>, C<close> and many others.

=head1 AUTHOR

Rachel Evans

=cut

1;
# eof
