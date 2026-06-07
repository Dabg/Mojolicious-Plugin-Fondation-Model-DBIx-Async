package Mojolicious::Plugin::Fondation::Model::DBIx::Async;

# ABSTRACT: Fondation plugin exposing DBIx::Class::Async natively —
# ResultSets, Futures, worker pool. No hashref wrapper or Future→Mojo::Promise
# conversion. 100% async.

use Mojo::Base 'Mojolicious::Plugin', -signatures;

our $VERSION = '0.01';

=head1 NAME

Mojolicious::Plugin::Fondation::Model::DBIx::Async - Native DBIx::Class::Async
for Fondation applications

=encoding UTF-8

=head1 SYNOPSIS

  # myapp.conf
  {
      'Fondation' => {
          dependencies => [
              { 'Fondation::Model::DBIx::Async' => {
                  backends => {
                      main => {
                          dsn          => 'dbi:SQLite:dbname=data/app.db',
                          schema_class => 'MySchema',
                          workers      => 2,
                      },
                  },
                  models => {
                      user => { source => 'users' },
                  },
              }},
          ],
      },
  }

  # In a controller
  sub list ($self) {
      $self->render_later;
      $self->model('user')->search({ active => 1 })->all
          ->on_done(sub {
              my @users = @_;
              $self->render(json => [ map { $_->get_columns } @users ]);
          })
          ->on_fail(sub { $self->reply->exception(shift) })
          ->retain;
  }

=head1 DESCRIPTION

L<Mojolicious::Plugin::Fondation::Model::DBIx::Async> is a L<Fondation> plugin
that exposes L<DBIx::Class::Async> natively — no hashref CRUD wrapper, no
Future-to-Mojo::Promise conversion. Every call goes through a background worker
pool, keeping the L<Mojolicious> event loop responsive.

=head2 Architecture

  ┌─────────────────────────────────────────────────┐
  │  Mojolicious Application                        │
  │  $c->model('user') → ResultSet                  │
  │  $c->schema         → DBIx::Class::Async::Schema│
  └──────────────┬──────────────────────────────────┘
                 │ IO::Async::Loop::Mojo
  ┌──────────────▼──────────────────────────────────┐
  │  Worker Pool (forked processes)                 │
  │  ┌────────┐ ┌────────┐ ┌────────┐              │
  │  │Worker 1│ │Worker 2│ │Worker N│              │
  │  └────────┘ └────────┘ └────────┘              │
  └──────────────┬──────────────────────────────────┘
                 │ DBI
  ┌──────────────▼──────────────────────────────────┐
  │  Database                                       │
  └─────────────────────────────────────────────────┘

Each backend is a separate L<DBIx::Class::Async::Schema> with its own
L<IO::Async::Loop::Mojo> and worker pool. Workers are forked lazily on
the first schema access and are automatically stopped on process exit.

=head2 Model discovery

During C<fondation_finalyze>, the plugin scans every loaded Fondation plugin
for a C<models> key in their configuration. Models declared by dependency
plugins are merged, with the application configuration taking priority.
Each model is validated to have a resolvable backend.

=head2 Source registration

The C<DBIx> action (L<Mojolicious::Plugin::Fondation::Model::DBIx::Async::Action::DBIx>)
auto-discovers C<Result> and C<ResultSet> classes under each plugin's
C<Schema::Result::*> and C<Schema::ResultSet::*> namespaces and registers them
on the native schema class I<before> workers are forked.

=head2 Shutdown

An C<END> block disconnects all schemas on clean process exit (Ctrl-C, C<kill>,
C<systemctl stop>), calling L<DBIx::Class::Async/disconnect> to gracefully
stop worker processes. The C<before_server_stop> hook is also emitted so
other code can react to shutdown. Only C<SIGKILL> bypasses this — no hook
can help there.

=head1 CONFIGURATION

    'Fondation::Model::DBIx::Async' => {
        backends => {
            main => {
                dsn          => 'dbi:SQLite:dbname=data/app.db',
                schema_class => 'MySchema',
                user         => '',           # optional
                pass         => '',           # optional
                workers      => 2,            # default: 2
                dbi_attrs    => {},           # optional
            },
            logs => {
                dsn          => 'dbi:SQLite:dbname=data/logs.db',
                schema_class => 'MyLogSchema',
                workers      => 1,
            },
        },
        default_backend => 'main',            # optional
        models => {
            user    => { source => 'users' },
            article => { source => 'articles', backend => 'main' },
            log     => { source => 'logs',    backend => 'logs' },
        },
    },

=head3 backends

Hash of named database backends. Each backend requires C<dsn> and
C<schema_class>. Keys are backend names used by models and other plugins
to reference a specific connection.

Plain DSN strings are accepted as a shorthand and normalized to
C<< { dsn => $dsn } >>.

=head3 default_backend

Name of the default backend. When omitted, the first backend in the
C<backends> hash is used. Models without an explicit C<backend> fall
back to this.

=head3 models

Hash of model definitions. Each model maps a name to a database source
(table name). The C<backend> key is optional — it defaults to
C<default_backend> or the first configured backend.

=head1 HELPERS

All helpers are available on the controller object (C<$c>).

=head2 schema_class

  my $class = $c->schema_class;              # from first backend with schema_class
  my $class = $c->schema_class('backend');   # from a specific backend

Returns the schema class name string, without connecting.

=head2 schema

  my $schema = $c->schema;                   # first backend
  my $schema = $c->schema('backend');        # specific backend

Returns a L<DBIx::Class::Async::Schema> instance. Creates it on first access
(lazy, cached per backend). Workers are forked only when the schema is first
connected.

=head2 model

  my $rs = $c->model('user');                # DBIx::Class::Async::ResultSet

Returns a L<DBIx::Class::Async::ResultSet> for the named model. The model
must be declared in configuration. All DML (C<search>, C<create>, C<update>,
C<delete>, C<find>) goes through the worker pool and returns L<Future> objects.

  # Search
  $c->model('user')->search({ active => 1 })->all
      ->on_done(sub { my @users = @_; ... })
      ->on_fail(sub { my $err = shift; ... })
      ->retain;

Always end Future chains with C<< ->retain >> to prevent garbage collection
before the async worker responds.

=head2 model_config

  my $cfg = $c->model_config('user');
  # { name => 'user', source => 'users', backend => 'main' }

Returns model metadata.

=head2 model_list

  my $names = $c->model_list;                # ['article', 'user']

Returns a sorted arrayref of configured model names.

=head2 backend_config

  my $cfg = $c->backend_config;              # first backend
  my $cfg = $c->backend_config('main');
  # { dsn => '...', schema_class => '...', name => 'main', ... }

Returns the full backend configuration hash (including the C<name> key).
Used by other plugins (MigrationDBIx, OpenAPI) to discover connection details.

=head2 default_backend_name

  my $name = $c->default_backend_name;       # 'main'
  my $name = $c->default_backend_name('logs');   # explicit wins

Cascade: explicit parameter → C<default_backend> config → first backend
→ C<undef>.

=head1 PLUGIN INTEGRATION

Plugins that provide DBIC Result classes must declare their C<fondation_meta>:

    sub fondation_meta {
        return {
            dependencies => ['Fondation::Model::DBIx::Async'],
            defaults => {
                models => {
                    user => {
                        source  => 'users',
                        backend => undef,   # resolves to default
                    },
                },
            },
        };
    }

The C<DBIx> action will then auto-discover C<Schema::Result::*> and
C<Schema::ResultSet::*> classes under the plugin's namespace and register
them on the schema.

=head1 SEE ALSO

=over

=item *

L<Mojolicious::Plugin::Fondation> — the Fondation plugin loader

=item *

L<Mojolicious::Plugin::Fondation::MigrationDBIx> — database migrations

=item *

L<DBIx::Class::Async> — async worker-pool wrapper for DBIC

=item *

L<DBIx::Class::Async::Schema> — async schema with forked workers

=back

=cut

sub fondation_meta {
    return {
        dependencies     => [],
        provides_actions => ['DBIx'],
        defaults         => {
            backends        => {},
            models          => {},
            default_backend => undef,
        },
    };
}

sub register ($self, $app, $config) {

    # Normalize backends — plain DSN string → { dsn => $dsn }
    my $backends = $config->{backends} // {};
    for my $name (keys %$backends) {
        if (!ref $backends->{$name}) {
            $backends->{$name} = { dsn => $backends->{$name} };
        }
    }
    $self->{_backends_config} = $backends;
    $self->{_models}          = $config->{models} // {};
    $self->{_default_backend} = $config->{default_backend};

    # Helper: schema_class($backend_name?)
    $app->helper(schema_class => sub ($c, $backend_name = undef) {
        my $bdef;
        if ($backend_name) {
            $bdef = $self->{_backends_config}{$backend_name}
                or die "Backend '$backend_name' not configured\n";
        }
        else {
            for my $name (keys %{$self->{_backends_config}}) {
                my $b = $self->{_backends_config}{$name};
                if ($b->{schema_class}) {
                    $bdef = $b;
                    last;
                }
            }
        }
        return $bdef ? $bdef->{schema_class} : undef;
    });

    # Helper: backend_config($name?)
    $app->helper(backend_config => sub ($c, $name = undef) {
        unless ($name) {
            for my $n (keys %{$self->{_backends_config}}) {
                $name = $n;
                last;
            }
        }
        my $bdef = $self->{_backends_config}{$name}
            or die "Backend '$name' not configured\n";
        return { %$bdef, name => $name };
    });

    # Helper: default_backend_name($explicit?)
    # Cascade: explicit param → $config->{default_backend} → first backend → undef
    $app->helper(default_backend_name => sub ($c, $explicit = undef) {
        return $explicit if $explicit;
        return $self->{_default_backend} if $self->{_default_backend};
        for my $name (keys %{$self->{_backends_config}}) {
            return $name;
        }
        return undef;
    });

    # Helper: model_config($name)
    $app->helper(model_config => sub ($c, $name) {
        my $spec = $self->{_models}{$name}
            or die "Model '$name' is not configured\n";
        return {
            name    => $name,
            source  => $spec->{source} // $name,
            backend => $spec->{backend},
        };
    });

    # Helper: model_list()
    $app->helper(model_list => sub ($c) {
        return [ sort keys %{$self->{_models}} ];
    });

    # Helper: schema($backend_name?)
    $app->helper(schema => sub ($c, $backend_name = undef) {
        $self->{_schemas} //= {};

        my $bname = $backend_name;
        unless ($bname) {
            for my $name (keys %{$self->{_backends_config}}) {
                $bname = $name;
                last;
            }
        }
        return undef unless $bname;
        return $self->{_schemas}{$bname} if exists $self->{_schemas}{$bname};

        my $bdef = $self->{_backends_config}{$bname}
            or die "Backend '$bname' not configured\n";
        die "schema_class is required for backend '$bname'\n"
            unless $bdef->{schema_class};

        require DBIx::Class::Async::Schema;
        require IO::Async::Loop::Mojo;

        my $loop = IO::Async::Loop::Mojo->new;
        $self->{_schemas}{$bname} = DBIx::Class::Async::Schema->connect(
            $bdef->{dsn},
            $bdef->{user}      // '',
            $bdef->{pass}      // '',
            $bdef->{dbi_attrs} // {},
            {
                schema_class => $bdef->{schema_class},
                workers      => $bdef->{workers} // 2,
                loop         => $loop,
            }
        );
        return $self->{_schemas}{$bname};
    });

    # Helper: model($name)
    $app->helper(model => sub ($c, $name) {
        my $models = $self->{_models};
        my $spec = $models->{$name}
            or die "Model '$name' is not configured\n";
        my $source  = $spec->{source} // $name;
        my $backend = $spec->{backend};
        return $c->schema($backend)->resultset($source);
    });

    # Shutdown cleanup: disconnect all DBIC::Async schemas on process exit.
    # END block catches every clean exit (Ctrl-C, kill, hypnotoad stop,
    # systemctl stop). Only SIGKILL bypasses it — no hook can help there.
    $self->{_shutdown} = sub {
        return unless $self->{_schemas};
        for my $bname (keys %{$self->{_schemas}}) {
            if (my $schema = delete $self->{_schemas}{$bname}) {
                DBIx::Class::Async->disconnect($schema);
                $app->log->info(
                    "DBIx::Class::Async workers stopped for backend '$bname'");
            }
        }
    };
    { no warnings 'closure';
      END {
          $app->plugins->emit_hook('before_server_stop' => $app);
          $self->{_shutdown}->() if $self->{_shutdown};
      }
    }

    return $self;
}

sub fondation_finalyze ($self, $app, $long_name) {
    my $manager = $app->manager;
    my $registry = $manager->registry // {};
    return 1 unless %$registry;

    my $models = $self->{_models};

    for my $long (keys %$registry) {
        next if $long eq $long_name;
        my $entry = $registry->{$long};
        my $plugin_config = $entry->{config} // {};
        my $plugin_models = $plugin_config->{models} // {};
        next unless %$plugin_models;

        for my $model_name (keys %$plugin_models) {
            next if exists $models->{$model_name};  # app config wins
            my $plugin_def = $plugin_models->{$model_name};
            $models->{$model_name} = {
                source  => $plugin_def->{source} // $model_name,
                backend => $plugin_def->{backend} // undef,
            };
        }
    }

    # Validate: every model must have a backend
    for my $model_name (sort keys %$models) {
        $models->{$model_name}{backend} //=
            $self->_resolve_default_backend;
        my $bname = $models->{$model_name}{backend}
            or die "Fondation::Model::DBIx::Async: no backend for model '$model_name'"
            . " and no default_backend configured\n";
        die "Fondation::Model::DBIx::Async: backend '$bname' not found for model '$model_name'\n"
            unless $self->{_backends_config}{$bname};
    }

    return 1;
}

sub _resolve_default_backend ($self) {
    return $self->{_default_backend} if $self->{_default_backend};
    for my $name (keys %{$self->{_backends_config}}) {
        return $name;
    }
    return undef;
}

1;
