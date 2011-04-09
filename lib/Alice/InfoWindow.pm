package Alice::InfoWindow;

use Any::Moose;
use Encode;
use IRC::Formatting::HTML qw/irc_to_html/;
use Text::MicroTemplate qw/encoded_string/;

extends 'Alice::Window';

has '+network' => (required => 0, default => '');
has '+title' => (required => 0, default => 'info');
has 'topic' => (is => 'ro', isa => 'HashRef', default => sub {{string => ''}});
has '+type' => (is => 'ro', default => "info");

#
# DO NOT override the 'id' property, it is built in App/Alice.pm
# using the user-id, which is important for multiuser systems.
#

sub is_channel {0}
sub all_nicks {[]}

sub format_message {
  my ($self, $from, $body, %options) = @_;

  my $html = irc_to_html($body, classes => 1);

  my $message = {
    type   => "message",
    event  => "say",
    nick   => $from,
    window => $self->serialized,
    ($options{source} ? (source => $options{source}) : ()),
    self   => $options{self} ? 1 : 0,
    hightlight  => $options{highlight} ? 1 : 0,
    msgid       => $self->next_msgid,
    timestamp   => time,
    monospaced  => $options{mono} ? 1 : 0,
    consecutive => $from eq $self->previous_nick ? 1 : 0,
  };

  $message->{html} = $self->render("message", $message, encoded_string($html));

  $self->add_message($message);
  return $message;
}

sub hashtag {
  my $self = shift;
  return "/info";
}

__PACKAGE__->meta->make_immutable;
1;
