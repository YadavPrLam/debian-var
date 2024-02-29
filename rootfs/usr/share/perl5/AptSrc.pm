#!/usr/bin/perl
package AptSrc;

use warnings;
use strict;
use Cwd q{realpath};
use AptPkg::Config q{$_config};
use AptPkg::System q{$_system};
use AptPkg::Version;
use AptPkg::Source;
use AptPkg::Cache;
use Fcntl qw(:DEFAULT :flock);
use Carp;

# AptPkg init blah.
$_config->init;
$_config->{quiet} = 2;
$_system = $_config->system;
our $vs = $_system->versioning;
our $aptsrc = AptPkg::Source->new;
our $aptcache = AptPkg::Cache->new;

# Holds installed sources; read from the status file.
our %sources;

# Directory limit.
our $loclimit;

# Whether the status file is opened readonly, or for writing too.
our $writestatus;

# Filehandle locking status file.
my $statuslock;

# Holds error unwind subs.
our @unwind;

# Pass an AptPkg::Config in, and it will be used to configure this module.
sub config {
	my $class=shift;
	$_config=shift;
}

# Save the status file at program end, if it was opened for writing.
sub END {
	AptSrc->writestatus() if $writestatus;
}

sub statusdir {
	my $class=shift;
	return "$ENV{HOME}/.apt-src/";
}

sub statusfile {
	my $class=shift;
        return $class->statusdir()."/status";
}

# If writestatus is set to true, it will lock the status file for writing.
sub readstatus {
	my $class=shift;
	$writestatus=shift;
	my $fn=$class->statusfile();

	if (! -e $fn) {
		# Set up an empty file, and lock that.
		if ($writestatus) {
			$class->writestatus;
		}
		else {
			return;
		}
	}
	
	open($statuslock, $fn) || $class->error("read $fn: $!");

	if ($writestatus) {
		if (! flock($statuslock, LOCK_EX | LOCK_NB)) {
			$writestatus=0; # don't zero file!
			$class->error("$fn is locked by another process");
		}
	}
	
	{
		local $/="\n\n";
		while (<$statuslock>) {
			my %rec;
			foreach my $line (split /\n/, $_) {
				my ($key, $value) = split /:\s*/, $line, 2;
				$rec{lc($key)}=$value;
			}
			my $item=$class->new(%rec);

			# Make sure that the item still exists, and check
			# for a locally changed version.
			if (! -d $item->location) {
				delete $sources{$item->location};
			}
			elsif (open(APTSRC_CHANGELOG, $item->location."/debian/changelog")) {
				my $line=<APTSRC_CHANGELOG>;
				close APTSRC_CHANGELOG;
				if ($line =~ /^([^\s]+)\s+\(([^)]+)\)/) {
					my $source=$1;
					my $version=$2;
					$item->source($source);
					$item->version($version);
				}
				else {
					$item->warning("cannot parse ".$item->location."/debian/changelog");
				}
			}
			else {
				$item->warning("cannot read ".$item->location."/debian/changelog");
			}
		}
	}

	close $statuslock unless $writestatus;
}

sub writestatus {
	my $class=shift;
	my $fn=$class->statusfile();
	
	if (! $writestatus) {
		$class->error("writestatus called with read-only status file");
	}
	
	if (! -e AptSrc->statusdir) {
		mkdir AptSrc->statusdir
			|| AptSrc->error("Unable to create status directory: $!");
	}
	
	open(my $status, ">$fn.new") || $class->error("write $fn.new: $!");
	
	foreach my $k (keys %sources) {
		my $item=$sources{$k};
		next if $item->{status} eq 'removed';
		foreach my $key (sort keys %$item) {
			print $status ucfirst($key).": ".$item->{$key}."\n";
		}
		print $status "\n";
	}
	close $status;
	rename("$fn.new", $fn) || $class->error("rename $fn.new to $fn failed: $!");
}

# Pass a directory, and any packages in that directory will be acted on, but
# no others. Without parameters, returns the current loclimit.
sub loclimit {
	my $class=shift;
	if (@_) {
		return $loclimit=realpath(shift);
	}
	else {
		return $loclimit;
	}
}

# Returns true if the item patches the location limit, or there is no
# limit.
sub meets_loclimit {
	my $this=shift;
	
	return 1 if ! $loclimit ||
	            $loclimit eq $this->basedir ||
	            $loclimit eq $this->location;
	return 0;
}

# May be passed a hash of the item's contents.
sub new {
	my $proto = shift;
	my %fields=@_;
	my $class = ref($proto) || $proto;
	my $this=bless ({%fields}, $class);
	if (exists $this->{location}) {
		$sources{$this->{location}}=$this;
	}
	else {
		$this->updatelocation;
	}
	return $this;
}

# Returns the set of all installed sources.
sub installed {
	my $class=shift;
	my $this=shift;

	return grep { $_->status eq "installed" && $_->meets_loclimit }
	       values %sources;
}

# Returns the set of all unpacked but not yet fully installed sources.
sub unpacked {
	my $class=shift;
	my $this=shift;

	return grep { $_->status eq "unpacked" && $_->meets_loclimit }
	       values %sources;
}

# Returns all sources that match the passed name or names. The names can
# include regexps, as well.
sub match {
	my $class=shift;
	
	# Build up a regexp that will match the requested names.
	my $regexp=join("|", map {
		my $source = ($class->findsource($_))[1];
		$source=$_ unless defined $source;
		$source;
	} @_);
	return grep { $_->{source} =~ m/^($regexp)$/ && $_->meets_loclimit }
	       values %sources;
}

# Returns all known sources (that match the loclimit).
sub all {
	return grep { $_->meets_loclimit } values %sources;
}

# Finds a source package matching the input, and returns the version number
# and source package name. The input can be the name of a binary or source
# package, and can have =version prepended to specify a specific version,
# or /release prepended to specify a specific release.
sub findsource {
	my $class=shift;
	my $spec=shift;
	
	my $reqversion;
	my $reqrelease;
	if ($spec =~ /(.*)=(.*)/) {
		$reqversion=$2;
		$spec=$1;
	}
	elsif ($spec =~ /(.*)\/(.*)/) {
		$reqrelease=$2;
		$spec=$1;
	}
	
	# Look up source packages matching the given binary or source
	# package name.
	my @matches=$aptsrc->find($spec);
	
	# Now, filter the matches down to match any version or release
	# requirements.
	if (defined $reqversion) {
		@matches = grep { $_->{Version} eq $reqversion } @matches;
	}
	if (defined $reqrelease) {
		# Sources doesn't have release info, so to get it look at
		# the release info of one if the binary packages produced
		# by the source.
		my @newmatches;
SOURCE:		foreach my $source (@matches) {
			my @binaries=@{$source->{Binaries}};
			next unless @binaries;
			my $binname=$binaries[0];
			my $binpkg=$aptcache->get($binname);
			next unless ref $binpkg;
			my @vers = grep { $_->{VerStr} eq $source->{Version} }
			                @{$binpkg->{VersionList}};
			next unless @vers == 1;
			foreach my $verfile (@{$vers[0]->{FileList}}) {
				my $archive=$verfile->{File}->{Archive};
				if (defined $archive &&
				    $archive eq $reqrelease) {
					push @newmatches, $source;
					next SOURCE;
				}
			}
		}
		@matches=@newmatches;
	}
	
	# Finally, take the most recent version of the remaining matches.
	my ($source, $version);
	foreach my $match (@matches) {
		if (! defined $version || $vs->compare($match->{Version}, $version) > 0) {
			$source=$match->{Package};
			$version=$match->{Version};
		}
	}

	return ($version, $source);
}

# Install a source, or upgrade an installed source.
# Returns the source or sources that were installed or upgraded.
sub install {
	my $class=shift;
	my $source=shift;
	my $dir=shift || ".";
	my $ignoreloclimit=shift;

	if (! $writestatus) {
		$class->error("install called with read-only status file");
	}
	
	my $version;
	($version, $source)=$class->findsource($source);
	
	if (! defined $version) {
		$class->error("No such source");
	}
	my $cwd=realpath($dir);
	my @alreadyinstalled=grep { $_->source eq $source &&
		                    ($_->basedir eq $cwd || $_->location eq $cwd)
			          } $class->installed();
	if (@alreadyinstalled) {
		my @ret;
		foreach my $pkg (@alreadyinstalled) {
			my $newpkg = $pkg->upgrade;
			if (! $newpkg) {
				$class->warning($pkg->source." in ".$pkg->location." is already the latest version");
			}
			else {
				push @ret, $newpkg;
			}
		}
		return @ret;
	}
	
	# Go to the loclimit directory, to install a package there.
	my $basedir;
	if (defined $loclimit && ! $ignoreloclimit) {
		chdir($loclimit) || $class->error("Cannot chdir to $loclimit");
		$basedir = $loclimit;
	}
	else {
		chdir($dir) || $class->error("Cannot chdir to $dir");
		$basedir = $dir;
	}

	my $item=$class->new(
		status => 'removed',
		basedir => $basedir,
		source => $source,
		version => $version,
		sourcepkgversion => $version,
	);

	# source=version used to get exactly the version the user asked
	# for.
	if ($class->do(qw{apt-get source}, "$source=$version") != 0) {
		$class->error("Failed to download $source");
	}

	if (! -d $item->location) {
		$class->error("Did not unpack to ".$item->location);
	}
		
	if ($_config->get_bool("APT::Src::BuildDeps", 1) &&
	    $class->do("dpkg-checkbuilddeps", $item->location."/debian/control") != 0) {
		# Build deps are not satisfied, so launch
		# apt. This is done in two steps because
		# for non-root we have to use su.
		if ($class->do_root(qw{apt-get -y build-dep}, $source) != 0) {
			$item->status('unpacked');
			$class->error("Unable to satisfy build dependencies for $source");
		}
	}
	
	$item->status("installed");
	return $item;
}

# Upgrade an item. Returns the item that was upgraded, or nothing if no
# upgrade.
sub upgrade {
	my $this=shift;
	
	if (! $writestatus) {
		$this->error("upgrade called with read-only status file");
	}
	
	my ($version, $source)=$this->findsource($this->source);
	if (! defined $version || $vs->compare($version, $this->version) != 1) {
		# Nothing to upgrade.
		return;
	}

	return unless $this->meets_loclimit;
	
	$this->info("Upgrading ".$this->location." ..");
	
	# To upgrade a source, the current tree is renamed prefixed with
	# "local-", the old source package is re-extracted, and a diff is taken
	# between the pristine source and the possibly modified local-
	# source. Then the new source is installed, and the patch is applied to
	# it, and the local- tree removed. If the old source package is not
	# avilable or the patch fails to apply, these are warnings, not
	# errors.
	
	my $oldloc=$this->location;
	my $oldsrc=$this->source;
	my $oldupstream=$this->upstreamversion;
	my $olddsc=$this->source."_".$this->sourcepkgversion.".dsc";
	$this->source("local-".$this->source);
	$this->updatelocation;
	rename($oldloc, $this->location)
		|| $this->error("failed renaming $oldloc");
	# Set up error unwind to rename it back.
	push @unwind, sub {
		rename($this->location, $oldloc)
			|| $this->error("failed renaming ".$this->location);
		$this->source($oldsrc);
		$this->updatelocation;
	};
		
	my $diff;
	if ($_config->get_bool('APT::Src::Patch', 1)) {
		$this->clean;
	
		if (-e $this->basedir."/".$olddsc) {
			chdir($this->basedir) ||
				$this->error("chdir ".$this->basedir.": $!");
			if ($this->do("dpkg-source", "-x", $olddsc) != 0) {
				$this->warning("Unable to extract old source package; cannot generate diff");
			}
			else {
				$diff=$this->basedir."/".$this->source."_".$this->version.".tmpdiff";
				my $ret = $this->do("diff --new-file -ur ".
				                    $oldsrc."-".$oldupstream." ".
						    $this->source."-".$this->upstreamversion.
					            " > $diff");
				if ($ret >> 8 == 2) {
					$this->warning("Trouble generating diff");
					unlink($diff);
					$diff=undef;
				}
			}
			$this->do("rm","-rf",$oldloc);
		}
		else {
			$this->warning("Old source package dsc $olddsc is gone; cannot generate diff");
		}
	}
	
	my $newthis=$this->install($source, $this->basedir, 1);
	$this->remove(1);
	pop @unwind; # no need to unwind now
	$this=$newthis;
	
	if (defined $diff) {
		chdir($this->location) || $this->error("chdir ".$this->location.": $!");
		if ($this->do("patch -p1 < $diff") != 0) {
			$this->warning("Patch did not cleanly apply. Leaving it in $diff");
		}
		else {
			unlink($diff);
		}
	}
	
	$this->info("Successfully upgraded ".$this->location);
	
	return $this;
}

# Remove a source.
sub remove {
	my $this=shift;
	my $force=shift;
	
	if (! $writestatus) {
		$this->error("remove called with read-only status file");
	}
	
        return unless $force || $this->meets_loclimit;
	
	if ($this->status =~ /^(installed|unpacked)$/) {
		if (!$_config->get_bool('APT::Src::NoDeleteSource')) {
			$this->info("Removing ".$this->source." from ".$this->location." ..");
			my @files=$this->basedir."/".$this->source."_".$this->version.".dsc";
			if ($this->upstreamversion eq $this->version) {
				# native package
				push @files, $this->basedir."/".$this->source."_".$this->version.".tar.gz";
			}
			else {
				# non-native
				push @files, $this->basedir."/".$this->source."_".$this->upstreamversion.".orig.tar.gz";
				push @files, $this->basedir."/".$this->source."_".$this->version.".diff.gz";
			}
			foreach my $file (@files) {
				if (-e $file && ! unlink $file) {
					$this->error("Unable to remove $file");
				}
			}
			if ($this->do("rm", "-rf", $this->location) != 0) {
				$this->error("Unable to remove ".$this->location);
			}
		}
	}
	$this->status("removed");
	return $this;
}

# Clean a source tree.
sub clean {
	my $this=shift;

	return unless $this->meets_loclimit;
	
	$this->info("Cleaning in ".$this->location." ..");
	chdir $this->location || $this->error("Unable to chdir to ".$this->location);
	my @command = qw{debian/rules clean};
	if ($> != 0) {
		unshift @command, "fakeroot";
	}
	if ($this->do(@command) != 0) {
		$this->error("Cleaning failed");
	}
	return $this;
}

# Build a source tree.
sub build {
	my $this=shift;

	return unless $this->meets_loclimit;
	
	# Let the package know it's being built by apt-src.
	$ENV{APT_SRC_BUILD}=1;
	
	$this->info("Building in ".$this->location." ..");

	chdir $this->location || $this->error("Unable to chdir to ".$this->location);
	my @command;
	if (! $_config->exists('APT::Src::BuildCommand')) {
		@command = qw{dpkg-buildpackage -b -us -uc};
		if ($> != 0) {
			push @command, "-rfakeroot";
		}
	}
	else {
		@command=split(/\s+/, $_config->get('APT::Src::BuildCommand'));
		if ($> != 0) {
			push @command, "-rfakeroot";
		}
	}
	if ($this->do(@command) != 0) {
		$this->error("Building failed");
	}
	$this->info("Successfully built in ".$this->location);
	return $this;
}

# Installs all the packages generated by building a source tree.
sub installdebs {
	my $this=shift;
	
	return unless $this->meets_loclimit;

	# Find and parse .changes file to figure out what debs were
	# generated and should be installed.
	my $changes=$this->basedir."/".$this->source."_".$this->version."_".
	            $_config->get("APT::Architecture").".changes";
	if (! -e $changes) {
		$this->error("Cannot find changes file $changes");
	}
	open (my $c, $changes) || $this->error("Cannot read changes file $changes: $!");
	while (<$c>) {
		last if /^Files:/;
	}
	my (@debs, @files);
	push @files, $changes;
	while (<$c>) {
		chomp;
		last if ! /^ /;
		if (/^ [0-9a-zA-Z]+ \d+ [^ ]+ [^ ]+ (.*)/) {
			my $file=$1;
			push @files, $this->basedir."/".$file;
			push @debs, $this->basedir."/".$file if $file=~/\.deb$/;
		}
	}
	close $c;
	if (! @debs) {
		$this->warning("No debs were generated, or error parsing changes file");
	}
	else {
		$this->info("Installing debs built from ".$this->location." ..");
		my @command = ("dpkg", "-i", @debs);
		if ($this->do_root(@command) != 0) {
			$this->error("Error installing @debs");
		}
		if (@files && ! $_config->get_bool('APT::Src::KeepBuilt')) {
			unlink(@files) || $this->warning("Failed to remove some of the built files (@files)");}
		$this->info("Successfully installed debs.");
	}
}

# Given a directory, tries to find a debian/changelog and parse a version
# out of the first line of it; returns the version or undef.
sub guessversion {
	my $class=shift;
	my $dir=shift;

	open(my $changelog, "$dir/debian/changelog") || return;
	my $line=<$changelog>;
	close $changelog;
	
	if ($line =~ /^[^\s]+\s+\(([^\)]+)\)\s+/) {
		return $1
	}
	return;
}

# Returns three or less letters to indicate the status.
sub shortstatus {
	my $this=shift;
	my ($letter) = $this->status =~ m/(.)/;
	return $letter;
}

# Helper method to set location from three other fields. Adds the item to
# the %sources hash.
sub updatelocation {
	my $this=shift;
	
	delete $sources{$this->{location}} if defined $this->{location};
	$this->{location} = $this->{basedir}."/".
	                    $this->{source}."-".
			    $this->upstreamversion;
	$sources{$this->{location}}=$this;
}

# Returns upstream version.
sub upstreamversion {
	my $this=shift;

	return $vs->upstream($this->{version});
}

# Error reporting & etc.
sub error {
	my $class=shift;
	print STDERR "E: ".shift()."\n";
	# Error unwind.
	while ($_ = pop @unwind) {
		$_->();
	}
	exit(1);
}

sub warning {
	my $class=shift;
	print STDERR "W: ".shift()."\n";
}

sub info {
	my $class=shift;
	print "I: ".shift()."\n";
}

# Runs a shell command, gaining root if necessary.
sub do_root {
	my $class=shift;
	my $interpolated = 0;
	my @command;
	if ($> == 0) {
		@command = @_;
	} else {
		if ($_config->exists('APT::Src::RootCommand')) {
			@command=split(/\s+/, $_config->get('APT::Src::RootCommand'));
		} else {
			@command = qw(sudo);
		}
		# look for %s in the command to see if the user requests
		# interpolation instead of just appending
		foreach (@command) {
			if (/%s/) {
				$interpolated = 1;
				$_ = sprintf($_, join(' ', @_));
				last;
			}
		}
		# probably sudo, which doesn't require the command to be passed
		# as a single string, so append the array
		if (!$interpolated) {
			push @command, @_;
		}
	}
	$class->do(@command);
}

# Runs a shell command, only displaying its output in verbose mode or if it
# fails. Returns like system does.
sub do {
	my $class=shift;

	if ($_config->get_bool('APT::Src::Trace')) {
		$class->info("running: @_");
	}
	
	unless ($_config->get_bool('APT::Src::Quiet')) {
		return system @_;
	}
	
	my $pid=open(my $fh, "-|");
	if ($pid) {
		# Parent,
		my @output=<$fh>;
		close $fh;
		if ($? != 0) {
			print STDERR @output;
		}
		return $?;
	}
	else {
		# Child.
		open(STDERR, ">&STDOUT");
		close(STDOUT);
		exec(@_);
	}
}

# Field accesses.
sub AUTOLOAD {
	my $this=shift;
	(my $field = our $AUTOLOAD) =~ s/.*://;

	if (@_) {
		$this->{$field}=shift;
	}
	return $this->{$field};
}

1
