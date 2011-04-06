Alice::Events;

use AnyEvent::IRC::Util qw/split_prefix/;

sub privatemsg {
  my ($self, $window, $nick, $text) = @_;

  return if $self->is_ignore($nick);

  if (my $window = $self->find_or_create_window($nick)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
}

sub publicmsg {
  my ($self, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel)) {
    $self->broadcast($window->format_message($nick, $text)); 
  }
}

sub ctcp_action {
  my ($self, $channel, $nick, $text) = @_;

  return if $self->app->is_ignore($nick);

  if (my $window = $self->find_window($channel)) {
    $self->broadcast($window->format_message($nick, "\x{2022} $text"));
  }
}

sub nick_change {
  my ($self, $old_nick, $new_nick, $channels) = @_;

  $self->broadcast(
    map {$_->format_event("nick", $old_nick, $new_nick)} @channels
  );
}

sub invite {
  my ($self, $channel, $nick) = @_;

  $self->broadcast({
    type => "action",
    event => "announce",
    body => "$nick has invited you to $channel.",
  });
}

sub self_joined {
  my ($self, $channel) = @_;

  my $window = $self->window($channel);
  $window->disabled(0) if $window->disabled;
  $self->broadcast($window->join_action);
}

sub joined {
  my ($self, $nick, $channel) = @_;

  if (my $window = $self->find_window($channel)) {
    $self->broadcast($window->format_event("joined", $nick));
  }
}

sub self_parted {
  my ($self, $channel) = @_;

  if ($window = $self->find_window($channel)) {
    $self->close_window($window);
  }
}

sub parted {
  my ($self, $channel, $reason,  @nicks) = @_;

  if (my $window = $self->find_window($channel)) {
    $self->broadcast(map {$window->format_event("left", $_, $reason)} @nicks);
  }
}

sub topic {
  my ($self, $channel, $topic, $nick) = @_;

  if (my $window = $self->find_window($channel)) {
    $window->disabled(0) if $window->disabled;
    $topic = irc_to_html($topic, classes => 1, invert => "italic");
    $window->topic({string => $topic, author => $nick, time => time});
    $self->broadcast($window->format_event("topic", $nick, $topic));
  }
}

sub disconnected {
  my ($self, $reason, @channels) = @_;
  $_->disabled(1) for map {$_->find_window($_)} @channels;
}

sub awaymsg {
  my ($self, $nick, $awaymsg) = @_;

  if (my $window = $self->find_window($nick)) {
    $awaymsg = "$from is away ($awaymsg)";
    $window->reply($awaymsg);
  }
}

sub nicks_updated {
  my ($self, $channel, @nicks) = @_;
}

1;
