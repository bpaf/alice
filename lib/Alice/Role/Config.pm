package Alice::Role::Config;

use Any::Moose 'Role';

use FindBin;
use Data::Dumper;
use Getopt::Long;
use POSIX;
use AnyEvent::AIO;
use IO::AIO;
use List::MoreUtils qw/any/;
use AnyEvent::IRC::Util qw/filter_colors/;

has [qw/images avatars alerts/] => (
  is      => 'rw',
  isa     => 'Str',
  default => "show",
);

has first_run => (
  is      => 'rw',
  isa     => 'Bool',
  default => 1,
);

has style => (
  is      => 'rw',
  isa     => 'Str',
  default => 'default',
);

has timeformat => (
  is      => 'rw',
  isa     => 'Str',
  default => '24',
);

has quitmsg => (
  is      => 'rw',
  isa     => 'Str',
  default => 'alice.',
);

has debug => (
  is      => 'rw',
  isa     => 'Bool',
  default => 0,
);

has port => (
  is      => 'rw',
  isa     => 'Str',
  default => "8080",
);

has address => (
  is      => 'rw',
  isa     => 'Str',
  default => '127.0.0.1',
);

has auth => (
  is      => 'rw',
  isa     => 'HashRef[Str]',
  default => sub {{}},
);

has tabsets => (
  is      => 'rw',
  isa     => 'HashRef[ArrayRef]',
  default => sub {{}},
);

has [qw/ignore highlights order monospace_nicks/]=> (
  is      => 'rw',
  isa     => 'ArrayRef[Str]',
  default => sub {[]},
);

has servers => (
  is      => 'rw',
  isa     => 'HashRef[HashRef]',
  default => sub {{}},
);

has configdir => (
  is      => 'ro',
  isa     => 'Str',
  default => "$ENV{HOME}/.alice",
);

has configfile => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub {$_[0]->configdir ."/config"},
);

has commandline => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub {{}},
);

has static_prefix => (
  is      => 'rw',
  isa     => 'Str',
  default => '/static/',
);

has image_prefix => (
  is      => 'rw',
  isa     => 'Str',
  default => 'https://static.usealice.org/i/',
);

has enable_logging => (
  is      => 'rw',
  isa     => 'Bool',
  default => 1,
);

sub loadconfig {
  my $self = shift;
  my $config = {};

  mkdir $self->configdir unless -d $self->configdir;

  my $loaded = sub {
    $self->read_commandline_args;
    $self->mergeconfig($config);

    $self->init;
  };

  if (-e $self->configfile) {
    my $body;
    aio_load $self->configfile, $body, sub {
      $config = eval $body;
      if ($@) {
        warn "error loading config: $@\n";
      }
      $loaded->();
    }
  }
  else {
    say STDERR "No config found, writing a few config to ".$self->configfile;
    $self->writeconfig($loaded);
  }
}

sub read_commandline_args {
  my $self = shift;
  my ($port, $debug, $address, $nologs);
  GetOptions("port=i" => \$port, "debug" => \$debug, "address=s" => \$address, "disable-logging" => \$nologs);
  $self->commandline->{port} = $port if $port and $port =~ /\d+/;
  $self->commandline->{debug} = 1 if $debug;
  $self->commandline->{address} = $address if $address;
  $self->commandline->{disable_logging} = 1 if $nologs;
}

sub logging {
  my $self = shift;
  if ($self->commandline->{disable_logging}) {
    return 0;
  }
  return $self->enable_logging;
}

sub http_port {
  my $self = shift;
  if ($self->commandline->{port}) {
    return $self->commandline->{port};
  }
  return $self->port;
}

sub http_address {
  my $self = shift;
  if ($self->commandline->{address}) {
    return $self->commandline->{address};
  }
  if ($self->address eq "localhost") {
    $self->address("127.0.0.1");
  }
  return $self->address;
}

sub show_debug {
  my $self = shift;
  if ($self->commandline->{debug}) {
    return 1;
  }
  return $self->debug;
}

sub mergeconfig {
  my ($self, $config) = @_;
  for my $key (keys %$config) {
    if (exists $config->{$key} and my $attr = __PACKAGE__->meta->get_attribute($key)) {
      $self->$key($config->{$key}) if $attr->{is} eq "rw";
    }
    else {
      say STDERR "$key is not a valid config option";
    }
  }
}

sub writeconfig {
  my $self = shift;
  my $callback = pop;
  mkdir $self->configdir if !-d $self->configdir;
  aio_open $self->configfile, POSIX::O_CREAT | POSIX::O_WRONLY | POSIX::O_TRUNC, 0644, sub {
    my $fh = shift;
    if ($fh) {
      local $Data::Dumper::Terse = 1;
      local $Data::Dumper::Indent = 1;
      my $config = Dumper $self->serialized;
      aio_write $fh, 0, length $config, $config, 0, sub {
        $callback->() if $callback;
      };
    }
    else {
      warn "Can not write config file: $!\n";
    }
  }
}

sub serialized {
  my $self = shift;
  my $meta = __PACKAGE__->meta;
      use Data::Dumper;
  return {
    map  {$_ => $self->$_}
    grep {$meta->get_attribute($_)->{is} eq "rw"}
    $meta->get_attribute_list
  };
}

sub auth_enabled {
  my $self = shift;

  $self->auth
    and ref $self->auth eq 'HASH'
    and $self->auth->{user}
    and $self->auth->{pass};
}

sub authenticate {
  my ($self, $user, $pass) = @_;
  $user ||= "";
  $pass ||= "";
  if ($self->auth_enabled) {
    return ($self->auth->{user} eq $user
       and $self->auth->{pass} eq $pass);
  }
  return 1;
}

sub is_highlight {
  my ($self, $own_nick, $body) = @_;
  $body = filter_colors $body;
  any {$body =~ /(?:\W|^)\Q$_\E(?:\W|$)/i }
      (@{$self->highlights}, $own_nick);
}

sub is_monospace_nick {
  my ($self, $nick) = @_;
  any {$_ eq $nick} @{$self->monospace_nicks};
}

sub ignores {@{$_[0]->ignore}}

sub is_ignore {
  my ($self, $nick) = @_;
  any {$_ eq $nick} $self->ignores;
}

sub add_ignore {
  my ($self, $nick) = @_;
  push @{$self->ignore}, $nick;
  $self->writeconfig;
}

sub remove_ignore {
  my ($self, $nick) = @_;
  $self->ignore([ grep {$nick ne $_} $self->ignores ]);
  $self->writeconfig;
}

sub static_url {
  my ($self, $file) = @_;
  return $self->static_prefix . $file;
}

1;
