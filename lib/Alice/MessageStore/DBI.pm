package Alice::MessageStore::DBI;

use AnyEvent::DBI;
use DBI;
use JSON;

use Any::Moose;

our $DSN = ["dbi:SQLite:dbname=share/buffer.db", "", ""];

has insert_timer => (is => 'rw');
has trim_timer => (is => 'rw');

has msgid => (
  is => 'rw',
  default => 1,
);

has insert_queue => (
  is => 'rw',
  default => sub {[]},
);

has _trim_queue => (
  is => 'rw',
  default => sub {{}},
);

sub next_msgid {
  my $self = shift;
  $self->msgid($self->msgid + 1);
  $self->msgid;
}

sub BUILD {
  my $self = shift;
  # block to get the min msgid
  my $dbh = DBI->connect(@$DSN);
  my $row = $dbh->selectrow_arrayref("SELECT msgid FROM window_buffer ORDER BY msgid DESC LIMIT 1");

  $self->msgid($row->[0] + 1) if $row;
}

sub trim_queue {
  my $self = shift;
  return keys %{$self->_trim_queue};
}

sub clear_trim_queue {
  my $self = shift;
  $self->_trim_queue({});
}

has buffersize => (
  is => 'rw',
  default => 100,
);

has dbi => (
  is => 'rw',
  default => sub { AnyEvent::DBI->new(@$DSN) }
);

sub add_trim_job {
  my ($self, $id) = @_;
  $self->_trim_queue->{$id} = 1;
}

sub add_insert_job {
  my ($self, $job) = @_;
  push @{$self->insert_queue}, $job;
}

sub shift_insert_job {
  my ($self) = @_;
  shift @{$self->insert_queue};
}

sub clear {
  my ($self, $id) = @_;
  $self->dbi->exec("DELETE FROM window_buffer WHERE window_id = ?", $id, sub {});
}

sub messages {
  my ($self, $id, $limit, $msgid, $cb) = @_;
  $self->dbi->exec(
    "SELECT message FROM window_buffer WHERE window_id=? AND msgid > ? ORDER BY msgid DESC LIMIT ?",
    $id, $msgid, $limit, sub { $cb->([map {decode_json $_->[0]} reverse @{$_[1]}]) }
  );
}

sub add_message {
  my ($self, $id, $message) = @_;

  # collect inserts for one second

  $self->add_insert_job([$id, $message->{msgid}, encode_json($message)]);
  $self->add_trim_job($id);

  if (!$self->insert_timer) {
    $self->insert_timer(AE::timer 1, 0, $self->_handle_insert);
  }
}

sub _handle_insert {
  my $self = shift;

  return sub {
    my $idle_w; $idle_w = AE::idle sub {
      if (my $row = $self->shift_insert_job) {
        $self->dbi->exec("INSERT INTO window_buffer (window_id, msgid, message) VALUES (?,?,?)", @$row, sub{});
      }
      else {
        undef $idle_w;
        $self->insert_timer(undef);
      }
    };
  
    if (!$self->trim_timer) {
      $self->trim_timer(AE::timer 60, 0, $self->_handle_trim);
    }
  };
}

sub _handle_trim {
  my $self = shift;

  return sub {
    my @trim = $self->trim_queue;
    $self->clear_trim_queue;

    my $idle_w; $idle_w = AE::idle sub {
      if (my $window_id = shift @trim) {
        $self->_trim($window_id);
      }
      else {
        undef $idle_w;
        $self->trim_timer(undef);
      }
    };
  };
}

sub _trim {
  my ($self, $window_id) = @_;

  $self->dbi->exec(
    "SELECT msgid FROM window_buffer WHERE window_id=? ORDER BY msgid DESC LIMIT 100,1",
    $window_id, sub {
      my $rows = $_[1];
      if (@$rows) {
        my $minid = $rows->[0][0];
        $self->dbi->exec(
          "DELETE FROM window_buffer WHERE window_id=? AND msgid < ?",
          $window_id, $minid, sub{}
        );
      }
    }
  );
}

1;
