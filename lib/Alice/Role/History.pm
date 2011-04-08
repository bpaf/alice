package Alice::Role::History;

use Any::Moose 'Role';

use AnyEvent::DBI;
use AnyEvent::IRC::Util qw/filter_colors/;
use SQL::Abstract;
use File::Copy;

has dbi => (
  is => 'ro',
  isa => 'AnyEvent::DBI',
  lazy => 1,
  default => sub {
    my $self = shift;
    AnyEvent::DBI->new("DBI:SQLite:dbname=".$self->dbfile,"","");
  }
);

has sql => (
  is => 'ro',
  isa => 'SQL::Abstract',
  default => sub {SQL::Abstract->new(cmp => "like")},
);

has dbfile => (
  is => 'ro',
  isa => 'Str',
  lazy => 1,
  default => sub {
    my $self = shift;
    return $self->config->path."/log.db";
  }
);

before init => sub {
  my $self = shift;
  copy($self->assetdir."/log.db", $self->dbfile) unless -e $self->dbfile;
};

sub store {
  my ($self, %fields) = @_;
  return unless $self->config->logging;

  $fields{user} = $self->user;
  $fields{'time'} = time;
  my ($stmt, @bind) = $self->sql->insert("messages", \%fields);
  $self->dbi->exec($stmt, @bind, sub {});
}

1;
