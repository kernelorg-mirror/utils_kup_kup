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
	$e->authorize($rv);		# alice's ring isn't needed any more
	server_fails($e, blob(DATA => $payload).blob(SIGN => $rv_sig).
			 "PUT /t/revoked\n", qr/Signature invalid/,
		     'revoked key rejected');
	like($e->syslog_take, qr/^notice: pgp: $verifier rejected the signature: .*revoked/m,
	     '... and why is logged');
	unlink(glob("$data/t/revoked*"));

	# Expired keys: the server's ring decides, not the signer.  The keys
	# are made in 2020 and expired a day later.
	my $past = '20200101T000000';
	my $backdated = sub {	# signed while the key was still live
		my ($fpr) = @_;
		blob(DATA => $payload).
			blob(SIGN => sign_blob($e, $fpr, $payload, '--detach-sign',
				'--faked-system-time', '20200101T060000!'));
	};
	my $expired = sub {
		my ($stream, $msg) = @_;
		server_fails($e, $stream."PUT /t/expired\n", qr/Signature invalid/,
			     $msg);
		like($e->syslog_take,
		     qr/^notice: pgp: $verifier rejected the signature: .*[Ee]xpired/m,
		     '... and why is logged');
	};

	my $ex = $e->gen_key('expired', '1d', $past);
	$e->authorize($ex);
	# Its owner extended it, but never sent the new expiry to the server
	$e->gpg([ '--quick-set-expire', $ex, 'never' ])
		or xbail('cannot extend the key');
	$expired->(blob(DATA => $payload).
		   blob(SIGN => sign_blob($e, $ex, $payload)),
		   'key expired in the ring, extended by its owner');
	# The signer picks the signature's time; sq only checks that the key
	# was live then
	$expired->($backdated->($ex), 'backdated signature by an expired key');

	# The same with signing subkeys, which is what most people sign with
	my $sub = $e->gen_key('subkey', 'never', $past);
	my $signing_subkeys = sub {	# oldest first
		my ($out, @fpr, $signing);
		$e->gpg([ '--with-colons', '--list-keys', $sub ], { 1 => \$out });
		for (split(/\n/, $out)) {
			my @f = split(/:/);
			$signing = ($f[0] eq 'sub' && $f[11] =~ /s/) if $f[0] =~ /\A(?:pub|sub)\z/;
			push(@fpr, $f[9]) if $f[0] eq 'fpr' && $signing;
		}
		@fpr;
	};
	$e->gpg([ '--faked-system-time', "$past!", '--quick-add-key', $sub,
		  'ed25519', 'sign', '1d' ]) or xbail('cannot add a subkey');
	my ($old_sub) = $signing_subkeys->();
	$e->authorize($sub);
	# "!": sign with exactly this subkey
	$expired->($backdated->("$old_sub!"),
		   'backdated signature by an expired subkey');

	$e->gpg([ '--quick-add-key', $sub, 'ed25519', 'sign', 'never' ])
		or xbail('cannot add a subkey');
	my (undef, $new_sub) = $signing_subkeys->();
	$e->authorize($sub);
	server_ok($e, blob(DATA => $payload).
		  blob(SIGN => sign_blob($e, "$new_sub!", $payload))."PUT /t/subkey\n",
		  'a live signing subkey works');
	like($e->syslog_take, qr/^notice: pgp: signed by $sub$/m,
	     '... and the primary key is logged as the signer');
	unlink(glob("$data/t/subkey*"));

	my @left = grep { !m{/t/good2?(\.sign)?\z} } glob("$data/t/*");
	is_deeply(\@left, [], 'only the good uploads were installed');
}

subtest $_ => sub { check_verifier($_) } for verifiers();

done_testing;
