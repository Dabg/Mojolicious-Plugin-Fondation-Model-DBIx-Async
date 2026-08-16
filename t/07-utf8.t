use strict;
use warnings;
use Test::More;
use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use File::Temp qw(tempdir);
use DBI;
use Encode qw(is_utf8);
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(encode);
use Mojolicious::Plugin::Fondation::TestHelper qw(create_test_app);
use DBIxTestHelper qw(build_dbtest_app);

my $tmpdir = tempdir(CLEANUP => 1);

my ($app, $dbfile) = build_dbtest_app($tmpdir);

my $c      = $app->build_controller;
my $schema = $c->schema;

$schema->deploy({ add_drop_table => 0 })->get;

# 1. Round-trip through the async worker pool preserves accents
my $text = "Install\x{e9} 'uv' si n\x{e9}cessaire \x{2014} fin";
utf8::upgrade($text);

my $created = $schema->await(
    $c->model('user')->create({ name => $text, email => 'alice@example.com' }));
ok($created->id, 'create works');

my $found = $schema->await($c->model('user')->find($created->id));
is($found->name, $text, 'accented text round-trips unchanged');
ok(is_utf8($found->name), 'read-back string carries the UTF-8 flag');

# 2. Raw bytes in the DB are proper UTF-8 (readable by any UTF-8 tool)
{
    my $dbi = DBI->connect("dbi:SQLite:dbname=$dbfile", '', '', {});
    my $hex = $dbi->selectrow_array(
        'SELECT hex(name) FROM users WHERE id = ?', undef, $created->id);
    like($hex, qr/6EC3A96365737361697265/,
        'DB stores UTF-8 bytes (0xC3 0xA9 for e-acute)');
    $dbi->disconnect;
}

# 3. Rendering does not double-encode (regression: "nÃ©cessaire")
{
    my $c2 = $app->build_controller;
    $c2->stash(content => $found->name);
    my $html = $c2->render_to_string(
        inline => '<%== $content %>', handler => 'ep');
    # render_to_string skips the renderer's final UTF-8 encode step
    # (Mojolicious::Renderer returns raw output for 'mojo.string');
    # apply it like the real HTTP path does (Renderer.pm _maybe/encode).
    my $wire = encode('UTF-8', $html);
    like($wire, qr/n\xC3\xA9cessaire/s, 'rendered HTML is single-encoded UTF-8');
    unlike($wire, qr/n\xC3\x83\xC2\xA9cessaire/s,
        'rendered HTML has no double-encoded mojibake');

    my $json = encode_json({ content => $found->name });
    like($json, qr/n\xC3\xA9cessaire/, 'JSON response is single-encoded UTF-8');
    unlike($json, qr/n\xC3\x83\xC2\xA9cessaire/,
        'JSON response has no double-encoded mojibake');
}

# 4. An explicit encoding attribute in config wins over the default
{
    my $tmpdir2 = tempdir(CLEANUP => 1);
    my $app2 = create_test_app($tmpdir2);
    $app2->plugin('Fondation' => {
        dependencies => [
            { 'Fondation::Model::DBIx::Async' => {
                backends => [ main => {
                    dsn            => "dbi:SQLite:dbname=$tmpdir2/explicit.db",
                    schema_class   => 'TestDBIxAsyncSchema',
                    sqlite_unicode => 0,
                }],
            }},
            'Fondation::TestDBIxAsync',
        ],
    });
    my $c2      = $app2->build_controller;
    my $schema2 = $c2->schema;
    $schema2->deploy({ add_drop_table => 0 })->get;

    my $row = $schema2->await(
        $c2->model('user')->create({ name => $text, email => 'bob@example.com' }));
    my $back = $schema2->await($c2->model('user')->find($row->id));
    ok(!is_utf8($back->name),
        'explicit sqlite_unicode => 0 is honored (no override)');
}

done_testing;
