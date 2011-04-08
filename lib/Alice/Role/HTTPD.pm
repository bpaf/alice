package Alice::Role::HTTPD;

use AnyEvent;

use Twiggy::Server;
use Plack::Builder;
use Plack::Middleware::Static;
use Plack::Session::Store::File;
use Plack::Session::State::Cookie;

use Alice::HTTP::Request;
use Alice::Stream;

use Encode;
use Any::Moose 'Role';

has httpd => (
  is  => 'rw',
  lazy => 1,
  builder => "_build_httpd",
);

sub _build_httpd {
  my $self = shift;
  my $httpd;

  # eval in case server can't bind port
  eval {
    $httpd = Twiggy::Server->new(
      host => $self->config->http_address,
      port => $self->config->http_port,
    );
    $httpd->register_service(
      builder {
        if ($self->auth_enabled) {
          my $session = $self->config->path."/sessions";
          mkdir $session unless -d $session;
          enable "Session",
            store => Plack::Session::Store::File->new(dir => $session),
            state => Plack::Session::State::Cookie->new(expires => 60 * 60 * 24 * 7);
        }
        enable "Static", path => qr{^/static/}, root => $self->assetdir;
        enable "WebSocket";
        sub {
          my $env = shift;
          return sub {
            eval { $self->dispatch($env, shift) };
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
  my ($self, $env, $cb) = @_;

  my $req = Alice::HTTP::Request->new($env, $cb);
  my $res = $req->new_response(200);

  if ($self->auth_enabled) {
    unless ($req->path eq "/login" or $self->is_logged_in($req)) {
      $self->auth_failed($req, $res);
      return;
    }
  }

  return $self->http_request($req, $res);
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

1;
