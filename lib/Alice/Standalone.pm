package Alice::Standalone;

use Any::Moose;
use AnyEvent;

extends 'Alice';

has cv => (
  is       => 'rw',
  isa      => 'AnyEvent::CondVar'
);

with 'Alice::Role::HTTPD';

after run => sub {
  my $self = shift;

  my @sigs = map {AE::signal $_, sub {$self->init_shutdown}} qw/INT QUIT/;

  $self->cv(AE::cv);
  $self->cv->recv;
};

after init => sub {
  my $self = shift;
  $self->httpd;
  print STDERR "Location: http://".$self->http_address.":".$self->http_port."/\n";
};

before init_shutdown => sub {
  my $self = shift;
  print STDERR ($self->open_connections ? "\nDisconnecting, please wait\n" : "\n");
};

after shutdown => sub {
  my $self = shift;
  $self->cv->send;
};

1;
