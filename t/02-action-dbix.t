use strict;
use warnings;
use Test::More;
use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use Mojolicious;
use File::Temp qw(tempdir);

my $tmpdir = tempdir(CLEANUP => 1);
my $app = Mojolicious->new;
$app->moniker('MyApp');
$app->log->level('fatal');

$app->config->{'Fondation'} = {
    dependencies => [
        {
            'Fondation::Model::DBIx::Async' => {
                backends => {
                    main => {
                        dsn          => "dbi:SQLite:dbname=$tmpdir/test.db",
                        schema_class => 'TestDBIxAsyncSchema',
                        workers      => 1,
                    },
                },
                models => {
                    user => { source => 'users', backend => 'main' },
                },
            },
        },
        'TestDBIxPlugin',
    ],
};

$app->plugin('Fondation');

my $c = $app->build_controller;

# 1. Action::DBIx registered the plugin's Result
my $schema = $c->schema;
my $source = eval { $schema->source('users') };
ok($source, 'users source registered by Action::DBIx');
is($source->result_class, 'Mojolicious::Plugin::TestDBIxPlugin::Schema::Result::User',
    'result_class from plugin');

# 2. Plugin registry has dbic metadata
my $entry = $app->manager->registry->{'Mojolicious::Plugin::TestDBIxPlugin'};
ok($entry->{dbic}, 'dbic metadata present');
is_deeply($entry->{dbic}{results}, ['users'], 'results list correct');
is($entry->{dbic}{total_added}, 1, 'one result added');

# 3. End-to-end: deploy + CRUD via model()
$schema->deploy({ add_drop_table => 0 })->get;

my $rs = $c->model('user');
my $alice = $schema->await($rs->create({ name => 'Alice', email => 'a@e.com' }));
ok($alice->id, 'create via model works');

my $found = $schema->await($rs->find($alice->id));
is($found->name, 'Alice', 'find via model works');

done_testing;
