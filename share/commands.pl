require Text::MicroTemplate;
my $SRVOPT = qr/(?:\-(\S+)\s+)?/;

my $commands = [
  {
    name => 'say',
    re => qr{^(?:/(?:say)?\s+(.*)|([^/].*))}s,
    code => sub {
      my ($self, $app, $window, $msg) = @_;

      if ($window->type eq "info") {
        $window->reply("You can't talk here!");
        return;
      }
      elsif (!$window->connection->is_connected) {
        $window->reply("You are not connected to ".$window->network.".");
        return;
      }

      $window->show($msg);

      $window->connection->send_long_line(PRIVMSG => $window->title, $msg);
      $app->store(nick => $window->nick, channel => $window->title, body => $msg);
    },
  },
  {
    name => 'msg',
    re => qr{^/(?:msg|query)\s+$SRVOPT(\S+)\s*(.*)},
    eg => "/MSG [-<server name>] <nick> <message>",
    desc => "Sends a message to a nick.",
    code => sub  {
      my ($self, $app, $window, $msg, $nick, $network) = @_;

      if (my $connection = $self->determine_connection($app, $window, $network)) {
        my $new_window = $app->find_or_create_window($nick, $connection);
        my @msgs = ($new_window->join_action);

        if ($msg) {
          push @msgs, $new_window->format_message($new_window->nick, $msg);
          $connection->send_srv(PRIVMSG => $nick, $msg) if $msg;
        }

        $app->broadcast(@msgs);
      }
    },
  },
  {
    name => 'nick',
    re => qr{^/nick\s+$SRVOPT(\S+)},
    eg => "/NICK [-<server name>] <new nick>",
    desc => "Changes your nick.",
    code => sub {
      my ($self, $app, $window, $nick, $network) = @_;

      if (my $connection = $self->determine_connection($app, $window, $network)) {
        $connection->log(info => "now known as $nick");
        $connection->send_srv(NICK => $nick);
      }
    },
  },
  {
    name => 'names',
    re => qr{^/n(?:ames)?$},
    in_channel => 1,
    eg => "/NAMES [-avatars]",
    desc => "Lists nicks in current channel.",
    code => sub  {
      my ($self, $app, $window) = @_;
      $window->reply($window->nick_table);
    },
  },
  {
    name => 'join',
    re => qr{^/j(?:oin)?\s+$SRVOPT(.+)},
    eg => "/JOIN [-<server name>] <channel> [<password>]",
    desc => "Joins the specified channel.",
    code => sub  {
      my ($self, $app, $window, $channel, $network) = @_;
      if (my $connection = $self->determine_connection($app, $window, $network)) {
        my @params = split /\s+/, $channel;

        unless ($connection->cl->is_channel_name($params[0])) {
          $window->reply("Invalid channel name: $params[0]");
          return;
        }

        $connection->log(info => "joining $params[0]");
        $connection->send_srv(JOIN => @params);
      }
    },
  },
  {
    name => 'create',
    re => qr{^/create\s+(\S+)},
    code => sub  {
      my ($self, $app, $window, $name) = @_;
      if (my $connection = $window->connection) {
        my $new_window = $app->find_or_create_window($name, $connection);
        $app->broadcast($new_window->join_action);
      }
    },
  },
  {
    name => 'part',
    re => qr{^/(?:close|wc|part)},
    eg => "/PART",
    desc => "Leaves and closes the focused window.",
    code => sub  {
      my ($self, $app, $window) = @_;
      $app->close_window($window);
      $window->connection->send_srv(PART => $window->title) if $window->is_channel and !$window->disabled;
    },
  },
  {
    name => 'clear',
    re => qr{^/clear},
    eg => "/CLEAR",
    desc => "Clears lines from current window.",
    code => sub {
      my ($self, $app, $window) = @_;
      $window->buffer->clear;
      $app->broadcast($window->clear_action);
    },
  },
  {
    name => 'topic',
    re => qr{^/t(?:opic)?(?:\s+(.+))?},
    in_channel => 1,
    eg => "/TOPIC [<topic>]",
    desc => "Shows and/or changes the topic of the current channel.",
    code => sub  {
      my ($self, $app, $window, $new_topic) = @_;
      if ($new_topic) {
        $window->topic({string => $new_topic, nick => $window->nick, time => time});
        $window->connection->send_srv(TOPIC => $window->title, $new_topic);
      }
      else {
        my $topic = $window->topic;
        $app->broadcast($window->format_event("topic", $topic->{author}, $topic->{string}));
      }
    },
  },
  {
    name => 'whois',
    re => qr{^/whois\s+$SRVOPT(\S+)},
    eg => "/WHOIS [-<server name>] <nick>",
    desc => "Shows info about the specified nick",
    code => sub  {
      my ($self, $app, $window, $nick, $network) = @_;

      if (my $connection = $self->determine_connection($app, $window, $network)) {
        $connection->add_whois($nick);
      }
    },
  },
  {
    name => 'me',
    re => qr{^/me\s+(.+)},
    eg => "/ME <message>",
    desc => "Sends a CTCP ACTION to the current window.",
    code => sub {
      my ($self, $app, $window, $action) = @_;
      $window->show("\x{2022} $action");
      $action = AnyEvent::IRC::Util::encode_ctcp(["ACTION", $action]);
      $window->connection->send_srv(PRIVMSG => $window->title, $action);
    },
  },
  {
    name => 'quote',
    re => qr{^/(?:quote|raw)\s+$SRVOPT(.+)},
    eg => "/QUOTE [-<server name>] <data>",
    desc => "Sends the server raw data without parsing.",
    code => sub  {
      my ($self, $app, $window, $command, $network) = @_;

      if (my $connection = $self->determine_connection($app, $window, $network)) {
        $connection->send_raw($command);
      }
    },
  },
  {
    name => 'disconnect',
    re => qr{^/disconnect(?:\s+(\S+))},
    eg => "/DISCONNECT <server name>",
    desc => "Disconnects from the specified server.",
    code => sub  {
      my ($self, $app, $window, $network) = @_;
      my $connection = $app->get_connection($network);
      if ($connection) {
        if ($connection->is_connected) {
          $connection->disconnect;
        }
        elsif ($connection->reconnect_timer) {
          $connection->cancel_reconnect;
          $connection->log(info => "Canceled reconnect timer");
        }
        else {
          $window->reply("Already disconnected");
        }
      }
      else {
        $window->reply("$network isn't one of your networks!");
      }
    },
  },
  {
    name => 'connect',
    re => qr{^/connect(?:\s+(\S+))},
    eg => "/CONNECT <server name>",
    desc => "Connects to the specified server.",
    code => sub {
      my ($self, $app, $window, $network) = @_;
      my $connection = $app->get_connection($network);
      if ($connection) {
        if ($connection->is_connected) {
          $window->reply("Already connected");
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
        $window->reply("$network isn't one of your networks!");
      }
    },
  },
  {
    name => 'ignore',
    re => qr{^/ignore\s+(\S+)},
    eg => "/IGNORE <nick>",
    desc => "Adds nick to ignore list.",
    code => sub  {
      my ($self, $app, $window, $nick) = @_;
      $app->add_ignore($nick);
      $window->reply("Ignoring $nick");
    },
  },
  {
    name => 'unignore',
    re => qr{^/unignore\s+(\S+)},
    eg => "/UNIGNORE <nick>",
    desc => "Removes nick from ignore list.",
    code => sub {
      my ($self, $app, $window, $nick) = @_;
      $app->remove_ignore($nick);
      $window->reply("No longer ignoring $nick");
    },
  },
  {
    name => 'ignores',
    re => qr{^/ignores?},
    eg => "/IGNORES",
    desc => "Lists ignored nicks.",
    code => sub {
      my ($self, $app, $window) = @_;
      my $msg = join ", ", $app->ignores;
      $msg = "none" unless $msg;
      $window->reply("Ignoring:\n$msg");
    },

  },
  {
    name => 'window',
    re => qr{^/w(?:indow)?\s*(\d+|next|prev(?:ious)?)},
    eg => "/WINDOW <window number>",
    desc => "Focuses the provided window number",
    code => sub  {
      my ($self, $app, $window, $window_number) = @_;
      $app->broadcast({
        type => "action",
        event => "focus",
        window_number => $window_number,
      });
    },
  },
  {
    name => 'reload commands',
    re => qr{^/reload commands$},
    code => sub {
      my ($self, $app, $window) = @_;
      $self->reload_handlers;
      $window->reply("Commands reloaded.");
    }
  },
  {
    name => 'away',
    re => qr{^/away(?:\s+(.+))?},
    eg => "/AWAY [<message>]",
    desc => "Set or remove an away message",
    code => sub {
      my ($self, $app, $window, $message) = @_;
      if ($message) {
        $window->reply("Setting away status: $message");
      }
      else {
        $window->reply("Removing away status");
      }

      $app->set_away($message);
    }
  },
  {
    name => 'invite',
    re => qr{^/invite\s+$SRVOPT(\S+)\s+(\S+)},
    eg => "/INVITE <nickname> <channel>",
    desc => "Invite a user to a channel you're in",
    code => sub {
      my ($self, $app, $window, $channel, $nick, $network) = @_;
      if (my $connection = $self->determine_connection($app, $window, $network)) {
        if($nick and $channel){
          $window->reply("Inviting $nick to $channel");
          $connection->send_srv(INVITE => $nick, $channel);   
        }
        else {
          $window->reply("Please specify both a nickname and a channel.");
        }
      }
    },
  },
  {
    name => 'help',
    re => qr{^/help(?:\s+(\S+))?},
    code => sub {
      my ($self, $app, $window, $command) = @_;
      if (!$command) {
        $window->reply('/HELP <command> for help with a specific command');
        $window->reply("Available commands: " . join " ", map {
          uc $_->{name};
        } grep {$_->{eg}} @{$self->handlers});
        return;
      }
      for (@{$self->handlers}) {
        if ($_->{name} eq lc $command) {
          $window->reply("$_->{eg}\n$_->{desc}");
          return;
        }
      }
      $window->reply("No help for ".uc $command);
    },
  },
  {
    name => 'notfound',
    re => qr{^/(.+)(?:\s.*)?},
    code => sub {
      my ($self, $app, $window, $command) = @_;
      $window->reply("Invalid command $command");
    },
  },
];

$commands;
