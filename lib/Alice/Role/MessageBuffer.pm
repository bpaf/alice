package Alice::Role::MessageBuffer;

use Any::Moose 'Role';

our $BACKEND = "Memory";
our $STORE;

sub store {
  if (!$STORE) {
    $STORE = do {
      my $class = "Alice::MessageStore::$BACKEND";
      eval "use $class;";
      $class->new;
    };
  }
  return $STORE;
}

has previous_nick => (
  is => 'rw',
  default => "",
);

sub msgid {
  my $self = shift;
  return $self->store->msgid;
}

sub next_msgid {
  my $self = shift;
  $self->store->next_msgid;
}

sub clear {
  my $self = shift;
  $self->previous_nick("");
  $self->store->clear($self->id);
}

sub add_message {
  my ($self, $message) = @_;
  $message->{event} eq "say" ? $self->previous_nick($message->{nick})
                             : $self->previous_nick("");

  $self->store->add_message($self->id, $message);
}

sub messages {
  my ($self, $limit, $min, $cb) = @_;

  my $msgid = $self->store->msgid;

  $min = 0 unless $min > 0;
  $min = $msgid if $min > $msgid;

  $limit = $msgid - $min if $min + $limit > $msgid;
  $limit = 0 if $limit < 0;

  return $self->store->messages($self->id, $limit, $min, $cb);
}

1;
