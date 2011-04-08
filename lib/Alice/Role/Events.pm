package Alice::Role::Events;

use Any::Moose 'Role';
use IRC::Formatting::HTML qw/irc_to_html/;
use Scalar::Util qw/weaken/;
use Digest::MD5 qw/md5_hex/;

my $email_re = qr/([^<\s]+@[^\s>]+\.[^\s>]+)/;
my $image_re = qr/(https?:\/\/\S+(?:jpe?g|png|gif))/i;

requires qw/add_connection/;

our %CALLBACKS;

around add_connection => sub {
  my ($orig, $self, $connection) = @_;
  $connection->{reg_guard} = $connection->reg_cb($self->events);
  $self->$orig($connection);
};

sub events {
  my $self = shift;
  weaken $self;
  map {
    my $event = $_;
    $event => sub {
      return unless defined $self;
      $CALLBACKS{$event}->($self, @_);
    }
  } keys %CALLBACKS;
}

sub on ($&) {
  my ($name, $cb) = @_;
  $CALLBACKS{$name} = $cb;
}

on 'log' => sub {
  my ($self, $connection, $level, $message, %options) = @_;
  $options{network} = $connection->id;
  $self->log($level, $message, %options);
};

on privatemsg => sub {
  my ($self, $connection, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_or_create_window($nick, $connection)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on publicmsg => sub {
  my ($self, $connection, $channel, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_window($channel, $connection)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on ctcp_action => sub {
  my ($self, $connection, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel, $connection)) {
    $self->broadcast($window->format_message($nick, "\x{2022} $text"));
  }
};

on nick_change => sub {
  my ($self, $connection, $old_nick, $new_nick, @channels) = @_;

  if ($self->avatars->{$old_nick}) {
    $connection->avatars->{$new_nick} = delete $self->avatars->{$old_nick};
  }

  my @windows = map {$self->find_window($_, $connection)} @channels;

  $self->broadcast(
    map {$_->format_event("nick", $old_nick, $new_nick)} @windows
  );
};

on invite => sub {
  my ($self, $connection, $channel, $nick) = @_;

  $self->broadcast({
    type => "action",
    event => "announce",
    body => "$nick has invited you to $channel.",
  });
};

on self_join => sub {
  my ($self, $connection, $channel) = @_;

  if (my $window = $self->find_or_create_window($channel, $connection)) {
    if ($window->disabled) {
      $window->disabled(0);
      $self->broadcast($window->connect_action);
    }
    $self->broadcast($window->join_action);
  }
};

on 'join' => sub {
  my ($self, $connection, $nick, $channel) = @_;

  if (my $window = $self->find_window($channel, $connection)) {
    $self->broadcast($window->format_event("joined", $nick));
  }
};

on self_part => sub {
  my ($self, $connection, $channel) = @_;

  if (my $window = $self->find_window($channel, $connection)) {
    $self->close_window($window);
  }
};

on part => sub {
  my ($self, $connection, $channel, $reason,  @nicks) = @_;

  if (my $window = $self->find_window($channel, $connection)) {
    $self->broadcast(map {$window->format_event("left", $_, $reason)} @nicks);
  }
};

on topic => sub {
  my ($self, $connection, $channel, $nick, $topic) = @_;

  if (my $window = $self->find_window($channel, $connection)) {
    if ($window->disabled) {
      $window->disabled(0);
      $self->broadcast($window->connect_action);
    }
    $topic = irc_to_html($topic, classes => 1, invert => "italic");
    $window->topic({string => $topic, author => $nick, time => time});
    $self->broadcast($window->format_event("topic", $nick, $topic));
  }
};

on disconnect => sub {
  my ($self, $connection, $reason) = @_;

  my @windows = $self->connection_windows($connection);

  $_->disabled(1) for @windows;
  my @events = map {$_->format_event("disconnect", "You", $_->network)} @windows;

  $self->broadcast(
    @events,
    {
      type => "action",
      event => "disconnect",
      network => $connection->id,
      windows => [map {$_->serialized} @windows ],
    }
  );
};

on 'connect' => sub {
  my ($self, $connection, $reason) = @_;
  $self->broadcast(
    {
      type => "action",
      event => "connect",
      network => $connection->id,
      windows => [],
    }
  );
};

on awaymsg => sub {
  my ($self, $connection, $nick, $awaymsg) = @_;

  if (my $window = $self->find_window($nick, $connection)) {
    $window->reply("$nick is away ($awaymsg)");
  }
};

on nicklist_update => sub {
  my ($self, $connection, $channel, @nicks) = @_;

  if (my $window = $self->find_window($channel, $connection)) {
    $window->nicks(@nicks);
    if ($window->disabled) {
      $window->disabled(0);
      $self->broadcast($window->connect_action);
    }
    $self->broadcast($window->nicks_action);
  }
};

on not_nick => sub {
  my ($self, $connection, $nick) = @_;

  if (my $window = $self->find_window($nick, $connection)) {
    $self->broadcast($window->format_announcement("No such nick."));
  }
};

on whois => sub {
  my ($self, $connection, $nick, $info) = @_;

  $self->broadcast({
    type => "action",
    event => "announce",
    body => join "\n", map {"$_: $info->{$_}"} keys %$info,
  });
};

on realname_change => sub {
  my ($self, $connection, $nick, $realname) = @_;
  $self->avatars->{$nick} = realname_avatar($realname);
};

on shutdown => sub {
  my ($self, $connection) = @_;
  delete $connection->{reg_guard};
  $self->remove_connection($connection);
};

sub realname_avatar {
  my $realname = shift;
  return () unless $realname;

  if ($realname =~ $email_re) {
    my $email = $1;
    return "http://www.gravatar.com/avatar/"
           . md5_hex($email) . "?s=32&amp;r=x";
  }
  elsif ($realname =~ $image_re) {
    return $1;
  }

  return ();
}

1;
