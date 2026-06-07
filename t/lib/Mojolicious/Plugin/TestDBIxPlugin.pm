package Mojolicious::Plugin::TestDBIxPlugin;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub fondation_meta {
    return {
        dependencies => ['Fondation::Model::DBIx::Async'],
        defaults     => {
            models => {
                user => { source => 'users' },
            },
        },
    };
}

sub register ($self, $app, $conf) { return $self }
1;
