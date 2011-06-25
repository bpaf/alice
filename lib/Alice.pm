package Alice;

use AnyEvent;
use Any::Moose;

use Alice::Window;
use Alice::InfoWindow;
use Alice::Connection::IRC;

use Digest::MD5 qw/md5_hex/;
use IRC::Formatting::HTML qw/html_to_irc/;
use Encode;

with 'Alice::Role::Assetdir';
with 'Alice::Role::Config';
with 'Alice::Role::Template';
with 'Alice::Role::Events';
with 'Alice::Role::HTTPRoutes';
with 'Alice::Role::IRCCommands';
with 'Alice::Role::Log';

our $VERSION = '0.19';

has _connections => (
  is      => 'rw',
  isa     => 'HashRef',
  default => sub {{}},
);

has cv => (
  is       => 'rw',
  isa      => 'AnyEvent::CondVar',
  default  => sub {AE::cv},
);

has message_store => (
  is      => 'ro',
  default => sub{
    eval "use Alice::MessageStore::Memory;";
    die $@ if $@;
    Alice::MessageStore::Memory->new
  },
);

sub connections {values %{$_[0]->_connections}}
sub add_connection {$_[0]->_connections->{$_[1]->id} = $_[1]}
sub has_connection {$_[0]->get_connection($_[1])}
sub get_connection {$_[0]->_connections->{$_[1]}}
sub remove_connection {delete $_[0]->_connections->{$_[1]->id}}
sub open_connections {grep {$_->is_connected} $_[0]->connections}

has streams => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub {[]},
);

sub add_stream {unshift @{shift->streams}, @_}
sub no_streams {@{$_[0]->streams} == 0}
sub stream_count {scalar @{$_[0]->streams}}

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
      id => $id,
      message_store => $self->message_store
    );
    return $info;
  }
);

has 'user' => (
  is => 'ro',
  default => $ENV{USER}
);

sub run {
  my $self = shift;
  $self->loadconfig;

  if (-e $self->configdir."/init.pl") {
    eval {do $self->configdir."/init.pl"};
    warn "Error running init file: $@\n" if $@;
  }
}

sub init {
  my $self = shift;

  $self->add_window($self->info_window);

  $self->add_new_connection($_, $self->servers->{$_})
    for keys %{$self->servers};
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
  $_->close($self->cv) for $self->windows;
}

sub tab_order {
  my ($self, $window_ids) = @_;
  my $order = [];
  for my $count (0 .. scalar @$window_ids - 1) {
    if (my $window = $self->get_window($window_ids->[$count])) {
      next unless $window->is_channel
           and $self->servers->{$window->network};
      push @$order, $window->id;
    }
  }
  $self->order($order);
  $self->writeconfig;
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
    message_store => $self->message_store,
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

  my %o = map {
    $self->order->[$_] => sprintf "%02d", $_ + 2
  } (0 .. @{$self->order} - 1);

  $o{$self->info_window->id} = "01";
  my $prefix = scalar @{$self->order} + 1;

  map  {$_->[1]}
  sort {$a->[0] cmp $b->[0]}
  map  {[($o{$_->id} || $o{$_->title} || $prefix.$_->sort_name), $_]}
       $self->windows;
}

sub close_window {
  my ($self, $window) = @_;
  $self->broadcast($window->close_action);
  $self->log(debug => "sending a request to close a tab: " . $window->title)
    if $self->stream_count;
  $self->remove_window($window->id) if $window->type ne "info";
  $window->close_logs;
}

sub add_new_connection {
  my ($self, $name, $config) = @_;

  $self->servers->{$name} = $config;
  my $conn = Alice::Connection::IRC->new(config => $config);
  $self->add_connection($conn);
}

sub reload_config {
  my ($self, $new_config) = @_;

  if ($new_config) {
    $self->mergeconfig($new_config);
    $self->writeconfig;
  }
  
  for my $network (keys %{$self->servers}) {
    my $config = $self->servers->{$network};
    if (!$self->has_connection($network)) {
      $self->add_new_connection($network, $config);
    }
    else {
      my $connection = $self->get_connection($network);
      $connection->config($config);
    }
  }
  for my $connection ($self->connections) {
    if (!$self->servers->{$connection->id}) {
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

# special because we need to allow html in part of the body
sub send_topic {
  my ($self, $window) = @_;

  my $message = $window->format_topic;
  $self->broadcast($message);
}

sub send_event {
  my ($self, $window, $body) = @_;

  my $message = $window->format_event($body);
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
    $window->messages($limit, $min, sub {
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
      $self->irc_command($window, $_) if length $_;
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

sub set_away {
  my ($self, $message) = @_;
  my @args = (defined $message ? (AWAY => $message) : "AWAY");
  $_->send_srv(@args) for $self->open_connections;
}

sub connection_windows {
  my ($self, $conn) = @_;
  grep {$_->network eq $conn->id} $self->windows;
}

__PACKAGE__->meta->make_immutable;
1;
