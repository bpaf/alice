package Alice::Role::IRCCommands;

use Any::Moose 'Role';

our %COMMANDS;
my $SRVOPT = qr/(?:\-(\S+)\s+)?/;

sub commands {
  return grep {$_->{eg}} values %COMMANDS;
}

sub irc_command {
  my ($self, $window, $line) = @_;
  eval { $self->match_irc_command($window, $line) };
  $self->announce($@) if $@;
}

sub match_irc_command {
  my ($self, $window, $line) = @_;

  for my $name (keys %COMMANDS) {

    if ($line =~ m{^/$name\s*(.*)}) {

      my $command = $COMMANDS{$name};
      my $args = $1;
      my $req = {line => $line, window => $window};

      # determine the connection if it is required
      if ($command->{connection}) {
        my ($network) = ($args =~ s/^$SRVOPT//);
        $network ||= $window->network;

        die "Must specify a network for /$name" unless $network;

        my $connection = $self->get_connection($network);

        $connection or die "The $network network does not exist.";
        $connection->is_connected or die "The $network network is not connected.";

        $req->{connection} = $connection;
      }

      # must be in a channel
      if ($command->{channel} and !$window->is_channel) {
        die "Must be in a channel for /$name";
      }

      # gather any options
      if (my $opt_re = $command->{opts}) {
        my (@opts) = ($args =~ /$opt_re/);
        $req->{opts} = \@opts;
      }
      else {
        $req->{opts} = [];
      }

      $command->{cb}->($self, $req);
    }
  }
}

sub command {
  my ($name, $opts) = @_;
  $COMMANDS{$name} = $opts;
}

command say => {
  connection => 1,
  channel => 1,
  opts => qr{(.*)},
  cb => sub {
    my ($self, $req) = @_;

    my $msg = $req->{opts}[0];
    my $window = $req->{window};

    $self->broadcast($window->format_message($msg));
    $window->connection->send_long_line(PRIVMSG => $window->title, $msg);
    $self->store(nick => $window->nick, channel => $window->title, body => $msg);
  },
};

command msg => {
  opts => qr{(\S+)\s+(\S*)},
  desc => "Sends a message to a nick.",
  connection => 1,
  cb => sub  {
    my ($self, $req) = @_;

    my ($nick, $msg) = @{ $req->{opts} };

    my $new_window = $self->find_or_create_window($nick, $req->{connection});
    $self->broadcast($new_window->join_action);

    if ($msg) {
      my $connection = $req->{connection};
      $self->broadcast($new_window->format_message($new_window->nick, $msg));
      $connection->send_srv(PRIVMSG => $nick, $msg);
    }
  }
};

command nick => {
  opts => qr{(\S+)},
  connection => 1,
  eg => "/NICK [-<server name>] <new nick>",
  desc => "Changes your nick.",
  cb => sub {
    my ($self, $req) = @_;

    if (my $nick = $req->{opts}[0]) {
      $req->{connection}->log(info => "now known as $nick");
      $req->{connection}->send_srv(NICK => $nick);
    }
  }
};

command qr{n(ames)?} => {
  in_channel => 1,
  eg => "/NAMES [-avatars]",
  desc => "Lists nicks in current channel.",
  cb => sub  {
    my ($self, $req) = @_;
    my $window = $req->{window};
    $self->broadcast($window->format_announcement($window->nick_table));
  },
};

command qr{j(oin)?} => {
  opts => qr{(\S+)\s+(\S+)?},
  eg => "/JOIN [-<server name>] <channel> [<password>]",
  desc => "Joins the specified channel.",
  cb => sub  {
    my ($self, $req) = @_;

    $req->connection->log(info => "joining ".$req->{opts}[0]);
    $req->connection->send_srv(JOIN => @{$req->{opts}});
  },
};

command create => {
  opts => qr{(\S+)},
  connection => 1,
  cb => sub  {
    my ($self, $req) = @_;

    if (my $name = $req->{opts}[0]) {
      my $new_window = $self->find_or_create_window($name, $req->{connection});
      $self->broadcast($new_window->join_action);
    }
  }
};

command qr{close|wc|part} => {
  name => 'part',
  eg => "/PART",
  desc => "Leaves and closes the focused window.",
  cb => sub  {
    my ($self, $req) = @_;

    my $window = $req->window;
    $self->close_window($window);

    if ($window->is_channel) {
      my $connection = $self->get_connection($window->network);
      $connection->send_srv(PART => $window->title);
    }
  },
};

command clear =>  {
  name => 'clear',
  eg => "/CLEAR",
  desc => "Clears lines from current window.",
  cb => sub {
    my ($self, $req) = @_;
    $req->window->buffer->clear;
    $self->broadcast($req->window->clear_action);
  },
};

command qr{t(opic)?} => {
  name => 'topic',
  opts => qr{(.+)?},
  channel => 1,
  connection => 1,
  eg => "/TOPIC [<topic>]",
  desc => "Shows and/or changes the topic of the current channel.",
  cb => sub  {
    my ($self, $req) = @_;

    my $new_topic = $req->{opts}[0];
    my $window = $req->{window};

    if ($new_topic) {
      my $connection = $req->{connection};
      $window->topic({string => $new_topic, nick => $window->nick, time => time});
      $connection->send_srv(TOPIC => $window->title, $new_topic);
    }
    else {
      my $topic = $window->topic;
      $self->broadcast($window->format_event("topic", $topic->{author}, $topic->{string}));
    }
  }
};

command whois =>  {
  name => 'whois',
  connection => 1,
  opts => qr{(\S+)},
  eg => "/WHOIS [-<server name>] <nick>",
  desc => "Shows info about the specified nick",
  cb => sub  {
    my ($self, $req) = @_;

    if (my $nick = $req->{opts}[0]) {
      $req->{connection}->add_whois($nick);
    }
  },
};

command me =>  {
  name => 'me',
  re => qr{(\S+)},
  eg => "/ME <message>",
  connection => 1,
  desc => "Sends a CTCP ACTION to the current window.",
  cb => sub {
    my ($self, $req) = @_;
    my $action = $req->{opts}[0];

    if ($action) {
      my $window = $req->{window};
      my $connection = $req->{connection};

      $self->broadcast($window->format_message("\x{2022} $action"));
      $action = AnyEvent::IRC::Util::encode_ctcp(["ACTION", $action]);
      $connection->send_srv(PRIVMSG => $window->title, $action);
    }
  },
};

command quote => {
  name => 'quote',
  opts => qr{(.+)},
  connection => 1,
  eg => "/QUOTE [-<server name>] <data>",
  desc => "Sends the server raw data without parsing.",
  cb => sub  {
    my ($self, $req) = @_;

    if (my $command = $req->{opts}[0]) {
      $req->{connection}->send_raw($command);
    }
  },
};

command disconnect => {
  name => 'disconnect',
  re => qr{(\S+)},
  eg => "/DISCONNECT <server name>",
  desc => "Disconnects from the specified server.",
  cb => sub  {
    my ($self, $req) = @_;

    my $network = $req->{opts}[0];
    my $connection = $self->get_connection($network);
    my $window = $req->{window};

    if ($connection) {
      if ($connection->is_connected) {
        $connection->disconnect;
      }
      elsif ($connection->reconnect_timer) {
        $connection->cancel_reconnect;
        $connection->log(info => "Canceled reconnect timer");
      }
      else {
        $self->broadcast($window->format_announcement("Already disconnected"));
      }
    }
    else {
      $self->broadcast($window->format_announcement("$network isn't one of your networks!"));
    }
  },
};

command 'connect' => {
  name => 'connect',
  re => qr{(\S+)},
  eg => "/CONNECT <server name>",
  desc => "Connects to the specified server.",
  cb => sub {
    my ($self, $req) = @_;

    my $network = $req->{opts}[0];
    my $connection = $self->get_connection($network);
    my $window = $req->{window};

    if ($connection) {
      if ($connection->is_connected) {
        $self->broadcast($window->format_announcement("Already connected"));
      }
      elsif ($connection->reconnect_timer) {
        $connection->cancel_reconnect;
        $connection->log(info => "Canceled reconnect timer");
        $connection->connect;
      }
      else {
        $connection->connect;
      }
    }
    else {
      $self->broadcast($window->format_announcement("$network isn't one of your networks"));
    }
  }
};

command ignore =>  {
  name => 'ignore',
  opts => qr{(\S+)},
  eg => "/IGNORE <nick>",
  desc => "Adds nick to ignore list.",
  cb => sub  {
    my ($self, $req) = @_;
    
    if (my $nick = $req->{opts}[0]) {
      my $window = $req->{window};
      $self->add_ignore($nick);
      $self->broadcast($window->format_announcement("Ignoring $nick"));
    }
  },
};

command unignore =>  {
  name => 'unignore',
  re => qr{(\S+)},
  eg => "/UNIGNORE <nick>",
  desc => "Removes nick from ignore list.",
  cb => sub {
    my ($self, $req) = @_;
    
    if (my $nick = $req->{opts}[0]) {
      my $window = $req->{window};
      $self->remove_ignore($nick);
      $self->broadcast($window->format_announcement("No longer ignoring $nick"));
    }
  },
};

command ignores => {
  name => 'ignores',
  eg => "/IGNORES",
  desc => "Lists ignored nicks.",
  cb => sub {
    my ($self, $req) = @_;

    my $msg = join ", ", $self->ignores;
    $msg = "none" unless $msg;

    my $window = $req->{window};
    $self->broadcast($window->format_announcement("Ignoring:\n$msg"));
  },
};

command qr{w(indow)?} =>  {
  name => 'window',
  opts => qr{(\d+|next|prev(?:ious)?)},
  eg => "/WINDOW <window number>",
  desc => "Focuses the provided window number",
  cb => sub  {
    my ($self, $req) = @_;
    
    if (my $window_number = $req->{opts}[0]) {
      $self->broadcast({
        type => "action",
        event => "focus",
        window_number => $window_number,
      });
    }
  }
};

command away =>  {
  name => 'away',
  opts => qr{(.+)?},
  eg => "/AWAY [<message>]",
  desc => "Set or remove an away message",
  cb => sub {
    my ($self, $req) = @_;

    my $window = $req->{window};

    if (my $message = $req->{opts}[0]) {
      $self->broadcast($window->format_announcement("Setting away status: $message"));
      $self->set_away($message);
    }
    else {
      $self->broadcast($window->format_announcement("Removing away status."));
      $self->set_away;
    }
  }
};

command invite =>  {
  name => 'invite',
  connection => 1,
  opts => qr{(\S+)\s+(\S+)},
  eg => "/INVITE <nickname> <channel>",
  desc => "Invite a user to a channel you're in",
  cb => sub {
    my ($self, $req) = @_;

    my ($nick, $channel) = @{ $req->{opts} };
    my $window = $req->{opts};

    if ($nick and $channel){
      $self->broadcast($window->format_announcement("Inviting $nick to $channel"));
      $req->{connection}->send_srv(INVITE => $nick, $channel);   
    }
    else {
      $self->broadcast($window->format_announcement("Please specify both a nickname and a channel."));
    }
  },
};

command help => {
  name => 'help',
  opts => qr{(\S+)?},
  cb => sub {
    my ($self, $req) = @_;

    my $window = $req->{window};
    my $command = $req->{opts}[0];

    if (!$command) {
      my $commands = join " ", map {uc $_->{name}} grep {$_->{eg}} values %COMMANDS;
      $self->broadcast($window->format_announcement('/HELP <command> for help with a specific command'));
      $self->broadcast($window->format_announcement("Available commands: $commands"));
      return;
    }

    for (values %COMMANDS) {
      if ($_->{name} eq lc $command) {
        $self->broadcast($window->format_announcement("$_->{eg}\n$_->{desc}"));
        return;
      }
    }

    $self->broadcast($window->format_announcement("No help for ".uc $command));
  }
};

1;
