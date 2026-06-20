use strict;
use warnings;
use Test::More;
use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use File::Temp qw(tempdir);
use Mojolicious::Plugin::Fondation::TestHelper qw(create_test_app);

my $tmpdir = tempdir(CLEANUP => 1);
my $dbfile = "$tmpdir/test.db";

my $app = create_test_app($tmpdir);
$app->plugin('Fondation' => {
    dependencies => [
        { 'Fondation::Model::DBIx::Async' => {
            backends => [
                main => {
                    dsn          => "dbi:SQLite:dbname=$dbfile",
                    schema_class => 'TestDBIxAsyncSchema',
                    workers      => 1,
                    quote_char   => '"',
                },
            ],
            models => {
                user       => { source => 'User',       backend => 'main' },
                group      => { source => 'Group',      backend => 'main' },
                user_group => { source => 'UserGroup',  backend => 'main' },
            },
        }},
        'Fondation::TestDBIxRelation',
    ],
});

my $c = $app->build_controller;

# ─── Setup ───────────────────────────────────────────────────────────────────

my $schema = $c->schema;
$schema->deploy({ add_drop_table => 0 })->get;

my $alice  = $schema->await($c->model('user')->create({ name => 'Alice' }));
my $admins = $schema->await($c->model('group')->create({ name => 'Admins' }));
my $editors = $schema->await($c->model('group')->create({ name => 'Editors' }));
$schema->await($alice->add_to_groups($admins));
$schema->await($alice->add_to_groups($editors));

# ─── 1. with('groups')->all ──────────────────────────────────────────────────

subtest 'with(groups)->all returns users with groups' => sub {
    my $rows = $schema->await(
        $c->model('user')->with('groups')->all
    );
    is(scalar @$rows, 1, 'one user');

    my $row = $rows->[0];
    is($row->name, 'Alice', 'correct user');

    # groups accessible via many_to_many_async (prefetched path)
    my $groups = $schema->await($row->groups);
    is(scalar @$groups, 2, 'user has 2 groups');
    my %names = map { $_->{name} => 1 } @$groups;
    ok($names{Admins},  'Admins in result');
    ok($names{Editors}, 'Editors in result');
};

# ─── 2. with('groups')->search({ ... })->all ─────────────────────────────────

subtest 'with(groups)->search({})->all chains correctly' => sub {
    my $rows = $schema->await(
        $c->model('user')->with('groups')->search({ 'me.name' => 'Alice' })->all
    );
    is(scalar @$rows, 1, 'one user matching search');
    my $groups = $schema->await($rows->[0]->groups);
    is(scalar @$groups, 2, 'user has 2 groups after search filter');
};

# ─── 3. with('groups')->find works ───────────────────────────────────────────

subtest 'with(groups)->find returns user with groups' => sub {
    my $row = $schema->await(
        $c->model('user')->with('groups')->find($alice->id)
    );
    ok($row, 'user found');
    is($row->name, 'Alice', 'correct user');

    my $groups = $schema->await($row->groups);
    is(scalar @$groups, 2, 'user has 2 groups via find');
};

# ─── 4. without with() — standard path still works ───────────────────────────

subtest 'model without with() still works' => sub {
    my $rows = $schema->await(
        $c->model('user')->all
    );
    is(scalar @$rows, 1, 'one user without with()');
    is($rows->[0]->name, 'Alice', 'correct user without with()');
};

# ─── 5. with() validates relation exists ─────────────────────────────────────

subtest 'with() dies on unknown relation' => sub {
    eval { $c->model('user')->with('nonexistent') };
    like($@, qr/No many_to_many relation/, 'dies on unknown relation');
};

done_testing;
