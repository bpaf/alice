package Alice::Role::HTTPD::Twiggy;

use Twiggy::Server;
use Any::Moose 'Role';

with 'Alice::Role::HTTPD';

sub build_httpd {
  my $self = shift;

  Twiggy::Server->new(
    host => $self->http_address,
    port => $self->http_port,
  );
}

sub register_app {
  my ($self, $app) = @_;
  $self->httpd->register_service($app);
}

1;
