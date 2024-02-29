#
# Copyright 2014 Andrew Ayer
# Copyright 2015-2016 Chris Lamb <lamby@debian.org>
#
# This file is part of strip-nondeterminism.
#
# strip-nondeterminism is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# strip-nondeterminism is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with strip-nondeterminism.  If not, see <http://www.gnu.org/licenses/>.
#
package File::StripNondeterminism::handlers::javadoc;

use strict;
use warnings;

use File::StripNondeterminism;
use File::StripNondeterminism::Common qw(copy_data);
use File::Temp;
use File::Basename;
use POSIX qw(strftime);

=head1 DEPRECATION PLAN

This could almost-certainly be changed in OpenJDK itself and then removed here.

=cut

sub is_javadoc_file($) {
	my ($filename) = @_;

	# If this is a javadoc file, '<!-- Generated by javadoc' should appear
	# in first 1kb
	my $fh;
	my $str;
	return
	     open($fh, '<', $filename)
	  && read($fh, $str, 1024)
	  && $str =~ /\<!-- Generated by javadoc/;
}

sub normalize {
	my ($filename) = @_;

	open(my $fh, '<', $filename)
	  or die "Unable to open $filename for reading: $!";
	my $tempfile = File::Temp->new(DIR => dirname($filename));

	# Strip the javadoc comment, which contains a timestamp. It should
	# appear before a line containing </head>, which should be within first
	# 15 lines.
	my $modified = 0;
	while (defined(my $line = <$fh>)) {
		if ($line =~ /\<!-- Generated by javadoc .* --\>/) {
			$line =~ s/\<!-- Generated by javadoc .* --\>//g;
			print $tempfile $line
			  unless $line
			  =~ /^\s*$/; # elide lines that are now whitespace-only
			$modified = 1;
		} elsif ($line =~ /\<META NAME="(date|dc.created)" CONTENT="[^"]*"\>/i) {
			if (defined $File::StripNondeterminism::canonical_time) {
				my $date = strftime('%Y-%m-%d',
					gmtime($File::StripNondeterminism::canonical_time));
				$line
				  =~ s/\<(META NAME="(?:date|dc.created)" CONTENT)="[^"]*"\>/<$1="$date">/gi;
			} else {
				$line =~ s/\<META NAME="(?:date|dc.created)" CONTENT="[^"]*"\>//gi;
			}
			print $tempfile $line
			  unless $line
			  =~ /^\s*$/; # elide lines that are now whitespace-only
			$modified = 1;
		} elsif ($line =~ /<html lang="[^"]+">/) {
			# Strip locale as it's inherited from environment.
			# Browsers will do a far better job at detecting
			# encodings, than a header ever could anyway.
			print $tempfile "<html>\n";
			$modified = 1;
		} else {
			print $tempfile $line;
		}
		last if $. == 15 or $line =~ /\<\/head\>/i;
	}

	return 0 if not $modified;

	# Copy through rest of file
	my $bytes_read;
	my $buf;
	while ($bytes_read = read($fh, $buf, 4096)) {
		print $tempfile $buf;
	}
	defined($bytes_read) or die "$filename: read failed: $!";

	$tempfile->close;
	copy_data($tempfile->filename, $filename)
	  or die "$filename: unable to overwrite: copy_data: $!";

	return 1;
}

1;
