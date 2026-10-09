# SPDX-License-Identifier: GPL-2.0-or-later
#
# Loaded into kup-server and kup with -M by the test harness.  It sends
# syslog() calls to the file named in $KUP_TEST_SYSLOG instead of the
# system log, so tests can check what was logged.  It has to be a -M
# module: kup-server clears %ENV before its own code runs, and -T makes
# perl ignore PERL5OPT.
package KupTestSyslog;
use strict;
use warnings;
use Sys::Syslog ();

my @LEVELS = qw(emerg alert crit err warning notice info debug);

if (defined(my $file = $ENV{KUP_TEST_SYSLOG})) {
	($file) = ($file =~ /\A(.+)\z/s);	# untaint: set by the harness
	no warnings 'redefine';
	# Before the script is compiled, so its "use Sys::Syslog" imports this
	*Sys::Syslog::syslog = sub {
		my ($prio, $fmt, @args) = @_;
		my $level = $prio =~ /\A\d+\z/ ? $LEVELS[$prio & 7] : $prio;
		# Children (compressors) log too; O_APPEND keeps lines whole
		open(my $fh, '>>', $file) or die "open $file: $!";
		# Like Sys::Syslog: no arguments, no sprintf ("Cmd: $line")
		print $fh "$level: ", (@args ? sprintf($fmt, @args) : $fmt), "\n";
		close($fh) or die "close $file: $!";
	};
}

1;
