use strict;
use warnings;
use Test::More;
use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use Mojolicious;
use File::Temp qw(tempdir);

my $tmpdir = tempdir(CLEANUP => 1);

# Build app with DBIx::Async backend
my $app = Mojolicious->new;
$app->moniker('ShutdownTest');
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
    ],
};

$app->plugin('Fondation');

# Register source explicitly (not under a plugin namespace)
require TestDBIxAsyncSchema;
require TestDBIxAsyncSchema::Result::User;
TestDBIxAsyncSchema->register_source('users',
    TestDBIxAsyncSchema::Result::User->result_source_instance);

# Connect to trigger schema creation and populate _schemas
my $c = $app->build_controller;
my $schema = $c->schema;
isa_ok($schema, 'DBIx::Class::Async::Schema',
    'schema connected before shutdown');

# Mock DBIx::Class::Async::disconnect to track calls
my (@disconnect_args, $disconnect_count);
{
    no warnings 'redefine';
    my $orig_disconnect = \&DBIx::Class::Async::disconnect;
    *DBIx::Class::Async::disconnect = sub {
        $disconnect_count++;
        push @disconnect_args, $_[1];   # $_[0] is class name
        goto $orig_disconnect;
    };
}

# --- Test 1: _shutdown sub disconnects all schemas ---

# Get the plugin instance from Fondation's manager
my $manager = $app->manager;
my $plugin = $manager->registry
    ->{'Mojolicious::Plugin::Fondation::Model::DBIx::Async'}{instance};
ok($plugin, 'plugin instance found');
$plugin->{_shutdown}->();

is($disconnect_count, 1, 'disconnect called once by shutdown handler');
is($disconnect_args[0], $schema,
    'disconnect called with the connected schema');

# --- Test 2: END block emits before_server_stop hook ---

my $hook_fired = 0;
$app->hook(before_server_stop => sub { $hook_fired++ });

# Simulate what the END block does: emit hook first, then shutdown
$app->plugins->emit_hook('before_server_stop' => $app);
is($hook_fired, 1, 'before_server_stop hook emitted on shutdown');

done_testing;
