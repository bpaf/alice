package Alice::MessageStore::Memory;

use Any::Moose;

has msgid => (
  is => 'rw',
  default => 1,
);

has buffersize => (
  is => 'rw',
  default => 100,
);

has store => (
  is => 'rw',
  default => sub {{}},
);

sub next_msgid {
  my $self = shift;
  $self->msgid($self->msgid + 1);
  return $self->msgid;
}

sub clear {
  my ($self, $id) = @_;
  delete $self->store->{$id};
}

sub add_message {
  my ($self, $id, $message) = @_;

  push @{$self->store->{$id}}, $message;
  if (@{$self->store->{$id}} > $self->buffersize) {
    shift @{$self->store->{$id}};
  }
}

sub _messages {
  my ($self, $id) = @_;
  if ($self->store->{$id}) {
    return @{$self->store->{$id}};
  }
  return ();
}

sub messages {
  my ($self, $id, $limit, $min, $cb) = @_;

  my @messages = grep {$_->{msgid} > $min} $self->_messages($id);
  my $total = scalar @messages;

  if (!$total) {
    $cb->([]);
    return;
  }
  
  $limit = $total if $limit > $total;
  $cb->([ @messages[$total - $limit .. $total - 1] ]);
}

1;
