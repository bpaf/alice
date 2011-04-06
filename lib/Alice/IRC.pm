package Alice::IRC;

use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/split_prefix parse_irc_msg/;
use IRC::Formatting::HTML qw/irc_to_html/;
use List::Util qw/min first/;
use List::MoreUtils qw/uniq none any/;
use Digest::MD5 qw/md5_hex/;
use Any::Moose;
use Encode;

my $email_re = qr/([^<\s]+@[^\s>]+\.[^\s>]+)/;
my $image_re = qr/(https?:\/\/\S+(?:jpe?g|png|gif))/i;

{
  no warnings;

  # YUCK!!!
  *AnyEvent::IRC::Connection::_feed_irc_data = sub {
    my ($self, $line) = @_;
    my $m = parse_irc_msg (decode ("utf8", $line));
    $self->event (read => $m);
    $self->event ('irc_*' => $m);
    $self->event ('irc_' . (lc $m->{command}), $m);
  };

  *AnyEvent::IRC::Connection::mk_msg = \&mk_msg;
  *AnyEvent::IRC::Client::mk_msg = \&mk_msg;
}

has 'cl' => (
  is      => 'rw',
  default => sub {AnyEvent::IRC::Client->new(send_initial_whois => 1)},
);

has 'alias' => (
  isa      => 'Str',
  is       => 'ro',
  required => 1,
);

sub config {
  $_[0]->app->config->servers->{$_[0]->alias};
}

has 'app' => (
  isa      => 'Alice',
  is       => 'ro',
  weak_ref => 1,
  required => 1,
);

has 'reconnect_timer' => (
  is => 'rw'
);

has [qw/reconnect_count connect_time/] => (
  is  => 'rw',
  isa => 'Int',
  default   => 0,
);

sub increase_reconnect_count {$_[0]->reconnect_count($_[0]->reconnect_count + 1)}
sub reset_reconnect_count {$_[0]->reconnect_count(0)}

has [qw/is_connected disabled removed/] => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

has whois => (
  is        => 'rw',
  isa       => 'HashRef[CodeRef]',
  default   => sub {{}},
);

has avatars => (
  is        => 'rw',
  isa       => 'HashRef',
  default   => sub {{}},
);

sub add_whois {
  my ($self, $nick, $cb) = @_;
  $nick = lc $nick;
  $self->whois->{$nick} = {info => "", cb => $cb};
  $self->send_srv(WHOIS => $nick);
}

sub BUILD {
  my $self = shift;
  $self->cl->enable_ssl if $self->config->{ssl};
  $self->disabled(1) unless $self->config->{autoconnect};
  $self->cl->reg_cb(
    registered     => sub{$self->registered($_)},
    channel_remove => sub{$self->multiple_left(@_)},
    channel_topic  => sub{$self->channel_topic(@_)},
    join           => sub{$self->joined(@_)},
    part           => sub{$self->part(@_)},
    nick_change    => sub{$self->nick_change(@_)},
    ctcp_action    => sub{$self->ctcp_action(@_)},
    publicmsg      => sub{$self->publicmsg(@_)},
    privatemsg     => sub{$self->privatemsg(@_)},
    connect        => sub{$self->connected(@_)},
    disconnect     => sub{$self->disconnected(@_)},
    irc_invite     => sub{$self->invite(@_)},
    irc_001        => sub{$self->log_message($_[1])},
    irc_301        => sub{$self->irc_301(@_)}, # AWAY message
    irc_305        => sub{$self->log_message($_[1])}, # AWAY
    irc_306        => sub{$self->log_message($_[1])}, # not AWAY
    irc_352        => sub{$self->irc_352(@_)}, # WHO info
    irc_311        => sub{$self->irc_311(@_)}, # WHOIS info
    irc_312        => sub{$self->irc_312(@_)}, # WHOIS server
    irc_319        => sub{$self->irc_319(@_)}, # WHOIS channels
    irc_318        => sub{$self->irc_318(@_)}, # end of WHOIS
    irc_366        => sub{$self->irc_366(@_)}, # end of NAMES
    irc_372        => sub{$self->log_message(mono => 1, $_[1])}, # MOTD info
    irc_377        => sub{$self->log_message(mono => 1, $_[1])}, # MOTD info
    irc_378        => sub{$self->log_message(mono => 1, $_[1])}, # MOTD info
    irc_401        => sub{$self->irc_401(@_)}, # not a nick
    irc_471        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_473        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_474        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_475        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_477        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_485        => sub{$self->log_message($_[1])}, # JOIN fail
    irc_432        => sub{$self->nick; $self->log_message($_[1])}, # Bad nick
    irc_433        => sub{$self->nick; $self->log_message($_[1])}, # Bad nick
    irc_464        => sub{$self->disconnect("bad USER/PASS")},
  );
  $self->cl->ctcp_auto_reply ('VERSION', ['VERSION', "alice $Alice::VERSION"]);
  $self->connect unless $self->disabled;
}

sub send_srv {
  my $self = shift;
  $self->cl->send_srv(@_);
}

sub send_long_line {
  my ($self, $cmd, @params) = @_;
  my $msg = pop @params;
  my $ident = $self->cl->nick_ident($self->cl->nick);
  my $init_len = length mk_msg($ident, $cmd, @params, " ");

  my $max_len = 500; # give 10 bytes extra margin
  my $line_len = $max_len - $init_len;

  # split up the multiple lines in the message:
  my @lines = split /\n/, $msg;
  @lines = map split_unicode_string ("utf-8", $_, $line_len), @lines;

  $self->cl->send_srv($cmd => @params, $_) for @lines;
}

sub send_raw {
  my $self = shift;
  $self->cl->send_raw(encode "utf8", $_[0]);
}

sub broadcast {
  my $self = shift;
  $self->app->broadcast(@_);
}

sub log {
  my $messages = pop;
  $messages = [ $messages ] unless ref $messages eq "ARRAY";

  my ($self, $level, %options) = @_;

  my @lines = map {$self->format_info($_, %options)} @$messages;
  $self->broadcast(@lines);
  $self->app->log($level => "[".$self->alias . "] $_") for @$messages;
}

sub log_message {
  my $message = pop;

  my ($self, %options) = @_;
  if (@{$message->{params}}) {
    $self->log("debug", %options, [ pop @{$message->{params}} ]);
  }
}

sub format_info {
  my ($self, $message, %options) = @_;
  $self->app->format_info($self->alias, $message, %options);
}

sub window {
  my ($self, $title) = @_;
  return $self->app->find_or_create_window($title, $self);
}

sub find_window {
  my ($self, $title) = @_;
  return $self->app->find_window($title, $self);
}

sub nick {
  my $self = shift;
  my $nick = $self->cl->nick || $self->config->{nick} || "";
}

sub nick_avatar {
  my $self = shift;
  return $self->avatars->{$_[0]} || "";
}

sub channels {
  my $self = shift;
  return keys %{$self->cl->channel_list};
}

sub connect {
  my $self = shift;

  $self->disabled(0);
  $self->increase_reconnect_count;

  $self->cl->{enable_ssl} = $self->config->{ssl} ? 1 : 0;

  # some people don't set these, wtf
  if (!$self->config->{host} or !$self->config->{port}) {
    $self->log(info => "can't connect: missing either host or port");
    return;
  }

  $self->reconnect_count > 1 ? 
    $self->log(info => "reconnecting: attempt " . $self->reconnect_count)
  : $self->log(debug => "connecting");

  $self->cl->connect(
    $self->config->{host}, $self->config->{port}
  );
}

sub connected {
  my ($self, $cl, $err) = @_;

  if ($cl->{socket}) {
    $cl->{socket}->{rbuf_max} = 1024 * 10; # 10K max read buffer
  }

  if (defined $err) {
    $self->log(info => "connect error: $err");
    $self->reconnect();
    return;
  }

  $self->log(info => "connected");
  $self->reset_reconnect_count;
  $self->connect_time(time);
  $self->is_connected(1);

  $self->cl->register(
    $self->nick, $self->config->{username},
    $self->config->{ircname}, $self->config->{password}
  );
}

sub reconnect {
  my ($self, $time) = @_;

  my $interval = time - $self->connect_time;

  if ($interval < 15) {
    $time = 15 - $interval;
    $self->log(debug => "last attempt was within 15 seconds, delaying $time seconds")
  }

  if (!defined $time) {
    # increase timer by 15 seconds each time, until it hits 5 minutes
    $time = min 60 * 5, 15 * $self->reconnect_count;
  }

  $self->log(debug => "reconnecting in $time seconds");
  $self->reconnect_timer(
    AnyEvent->timer(after => $time, cb => sub {
      $self->connect unless $self->is_connected;
    })
  );
}

sub cancel_reconnect {
  my $self = shift;
  $self->reconnect_timer(undef);
  $self->reset_reconnect_count;
}

sub registered {
  my $self = shift;
  my @log;

  $self->cl->enable_ping (300, sub {
    $self->disconnected("ping timeout");
  });
  
  # merge auto-joined channel list with existing channels
  my @channels = uniq @{$self->config->{channels}}, $self->channels;
  my @commands = ();

  push @commands, map {
    my $command = $_;
    sub {
      $self->log(debug => "sending $command");
      $self->send_raw($command);
    }
  } @{$self->config->{on_connect}};

  push @commands, map {
    my $channel = $_;
    sub {
      $self->log(debug => "joining $channel");
      $self->send_srv("JOIN", split /\s+/, $channel);
    }
  } @channels; 
    
  my $t; $t = AE::timer 1, 0.5, sub {
    if (my $command = shift @commands) {
      $command->();
    }
    else {
      undef $t;
    }
  };
};

sub disconnected {
  my ($self, $cl, $reason) = @_;
  delete $self->{disconnect_timer} if $self->{disconnect_timer};
  
  $reason = "" unless $reason;
  return if $reason eq "reconnect requested.";
  $self->log(info => "disconnected: $reason");
  
  $self->event(disconnected => $reason, $self->channels);
  
  $self->is_connected(0);
  $self->reconnect(0) unless $self->disabled;
  
  if ($self->removed) {
    $self->app->remove_irc($self->alias);
    undef $self;
  }
}

sub disconnect {
  my ($self, $msg) = @_;
  $msg ||= $self->app->config->quitmsg;

  $self->disabled(1);

  $self->send_srv(QUIT => $msg);

  $self->{disconnect_timer} = AnyEvent->timer(
    after => 1,
    cb => sub {
      delete $self->{disconnect_timer};
      $self->cl->disconnect($msg);
    }
  );
}

sub remove {
  my $self = shift;
  $self->removed(1);
  $self->disconnect;
}

sub publicmsg {
  my ($self, $cl, $channel, $msg) = @_;

  my $text = $msg->{params}[1];
  my ($nick) = split_prefix($msg->{prefix});

  $self->event(publicmsg => $channel, $nick, $text);
}

sub privatemsg {
  my ($self, $cl, $nick, $msg) = @_;

  my ($from) = split_prefix($msg->{prefix});
  my $text = $msg->{params}[1];

  $self->event(privatemsg => $from, $from, $text);
  $self->send_srv(WHO => $from) unless $self->nick_avatar($from);

}

sub ctcp_action {
  my ($self, $cl, $nick, $channel, $msg, $type) = @_;
  return unless $msg;

  my $dest = ($channel eq $self->nick ? $nick : $channel);
  $self->event(ctcp_action => $dest, $msg);
}

sub nick_change {
  my ($self, $cl, $old_nick, $new_nick, $is_self) = @_;


  my @channels = $self->nick_channels($new_nick)
  $self->event(nick_change => $old_nick, $new_nick, @channels);

  if ($self->avatars->{$old_nick}) {
    $self->avatars->{$new_nick} = delete $self->avatars->{$old_nick};
  }
}

sub invite {
  my ($self, $cl, $msg) = @_;

  my ($from, $channel) = @{$msg->{params}};
  $self->event(invite => $from, $channel);
}

sub joined {
  my ($self, $cl, $nick, $channel, $is_self) = @_;

  $self->event(joined => $nick, $channel, $is_self);

  if ($is_self) {
    # client library only sends WHO if the server doesn't
    # send hostnames with NAMES list (UHNAMES), we to WHO always
    $self->send_srv("WHO" => $channel) if $cl->isupport("UHNAMES");
  }
  else {
    $self->send_srv("WHO" => $nick) unless $self->nick_avatar($nick);
  }
}

sub part {
  my ($self, $cl, $nick, $channel, $is_self, $msg) = @_;

  $self->event(self_part => $channel) if $is_self;
}

sub multiple_left {
  my ($self, $cl, $msg, $channel, @nicks) = @_;
  my $reason = $msg->{params}[0];
  $self->event(parted => $channel, $reason);
}

sub channel_topic {
  my ($self, $cl, $channel, $topic, $nick) = @_;
  $self->event(topic => $channel, $nick, $topic);
}

sub channel_nicks {
  my ($self, $channel, $mode) = @_;
  my $nicks = $self->cl->channel_list($channel);
  return map {
    $mode ? $self->prefix_from_modes($_, $nicks->{$_}).$_ : $_;
  } keys %$nicks;
}

sub prefix_from_modes {
  my ($self, $nick, $modes) = @_;
  for my $mode (keys %$modes) {
    if (my $prefix = $self->cl->map_mode_to_prefix($mode)) {
      return $prefix;
    }
  }
  return "";
}

sub nick_channels {
  my ($self, $nick) = @_;
  grep {any {$nick eq $_} $self->channel_nicks($_)} $self->channels;
}

sub irc_301 {
  my ($self, $cl, $msg) = @_;

  my (undef, $from, $awaymsg) = @{$msg->{params}};
  $self->event(awaymsg => $from, $awaymsg);
}

sub irc_319 {
  my ($self, $cl, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $self->nick;

  my ($nick, $channels) = @{$msg->{params}};

  if (my $whois = $self->whois->{lc $nick}) {
    $whois->{info} .= "\nchannels: " .
    join " ", map {
      my $modes = $self->cl->nick_modes($nick, $_);
      $self->prefix_from_modes($nick, $modes) . $_;
    } split /\s+/, $channels;
  }
}

sub irc_352 {
  my ($self, $cl, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $self->nick;
  
  my (undef, undef, undef, undef, $nick, undef, @real) = @{$msg->{params}};
  my $real = join "", @real;
  $real =~ s/^[0-9*] //;
  if (my $avatar = $self->realname_avatar($real)) {
    $self->avatars->{$nick} = $avatar;
  }
}

sub irc_311 {
  my ($self, $cl, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $self->nick;

  # hector adds an extra nick param or something
  shift @{$msg->{params}} if scalar @{$msg->{params}} > 5;

  my ($nick, $user, $address, undef, $real) = @{$msg->{params}};

  if (my $avatar = $self->realname_avatar($real)) {
    $self->avatars->{$nick} = $avatar;
  }

  if (my $whois = $self->whois->{lc $nick}) {
    $whois->{info} .= "nick: $nick"
                    .  "\nuser: $user"
                    .  "\nreal: $real"
                    .  "\nIP: $address";
  }
}

sub irc_312 {
  my ($self, $cl, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $self->nick;

  my ($nick, $server) = @{$msg->{params}};

  if (my $whois = $self->whois->{lc $nick}) {
    $whois->{info} .= "\nserver: $server";
  }
}

sub irc_318 {
  my ($self, $cl, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $self->nick;

  my $nick = $msg->{params}[0];

  if (my $whois = $self->whois->{lc $nick}) {
    $whois->{cb}->($whois->{info});
    delete $self->whois->{lc $nick};
  }
}

sub irc_366 {
  my ($self, $cl, $msg) = @_;
  if (my $window = $self->find_window($msg->{params}[1])) {
    $window->disabled(0) if $window->disabled;
    $self->broadcast($window->nicks_action);
  }
}

sub irc_401 {
  my ($self, $cl, $msg) = @_;
  if (my $window = $self->find_window($msg->{params}[1])) {
    $self->broadcast($window->format_announcement("No such nick."));
  }
  
  if ($self->whois->{$msg->{params}[1]}) {
    $self->whois->{$msg->{params}[1]}{cb}->();
    delete $self->whois->{$msg->{params}[1]};
  }
}

sub realname_avatar {
  my ($self, $realname) = @_;

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

sub update_realname {
  my ($self, $realname) = @_;
  $self->send_srv(REALNAME => $realname);

  $self->avatars->{$self->nick} = $self->realname_avatar($realname);

  for (grep {$_->previous_nick eq $self->nick} $self->windows) {
    $_->reset_previous_nick;
  }
}

sub is_channel {
  my ($self, $channel) = @_;
  return $self->cl->is_channel_name($channel);
}

sub split_unicode_string {
  my ($enc, $str, $maxlen) = @_;

  return $str unless length (encode ($enc, $str)) > $maxlen;

  my $cur_out = '';
  my $word = '';
  my @lines;

  while (length ($str) > 0) {
    $word .= substr $str, 0, 1, '';

    if ($word =~ /\w\W$/
        || length ($str) == 0
        || length ( encode ($enc, $word)) >= $maxlen) {

      if (length (encode ($enc, $cur_out.$word)) > $maxlen) {
        push @lines, $cur_out;
        $cur_out = '';
      }

      $cur_out .= $word;
      $word = '';
    }
  }

  push @lines, $cur_out if length ($cur_out);
  return @lines;
}

sub mk_msg {
  encode "utf8", AnyEvent::IRC::Util::mk_msg(@_);
}

__PACKAGE__->meta->make_immutable;
1;
