#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Only a detached signature over the uncompressed data, made by a key in
# the uploader's own keyring, may install anything.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $alice = $e->gen_key('alice');
my $alice2 = $e->gen_key('alice-laptop');
my $mallory = $e->gen_key('mallory');
my $data = "$e->{dir}/data";
my $payload = "release contents\n";

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

my @left = grep { !m{/t/good2?(\.sign)?\z} } glob("$data/t/*");
is_deeply(\@left, [], 'only the good uploads were installed');

done_testing;
