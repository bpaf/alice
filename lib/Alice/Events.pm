package Alice::Events;

use Any::Moose 'Role';
use IRC::Formatting::HTML qw/irc_to_html/;
use Scalar::Util qw/weaken/;

my $email_re = qr/([^<\s]+@[^\s>]+\.[^\s>]+)/;
my $image_re = qr/(https?:\/\/\S+(?:jpe?g|png|gif))/i;

requires qw/add_irc/;

our %CALLBACKS;

around add_irc => sub {
  my ($orig, $self, $conn) = @_;
  $conn->{reg_guard} = $conn->reg_cb($self->events);
  $self->$orig($conn);
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
  my ($self, $conn, $level, $message, %options) = @_;
  my $info = $self->info_window;
  $self->log($level, $message, %options);
};

on privatemsg => sub {
  my ($self, $conn, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_or_create_window($nick, $conn)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on publicmsg => sub {
  my ($self, $conn, $channel, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_window($channel, $conn)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on ctcp_action => sub {
  my ($self, $conn, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel, $conn)) {
    $self->broadcast($window->format_message($nick, "\x{2022} $text"));
  }
};

on nick_change => sub {
  my ($self, $conn, $old_nick, $new_nick, @channels) = @_;

  if ($self->avatars->{$old_nick}) {
    $conn->avatars->{$new_nick} = delete $self->avatars->{$old_nick};
  }

  my @windows = map {$self->find_window($_, $conn)} @channels;

  $self->broadcast(
    map {$_->format_event("nick", $old_nick, $new_nick)} @windows
  );
};

on invite => sub {
  my ($self, $conn, $channel, $nick) = @_;

  $self->broadcast({
    type => "action",
    event => "announce",
    body => "$nick has invited you to $channel.",
  });
};

on self_join => sub {
  my ($self, $conn, $channel) = @_;

  if (my $window = $self->find_or_create_window($channel, $conn)) {
    $window->disabled(0) if $window->disabled;
    $self->broadcast($window->join_action);
  }
};

on 'join' => sub {
  my ($self, $conn, $nick, $channel) = @_;

  if (my $window = $self->find_window($channel, $conn)) {
    $self->broadcast($window->format_event("joined", $nick));
  }
};

on self_part => sub {
  my ($self, $conn, $channel) = @_;

  if (my $window = $self->find_window($channel, $conn)) {
    $self->close_window($window);
  }
};

on part => sub {
  my ($self, $conn, $channel, $reason,  @nicks) = @_;

  if (my $window = $self->find_window($channel, $conn)) {
    $self->broadcast(map {$window->format_event("left", $_, $reason)} @nicks);
  }
};

on topic => sub {
  my ($self, $conn, $channel, $nick, $topic) = @_;

  if (my $window = $self->find_window($channel, $conn)) {
    $window->disabled(0) if $window->disabled;
    $topic = irc_to_html($topic, classes => 1, invert => "italic");
    $window->topic({string => $topic, author => $nick, time => time});
    $self->broadcast($window->format_event("topic", $nick, $topic));
  }
};

on disconnect => sub {
  my ($self, $conn, $reason, @channels) = @_;
  $_->disabled(1) for map {$self->find_window($_, $conn)} @channels;
};

on awaymsg => sub {
  my ($self, $conn, $nick, $awaymsg) = @_;

  if (my $window = $self->find_window($nick, $conn)) {
    $window->reply("$nick is away ($awaymsg)");
  }
};

on nicklist_update => sub {
  my ($self, $conn, $channel, @nicks) = @_;

  if (my $window = $self->find_window($channel, $conn)) {
    $window->disabled(0) if $window->disabled;
    $self->broadcast($window->nicks_action);
  }
};

on notnick => sub {
  my ($self, $conn, $nick) = @_;

  if (my $window = $self->find_window($nick, $conn)) {
    $self->broadcast($window->format_announcement("No such nick."));
  }
};

on whois => sub {
  my ($self, $conn, $nick, $info) = @_;
};

on realname_change => sub {
  my ($self, $conn, $nick, $realname) = @_;
  $self->avatars->{$nick} = realname_avatar($realname);
};

on remove => sub {
  my ($self, $conn) = shift;
  delete $conn->{reg_guard};
  $self->remove_irc($conn);
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
