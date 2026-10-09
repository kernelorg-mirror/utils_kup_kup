#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# [pgp]: choosing the verifier, the shadow verifier that only logs when it
# disagrees, and a broken verifier never passing for a bad signature.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));
require_cmd($_) for qw(gpgv sq);

my $e = kup_env();
my $dir = $e->{dir};
my $data = $e->{data};
my $fpr = $e->gen_key('alice');
$e->authorize($fpr);
my $payload = "contents\n";
server_ok($e, "MKDIR /t\n", 'create upload dir');

# gpgv accepts SHA-1 data signatures, sq doesn't
my $sha1_sig = sign_blob($e, $fpr, $payload, '--detach-sign',
			 '--digest-algo', 'SHA1');
my $sha1 = sub { blob(DATA => $payload).blob(SIGN => $sha1_sig)."PUT $_[0]\n" };
my $put = sub { put_cmds($e, $fpr, $payload, $_[0]) };

# A script standing in for a verifier
my $fake = sub {
	my ($name, $body) = @_;
	write_file("$dir/$name", "#!/bin/sh\n$body\n");
	chmod(0755, "$dir/$name") or xbail("chmod: $!");
	"$dir/$name";
};

subtest shadow => sub {
	$e->set_cfg('pgp.verifier' => 'gpgv', 'pgp.shadow' => 'sq');
	$e->syslog_take;
	server_ok($e, $put->('/t/agree'), 'both accept');
	unlike($e->syslog_take, qr/shadow/, 'agreement is not logged');

	server_ok($e, $sha1->('/t/sha1'), 'the verifier decides');
	like($e->syslog_take,
	     qr/^warning: pgp: gpgv accepted, but shadow sq rejected: .*SHA1/m,
	     "disagreement logged with the shadow's reason");

	$e->set_cfg('pgp.verifier' => 'sq', 'pgp.shadow' => 'gpgv');
	server_fails($e, $sha1->('/t/sha1-b'), qr/Signature invalid/,
		     'flipped: sq decides');
	like($e->syslog_take,
	     qr/^warning: pgp: sq rejected, but shadow gpgv accepted: .*SHA1/m,
	     "disagreement logged with the verifier's reason");

	# The two rings drifted apart: the shadow notices
	rename("$dir/pgp/$e->{user}.asc", "$dir/pgp/asc.bak") or xbail($!);
	$e->set_cfg('pgp.verifier' => 'gpgv', 'pgp.shadow' => 'sq');
	server_ok($e, $put->('/t/drift'), 'gpgv still accepts');
	like($e->syslog_take, qr/^warning: pgp: gpgv accepted, but shadow sq rejected/m,
	     'missing .asc shows up as a disagreement');
	$e->set_cfg('pgp.verifier' => 'sq', 'pgp.shadow' => undef);
	server_fails($e, $put->('/t/drift-b'), qr/Signature invalid/,
		     'and sq fails closed without its .asc');
	rename("$dir/pgp/asc.bak", "$dir/pgp/$e->{user}.asc") or xbail($!);
};

subtest 'broken verifiers' => sub {
	my @broken = (
		[ "$dir/no-such-verifier", qr/exit status 127/, 'missing' ],
		[ $fake->('usage', 'echo "unexpected argument" >&2; exit 2'),
		  qr/exit status 2: unexpected argument/, 'usage error' ],
		[ $fake->('killed', 'kill -KILL $$'), qr/signal 9/, 'killed' ],
	);
	for my $b (@broken) {
		my ($prog, $log_re, $what) = @$b;
		for my $v (qw(gpgv sq)) {
			$e->set_cfg('pgp.verifier' => $v, "pgp.$v" => $prog,
				    'pgp.shadow' => undef);
			server_fails($e, $put->("/t/broken-$v"),
				     qr/^Cannot check signatures right now/m,
				     "$v $what: a server error, not a bad signature");
			like($e->syslog_take, qr/^err: pgp: $v failed: $log_re/m,
			     '... and logged');
			ok(!-e "$data/t/broken-$v", '... and nothing installed');
		}
		$e->set_cfg(map { ("pgp.$_" => KupTest::which($_)) } qw(gpgv sq));
	}

	# A broken shadow must never block uploads
	$e->set_cfg('pgp.verifier' => 'gpgv', 'pgp.shadow' => 'sq',
		    'pgp.sq' => "$dir/no-such-verifier");
	server_ok($e, $put->('/t/shadow-broken'), 'broken shadow');
	like($e->syslog_take, qr/^err: pgp: sq failed: exit status 127/m,
	     '... is logged');
	$e->set_cfg('pgp.sq' => KupTest::which('sq'), 'pgp.shadow' => undef);
};

subtest config => sub {
	my @bad = (
		[ { 'pgp.verifier' => 'sqv' }, qr/Unknown PGP verifier: sqv/ ],
		[ { 'pgp.shadow' => 'gnupg' }, qr/Unknown PGP verifier: gnupg/ ],
		[ { 'pgp.verifier' => 'sq', 'pgp.sq' => 'sq' },
		  qr/pgp\.sq must be an absolute path/ ],
		[ { 'pgp.verifier' => 'sq', 'pgp.shadow' => 'sq' },
		  qr/pgp\.shadow must differ from pgp\.verifier/ ],
	);
	for my $b (@bad) {
		my ($cfg, $re) = @$b;
		$e->set_cfg(%$cfg);
		server_fails($e, "DIR /\n", $re, "rejected: $re");
		$e->set_cfg(map { $_ => undef } keys %$cfg);
		$e->set_cfg(map { ("pgp.$_" => KupTest::which($_)) } qw(gpgv sq));
	}
	# Without [pgp] at all: gpgv, as before
	$e->set_cfg(map { ("pgp.$_" => undef) } qw(gpgv sq verifier shadow));
	$e->syslog_take;
	server_ok($e, $sha1->('/t/default'), 'no [pgp]: gpgv') if
		-x '/usr/bin/gpgv';
};

done_testing;
