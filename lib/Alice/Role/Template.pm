package Alice::Role::Template;

use Any::Moose 'Role';

use Text::MicroTemplate::File;
use File::ShareDir qw/dist_dir/;
use Exporter;

our @EXPORT = qw/render/;
our @EXPORT_OK = qw/render/;

our $TEMPLATEDIR = do {
  if (-e  "$FindBin::Bin/../share/templates") {
    "$FindBin::Bin/../share/templates";
  }
  else {
    dist_dir('App-Alice')."/templates";
  }
};

our $TEMPLATE = Text::MicroTemplate::File->new(
  include_path => $TEMPLATEDIR,
  cache        => 2,
);

sub render {
  my ($self, $template, @args) = @_;
  return $TEMPLATE->render_file("$template.html", $self, @args)->as_string;
}

1;
