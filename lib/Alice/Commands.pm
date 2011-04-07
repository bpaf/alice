package Alice::Commands;

use Any::Moose;
use Encode;

has 'handlers' => (
  is => 'rw',
  isa => 'ArrayRef',
  default => sub {[]},
);

has 'commands_file' => (
  is       => 'ro',
  required => 1,
);

sub BUILD {
  my $self = shift;
  $self->reload_handlers;
}

sub reload_handlers {
  my $self = shift;
  if (-e $self->commands_file) {
    my $commands = do $self->commands_file;
    if ($commands and ref $commands eq "ARRAY") {
      $self->handlers($commands);
    }
    else {
      warn "$!\n";
    }
  }
}

sub handle {
  my ($self, $app, $command, $window) = @_;
  for my $handler (@{$self->handlers}) {
    my $re = $handler->{re};
    if ($command =~ /$re/) {
      my @args = grep {defined $_} ($5, $4, $3, $2, $1); # up to 5 captures
      if ($handler->{in_channel} and !$window->is_channel) {
        $window->reply("$command can only be used in a channel");
      }
      else {
        $handler->{code}->($self, $app, $window, @args);
      }
      return;
    }
  }
}

sub determine_connection {
  my ($self, $app, $window, $network) = @_;

  my $connection = $network ? $app->get_connection($network) : $window->connection;

  if (!$connection and $network) {
    $window->reply("$network is not one of your networks");
    return ();
  }
  elsif (!$connection) {
    $window->reply("Network is ambiguous, specify a network name");
    return();
  }
  elsif (!$connection->is_connected) {
    $window->reply($connection->id." is not connected");
    return ();
  }
  
  return $connection;
}

__PACKAGE__->meta->make_immutable;
1;
