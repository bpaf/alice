package Alice::Standalone;

use Any::Moose;
use AnyEvent;
use Alice::HTTPD;

extends 'Alice';

has cv => (
  is       => 'rw',
  isa      => 'AnyEvent::CondVar'
);

has httpd => (
  is      => 'rw',
  isa     => 'Alice::HTTPD',
  lazy    => 1,
  default => sub {
    my $self = shift;
    Alice::HTTPD->new(
      address => $self->config->http_address,
      port => $self->config->http_port,
      assetdir => $self->assetdir,
      sessiondir => $self->config->path."/sessions",
    );
  },
);

after run => sub {
  my $self = shift;

  $Alice::APP = $self;
  my @sigs = map {AE::signal $_, sub {$self->init_shutdown}} qw/INT QUIT/;

  $self->cv(AE::cv);
  $self->cv->recv;
};

after init => sub {
  my $self = shift;
  $self->httpd;
  print STDERR "Location: http://".$self->config->http_address.":".$self->config->http_port."/\n";
};

before init_shutdown => sub {
  my $self = shift;
  print STDERR ($self->open_connections ? "\nDisconnecting, please wait\n" : "\n");
};

after shutdown => sub {
  my $self = shift;
  $self->httpd->shutdown;
  $self->cv->send;
};

1;
