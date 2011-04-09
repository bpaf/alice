package Alice::Role::MessageBuffer;

use Alice::MessageStore::DBI;
use Any::Moose 'Role';

our $STORE = Alice::MessageStore::DBI->new;

has previous_nick => (
  is => 'rw',
  default => "",
);

sub msgid {
  my $self = shift;
  return $STORE->msgid;
}

sub next_msgid {
  my $self = shift;
  $STORE->next_msgid;
}

sub clear {
  my $self = shift;
  $self->previous_nick("");
  $STORE->clear($self->id);
}

sub add_message {
  my ($self, $message) = @_;
  $message->{event} eq "say" ? $self->previous_nick($message->{nick})
                             : $self->previous_nick("");

  $STORE->add_message($self->id, $message);
}

sub messages {
  my ($self, $limit, $min, $cb) = @_;

  my $msgid = $STORE->msgid;

  $min = 0 unless $min > 0;
  $min = $msgid if $min > $msgid;

  $limit = $msgid - $min if $min + $limit > $msgid;
  $limit = 0 if $limit < 0;

  return $STORE->messages($self->id, $limit, $min, $cb);
}

1;
