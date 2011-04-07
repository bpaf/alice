package Alice::Events;

use Any::Moose 'Role';
use IRC::Formatting::HTML qw/irc_to_html/;
use Scalar::Util qw/weaken/;

requires 'add_irc';

our %CALLBACKS;

around add_irc => sub {
  my ($orig, $self, $irc) = @_;
  $irc->reg_cb($self->events);
  $self->$orig($irc);
};

sub events {
  my $self = shift;
  weaken $self;
  map {
    my $event = $_;
    $event => sub {$CALLBACKS{$event}->($self, @_)}
  } keys %CALLBACKS;
}

sub on ($&) {
  my ($name, $cb) = @_;
  $CALLBACKS{$name} = $cb;
}

on privatemsg => sub {
  my ($self, $irc, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_or_create_window($nick, $irc)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on publicmsg => sub {
  my ($self, $irc, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel, $irc)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
};

on ctcp_action => sub {
  my ($self, $irc, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel, $irc)) {
    $self->broadcast($window->format_message($nick, "\x{2022} $text"));
  }
};

on nick_change => sub {
  my ($self, $irc, $old_nick, $new_nick, @channels) = @_;

  if ($self->avatars->{$old_nick}) {
    $self->avatars->{$new_nick} = delete $self->avatars->{$old_nick};
  }

  my @windows = map {$self->find_window($_, $irc)} @channels;

  $self->broadcast(
    map {$_->format_event("nick", $old_nick, $new_nick)} @windows
  );
};

on invite => sub {
  my ($self, $irc, $channel, $nick) = @_;

  $self->broadcast({
    type => "action",
    event => "announce",
    body => "$nick has invited you to $channel.",
  });
};

on self_join => sub {
  my ($self, $irc, $channel) = @_;

  if (my $window = $self->find_or_create_window($channel, $irc)) {
    $window->disabled(0) if $window->disabled;
    $self->broadcast($window->join_action);
  }
};

on 'join' => sub {
  my ($self, $irc, $nick, $channel) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    $self->broadcast($window->format_event("joined", $nick));
  }
};

on self_part => sub {
  my ($self, $irc, $channel) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    $self->close_window($window);
  }
};

on part => sub {
  my ($self, $irc, $channel, $reason,  @nicks) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    $self->broadcast(map {$window->format_event("left", $_, $reason)} @nicks);
  }
};

on topic => sub {
  my ($self, $irc, $channel, $topic, $nick) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    $window->disabled(0) if $window->disabled;
    $topic = irc_to_html($topic, classes => 1, invert => "italic");
    $window->topic({string => $topic, author => $nick, time => time});
    $self->broadcast($window->format_event("topic", $nick, $topic));
  }
};

on disconnect => sub {
  my ($self, $irc, $reason, @channels) = @_;
  $_->disabled(1) for map {$self->find_window($_, $irc)} @channels;
};

on awaymsg => sub {
  my ($self, $irc, $nick, $awaymsg) = @_;

  if (my $window = $self->find_window($nick, $irc)) {
    $window->reply("$nick is away ($awaymsg)");
  }
};

on nicklist_update => sub {
  my ($self, $irc, $channel, @nicks) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    $window->disabled(0) if $window->disabled;
    $self->broadcast($window->nicks_action);
  }
};

on notnick => sub {
  my ($self, $irc, $nick) = @_;

  if (my $window = $self->find_window($nick, $irc)) {
    $self->broadcast($window->format_announcement("No such nick."));
  }
};

on whois => sub {
  my ($self, $irc, $nick, $info) = @_;

};

on realname_change => sub {
  my ($self, $irc, $nick, $realname) = @_;
  $self->avatars->{$nick} = realname_avatar($realname);
};

on remove => sub {
  my ($self, $irc) = shift;
  $self->remove_irc($irc);
};

1;
