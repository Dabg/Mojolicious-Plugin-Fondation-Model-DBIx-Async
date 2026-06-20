package Fondation::Model::DBIx::Async::ResultSet;

# ABSTRACT: Fondation ResultSet — with() for fluent many_to_many prefetch

use strict;
use warnings;
use base 'DBIx::Class::Async::ResultSet';

sub with {
    my ($self, @names) = @_;

    for my $name (@names) {
        my $class = $self->result_source->result_class
            or die "Cannot resolve result_class for source";

        no strict 'refs';
        my $meta_hash = ${ $class . '::_fondation_many_to_many' };
        my $meta = $meta_hash->{$name}
            or die "No many_to_many relation '$name' on $class";

        $self->{_fondation_with}{ $meta->{rel} } = $meta->{f_rel};
    }
    return $self;
}

sub all {
    my ($self) = @_;
    return $self->SUPER::all unless $self->{_fondation_with};

    my $schema = $self->{_schema_instance};
    my $source = $self->result_source->source_name;
    my $cond   = $self->{_attrs}{where} // {};

    return $schema->search_with_prefetch($source, $cond, $self->{_fondation_with});
}

sub search {
    my ($self, $cond, $attrs) = @_;
    my $rs = $self->SUPER::search($cond, $attrs);
    $rs->{_fondation_with} = $self->{_fondation_with}
        if $self->{_fondation_with};
    return $rs;
}

1;
