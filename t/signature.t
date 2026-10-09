#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Only a detached signature over the uncompressed data, made by a key in
# the uploader's own keyring, may install anything.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $payload = "release contents\n";

# Every case runs against each verifier kup-server supports
sub check_verifier {
	my ($verifier) = @_;
	my $e = kup_env(cfg => { 'pgp.verifier' => $verifier });
	my $alice = $e->gen_key('alice');
	my $alice2 = $e->gen_key('alice-laptop');
	my $mallory = $e->gen_key('mallory');
	my $data = "$e->{dir}/data";

	server_ok($e, "MKDIR /t\n", 'create upload dir');

	server_fails($e, put_cmds($e, $alice, $payload, '/t/nokeyring'),
		     qr/Signature invalid/, 'no keyring for this user');

	$e->authorize($alice, $alice2);

	server_ok($e, put_cmds($e, $alice, $payload, '/t/good'), 'good signature');
	server_ok($e, put_cmds($e, $alice2, $payload, '/t/good2'),
		  'any key in the keyring may sign');

	# Old test/4
	server_fails($e, put_cmds($e, $alice, $payload, '/t/rogue',
				  signer => $mallory),
		     qr/Signature invalid/, 'valid signature by an unauthorized key');

	# Old test/5
	server_fails($e, blob(DATA => "tampered\n").
			 blob(SIGN => sign_blob($e, $alice, $payload))."PUT /t/bad\n",
		     qr/Signature invalid/, 'signature over different data');

	# Old test/6: a signed message carries its own data, which must not be
	# mistaken for a signature over DATA
	for my $mode ('--sign', '--clearsign') {
		server_fails($e, blob(DATA => $payload).
				 blob(SIGN => sign_blob($e, $alice, $payload, $mode)).
				 "PUT /t/msg\n",
			     qr/Signature invalid/, "$mode instead of --detach-sign");
	}

	{
		my $gz;
		spawn([ 'gzip', '-c' ], undef, { 0 => $payload, 1 => \$gz });
		server_fails($e, blob(DATA => $gz, 'gz').
				 blob(SIGN => sign_blob($e, $alice, $gz)).
				 "PUT /t/wire.gz\n",
			     qr/Signature invalid/,
			     'signing the compressed bytes is not enough');
	}

	server_fails($e, blob(SIGN => 'x' x 65536), qr/SIGN output impossibly large/,
		     'oversized SIGN');

	# The verifier tells us who signed; the sha256 log says what
	$e->syslog_take;
	server_ok($e, put_cmds($e, $alice2, $payload, '/t/who'), 'upload');
	like($e->syslog_take, qr/^notice: pgp: signed by $alice2$/m,
	     'signer fingerprint logged');
	unlink(glob("$data/t/who*"));

	# SHA-1 hashes can be forged; sq refuses SHA-1 data signatures
	my $sha1 = blob(DATA => $payload).
		blob(SIGN => sign_blob($e, $alice, $payload, '--detach-sign',
				       '--digest-algo', 'SHA1'))."PUT /t/sha1\n";
	if ($verifier eq 'sq') {
		server_fails($e, $sha1, qr/Signature invalid/,
			     'SHA-1 data signature rejected');
		like($e->syslog_take,
		     qr/^notice: pgp: sq rejected the signature: .*SHA1/m,
		     "sq's reason logged");
	} else {
		server_ok($e, $sha1, 'gpgv accepts a SHA-1 data signature');
		unlink(glob("$data/t/sha1*"));
	}

	# A key revoked after it signed; its owner revoked it for a reason
	my $rv = $e->gen_key('revoked');
	my $rv_sig = sign_blob($e, $rv, $payload);
	(my $rev = read_file("$e->{gpg_home}/openpgp-revocs.d/$rv.rev"))
		=~ s/^:(-----BEGIN)/$1/m;
	$e->gpg([ '--import' ], { 0 => $rev }) or xbail('revocation failed');
	$e->authorize($rv);		# last case: alice's ring isn't needed any more
	{
		local $TODO = 'gpgv only says REVKEYSIG and exits 0'
			if $verifier eq 'gpgv';
		my ($ok, $out, $err) = kup_server($e, blob(DATA => $payload).
			blob(SIGN => $rv_sig)."PUT /t/revoked\n");
		ok(!$ok && $err =~ /Signature invalid/, 'revoked key rejected')
			or diag("stderr: $err");
	}
	unlink(glob("$data/t/revoked*"));

	my @left = grep { !m{/t/good2?(\.sign)?\z} } glob("$data/t/*");
	is_deeply(\@left, [], 'only the good uploads were installed');
}

subtest $_ => sub { check_verifier($_) } for verifiers();

done_testing;
