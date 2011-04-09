package Alice::Connection;

use Any::Moose;
use Object::Event;

use parent 'Object::Event';

has avatars => (
  is => 'rw',
  default => sub {{}},
);

has nick => (
  is => 'rw',
  lazy => 1,
  default => sub {$_[0]->config->{nick}},
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

1;
