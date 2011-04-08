package Alice::HTTPD;

use AnyEvent;

use Twiggy::Server;
use Plack::Builder;
use Plack::Middleware::Static;
use Plack::Session::Store::File;
use Plack::Session::State::Cookie;

use Alice::HTTP::Request;
use Alice::Stream;

use JSON;
use Encode;
use Any::Moose;

has httpd => (
  is  => 'rw',
  lazy => 1,
  builder => "_build_httpd",
);

has address => (
  is => 'ro',
  default => '127.0.0.1',
);

has port => (
  is => 'ro',
  default => 8080,
);

has sessiondir => (
  is => 'ro',
  required => 1,
);

has assetdir => (
  is => 'ro',
  required => 1,
);

sub BUILD {
  my $self = shift;
  $self->httpd;
}

sub _build_httpd {
  my $self = shift;
  my $httpd;

  # eval in case server can't bind port
  eval {
    $httpd = Twiggy::Server->new(
      host => $self->address,
      port => $self->port,
    );
    $httpd->register_service(
      builder {
        if ($self->auth_enabled) {
          mkdir $self->sessiondir unless -d $self->sessiondir;
          enable "Session",
            store => Plack::Session::Store::File->new(dir => $self->sessiondir),
            state => Plack::Session::State::Cookie->new(expires => 60 * 60 * 24 * 7);
        }
        enable "Static", path => qr{^/static/}, root => $self->assetdir;
        enable "WebSocket";
        sub {
          my $env = shift;
          return sub {
            eval { $self->dispatch($Alice::APP, $env, shift) };
            warn $@ if $@;
          }
        }
      }
    );
  };

  warn $@ if $@;
  return $httpd;
}

sub dispatch {
  my ($self, $app, $env, $cb) = @_;

  my $req = Alice::HTTP::Request->new($env, $cb);
  my $res = $req->new_response(200);

  if ($self->auth_enabled) {
    unless ($req->path eq "/login" or $self->is_logged_in($req)) {
      $self->auth_failed($req, $res);
      return;
    }
  }

  return $app->http_request($req, $res);
}

sub auth_failed {
  my ($self, $req, $res) = @_;

  if ($req->path =~ m{^(/(?:safe)?)$}) {
    $res->redirect("/login".($1 ? "?dest=$1" : ""));
    $res->body("bai");
  } else {
    $res->status(401);
    $res->body("unauthorized");
  }
  $res->send;
}

sub is_logged_in {
  my ($self, $req) = @_;
  my $session = $req->env->{"psgix.session"};
  return $session->{is_logged_in};
}

sub shutdown {
  my $self = shift;
  $self->httpd(undef);
}

sub auth_enabled {
  my $self = shift;
  $Alice::APP->auth_enabled;
}

__PACKAGE__->meta->make_immutable;
1;
