package Alice::Connection;

use Any::Moose;
use Object::Event;

use parent 'Object::Event';

has avatars => (
  is => 'rw',
  default => sub {{}},
);

has config => (
  is => 'rw',
  isa => 'HashRef',
  required => 1,
);

sub nick_avatar {
  my ($self, $nick) = @_;
  return $self->avatars->{$nick};
}

sub log {
  my ($self, $level, $msg, %options) = @_;
  $self->event('log' => $level, $msg, %options);
}

sub id {
  my $self = shift;
  return $self->config->{name};
}

sub nick {
  my $self = shift;
  $self->config->{nick}},
);

1;
