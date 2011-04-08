package Alice;

use AnyEvent;
use Alice::Window;
use Alice::InfoWindow;
use Alice::MessageBuffer;
use Alice::HTTPD;
use Alice::Connection::IRC;
use Alice::Config;
use Alice::Tabset;

use Any::Moose;

use File::Copy;
use List::Util qw/first/;
use List::MoreUtils qw/any none/;
use AnyEvent::IRC::Util qw/filter_colors/;
use IRC::Formatting::HTML qw/html_to_irc/;
use File::ShareDir qw/dist_dir/;
use FindBin;
use Encode;

with 'Alice::Role::Template';
with 'Alice::Role::Events';
with 'Alice::Role::HTTPRoutes';
with 'Alice::Role::IRCCommands';
with 'Alice::Role::History';

our $VERSION = '0.19';

our $ASSETDIR = do {
  my $bin = $FindBin::Bin;
  -e "$bin/../share/static" ? "$bin/../share" : dist_dir('App-Alice');
};

has config => (
  is       => 'rw',
  isa      => 'Alice::Config',
);

has _connections => (
  is      => 'rw',
  isa     => 'HashRef',
  default => sub {{}},
);

sub connections {values %{$_[0]->_connections}}
sub add_connection {$_[0]->_connections->{$_[1]->id} = $_[1]}
sub has_connection {$_[0]->get_connection($_[1])}
sub get_connection {$_[0]->_connections->{$_[1]}}
sub remove_connection {delete $_[0]->_connections->{$_[1]->id}}
sub open_connections {grep {$_->is_connected} $_[0]->connections}

has httpd => (
  is      => 'rw',
  isa     => 'Alice::HTTPD',
  lazy    => 1,
  default => sub {
    my $self = shift;
    Alice::HTTPD->new(
      address => $self->config->http_address,
      port => $self->config->http_port,
      assetdir => $ASSETDIR,
      sessiondir => $self->config->path."/sessions",
    );
  },
);

has streams => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub {[]},
);

sub add_stream {unshift @{shift->streams}, @_}
sub no_streams {@{$_[0]->streams} == 0}
sub stream_count {scalar @{$_[0]->streams}}

sub log {
  my ($self, $level, $message, %options) = @_;

  if ($level eq "info") {
    my $from = delete $options{network} || "config";
    my $line = $self->info_window->format_message($from, $message, %options);
    $self->broadcast($line);
  }

  if ($self->config->show_debug) {
    my ($sec, $min, $hour, $day, $mon, $year) = localtime(time);
    my $datestring = sprintf "%02d:%02d:%02d %02d/%02d/%02d",
                     $hour, $min, $sec, $mon, $day, $year % 100;
    print STDERR substr($level, 0, 1) . ", [$datestring] "
               . sprintf("% 5s", $level) . " -- : $message\n";
  }
}

has _windows => (
  is        => 'rw',
  isa       => 'HashRef',
  default   => sub {{}},
);

sub windows {values %{$_[0]->_windows}}
sub add_window {$_[0]->_windows->{$_[1]->id} = $_[1]}
sub has_window {$_[0]->get_window($_[1])}
sub get_window {$_[0]->_windows->{$_[1]}}
sub remove_window {delete $_[0]->_windows->{$_[1]}}
sub window_ids {keys %{$_[0]->_windows}}

has 'info_window' => (
  is => 'ro',
  isa => 'Alice::InfoWindow',
  lazy => 1,
  default => sub {
    my $self = shift;
    my $id = $self->_build_window_id("info", "info");
    my $info = Alice::InfoWindow->new(
      id       => $id,
      buffer   => $self->new_window_buffer($id),
    );
    $self->add_window($info);
    return $info;
  }
);

has 'user' => (
  is => 'ro',
  default => $ENV{USER}
);

sub BUILDARGS {
  my ($class, %options) = @_;

  my $self = {};

  for (qw/template user httpd/) {
    if (exists $options{$_}) {
      $self->{$_} = $options{$_};
      delete $options{$_};
    }
  }

  $self->{config} = Alice::Config->new(
    %options,
    callback => sub {$self->{config}->merge(\%options)}
  );

  return $self;
}

sub run {
  my $self = shift;

  # wait for config to finish loading
  my $w; $w = AE::idle sub {
    return unless $self->config->{loaded};
    undef $w;
    $self->init;
  };
}

sub init {
  my $self = shift;
  $self->info_window;
  $self->httpd;

  $self->add_new_connection($_, $self->config->servers->{$_})
    for keys %{$self->config->servers};
}

sub init_shutdown {
  my ($self, $cb, $msg) = @_;

  $self->alert("Alice server is shutting down");
  $_->disconnect($msg) for $self->open_connections;

  my ($w, $t);
  my $shutdown = sub {
    $self->shutdown;
    $cb->() if $cb;
    undef $w;
    undef $t;
  };

  $w = AE::idle sub {$shutdown->() unless $self->open_connections};
  $t = AE::timer 3, 0, $shutdown;
}

sub shutdown {
  my $self = shift;
  $_->close for @{$self->streams};
}

sub new_window_buffer {
  my ($self, $id) = @_;
  Alice::MessageBuffer->new(
    id => $id,
    store_class => $self->config->message_store
  );
}

sub tab_order {
  my ($self, $window_ids) = @_;
  my $order = [];
  for my $count (0 .. scalar @$window_ids - 1) {
    if (my $window = $self->get_window($window_ids->[$count])) {
      next unless $window->is_channel
           and $self->config->servers->{$window->network};
      push @$order, $window->title;
    }
  }
  $self->config->order($order);
  $self->config->write;
}

sub find_window {
  my ($self, $title, $connection) = @_;
  return $self->info_window if $title eq "info";
  my $id = $self->_build_window_id($title, $connection->id);
  if (my $window = $self->get_window($id)) {
    return $window;
  }
}

sub alert {
  my ($self, $message) = @_;
  return unless $message;
  $self->broadcast({
    type => "action",
    event => "alert",
    body => $message,
  });
}

sub create_window {
  my ($self, $title, $connection) = @_;
  my $id = $self->_build_window_id($title, $connection->id);
  my $window = Alice::Window->new(
    title    => $title,
    network  => $connection->id,
    id       => $id,
    buffer   => $self->new_window_buffer($id),
  );
  $self->add_window($window);
  return $window;
}

sub _build_window_id {
  my ($self, $title, $network) = @_;
  md5_hex(lc $self->user."-$title-$network");
}

sub find_or_create_window {
  my ($self, $title, $connection) = @_;
  return $self->info_window if $title eq "info";

  if (my $window = $self->find_window($title, $connection)) {
    return $window;
  }

  $self->create_window($title, $connection);
}

sub sorted_windows {
  my $self = shift;
  my %o;
  if ($self->config->order) {
    %o = map {$self->config->order->[$_] => sprintf "%02d", $_ + 2}
             0 .. @{$self->config->order} - 1;
  }
  $o{info} = "01";
  my $prefix = scalar @{$self->config->order} + 1;
  sort { ($o{$a->title} || $prefix.$a->sort_name) cmp ($o{$b->title} || $prefix.$b->sort_name) }
       $self->windows;
}

sub close_window {
  my ($self, $window) = @_;
  $self->broadcast($window->close_action);
  $self->log(debug => "sending a request to close a tab: " . $window->title)
    if $self->stream_count;
  $self->remove_window($window->id) if $window->type ne "info";
}

sub add_new_connection {
  my ($self, $name, $config) = @_;

  $self->config->servers->{$name} = $config;
  my $conn = Alice::Connection::IRC->new(config => $config);
  $self->add_connection($conn);
}

sub reload_config {
  my ($self, $new_config) = @_;

  my %prev = map {$_ => $self->config->servers->{$_}{ircname} || ""}
             keys %{ $self->config->servers };

  if ($new_config) {
    $self->config->merge($new_config);
    $self->config->write;
  }
  
  for my $network (keys %{$self->config->servers}) {
    my $config = $self->config->servers->{$network};
    if (!$self->has_connection($network)) {
      $self->add_new_connection($network, $config);
    }
    else {
      my $connection = $self->get_connection($network);
      $config->{ircname} ||= "";
      if ($config->{ircname} ne $prev{$network}) {
        $connection->update_realname($config->{ircname});
      }
      $connection->config($config);
    }
  }
  for my $connection ($self->connections) {
    if (!$self->config->servers->{$connection->id}) {
      $self->remove_window($_->id) for $self->connection_windows($connection);
      $connection->shutdown;
    }
  }
}

sub send_announcement {
  my ($self, $window, $body) = @_;
  
  my $message = $window->format_announcement($body);
  $self->broadcast($message);
}

sub send_event {
  my ($self, $window, $event, $nick, $body) = @_;

  my $message = $window->format_event($event, $nick, $body);
  $self->broadcast($message);
}

sub send_message {
  my ($self, $window, $nick, $body) = @_;

  my $connection = $self->get_connection($window->network);
  my %options = (
    mono => $self->is_monospace_nick($nick),
    self => $connection->nick eq $nick,
    avatar => $connection->nick_avatar($nick) || "",
    highlight => $self->is_highlight($connection->nick, $body),
  );

  my $message = $window->format_message($nick, $body, %options);
  $self->broadcast($message);
}

sub broadcast {
  my ($self, @messages) = @_;
  return if $self->no_streams or !@messages;
  for my $stream (@{$self->streams}) {
    $stream->send(\@messages);
  }
}

sub ping {
  my $self = shift;
  return if $self->no_streams;
  $_->ping for grep {$_->is_xhr} @{$self->streams};
}

sub update_stream {
  my ($self, $stream, $req) = @_;

  my $min = $req->param('msgid') || 0;
  my $limit = $req->param('limit') || 100;

  $self->log(debug => "sending stream update");

  my @windows = $self->windows;

  if (my $id = $req->param('tab')) {
    if (my $active = $self->get_window($id)) {
      @windows = grep {$_->id ne $id} @windows;
      unshift @windows, $active;
    }
  }

  for my $window (@windows) {
    $self->log(debug => "updating stream from $min for ".$window->title);
    $window->buffer->messages($limit, $min, sub {
      my $msgs = shift;
      return unless @$msgs;
      $stream->send([{
        window => $window->serialized,
        type   => "chunk",
        nicks  => $window->all_nicks,
        html   => join "", map {$_->{html}} @$msgs,
      }]); 
    });
  }
}

sub handle_message {
  my ($self, $message) = @_;

  if (my $window = $self->get_window($message->{source})) {
    $message->{msg} = html_to_irc($message->{msg}) if $message->{html};

    for (split /\n/, $message->{msg}) {
      eval {
        $self->irc_command($window, $_) if length $_;
      };
      if ($@) {
        warn $@;
      }
    }
  }
}

sub send_highlight {
  my ($self, $nick, $body, $source) = @_;
  my $message = $self->info_window->format_message($nick, $body, self => 1, source => $source);
  $self->broadcast($message);
}

sub purge_disconnects {
  my ($self) = @_;
  $self->log(debug => "removing broken streams");
  $self->streams([grep {!$_->closed} @{$self->streams}]);
}

sub is_highlight {
  my ($self, $own_nick, $body) = @_;
  $body = filter_colors $body;
  any {$body =~ /(?:\W|^)\Q$_\E(?:\W|$)/i }
      (@{$self->config->highlights}, $own_nick);
}

sub is_monospace_nick {
  my ($self, $nick) = @_;
  any {$_ eq $nick} @{$self->config->monospace_nicks};
}

sub is_ignore {
  my ($self, $nick) = @_;
  any {$_ eq $nick} $self->config->ignores;
}

sub add_ignore {
  my ($self, $nick) = @_;
  $self->config->add_ignore($nick);
  $self->config->write;
}

sub remove_ignore {
  my ($self, $nick) = @_;
  $self->config->ignore([ grep {$nick ne $_} $self->config->ignores ]);
  $self->config->write;
}

sub ignores {
  my $self = shift;
  return $self->config->ignores;
}

sub static_url {
  my ($self, $file) = @_;
  return $self->config->static_prefix . $file;
}

sub auth_enabled {
  my $self = shift;

  # cache it
  if (!defined $self->{_auth_enabled}) {
    $self->{_auth_enabled} = ($self->config->auth
              and ref $self->config->auth eq 'HASH'
              and $self->config->auth->{user}
              and $self->config->auth->{pass});
  }

  return $self->{_auth_enabled};
}

sub authenticate {
  my ($self, $user, $pass) = @_;
  $user ||= "";
  $pass ||= "";
  if ($self->auth_enabled) {
    return ($self->config->auth->{user} eq $user
       and $self->config->auth->{pass} eq $pass);
  }
  return 1;
}

sub set_away {
  my ($self, $message) = @_;
  my @args = (defined $message ? (AWAY => $message) : "AWAY");
  $_->send_srv(@args) for $self->open_connections;
}

sub tabsets {
  my $self = shift;
  map {
    Alice::Tabset->new(
      name => $_,
      windows => $self->config->tabsets->{$_},
    );
  } sort keys %{$self->config->tabsets};
}

sub connection_windows {
  my ($self, $conn) = @_;
  grep {$_->network eq $conn->id} $self->windows;
}

sub assetdir {$ASSETDIR}

__PACKAGE__->meta->make_immutable;
1;
