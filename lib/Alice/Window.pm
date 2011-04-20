package Alice::Window;

use Any::Moose;
use AnyEvent;

use Text::MicroTemplate qw/encoded_string/;
use IRC::Formatting::HTML qw/irc_to_html/;
use Encode;

with 'Alice::Role::Template';
with 'Alice::Role::History';

my $url_regex = qr/\b(https?:\/\/(?:[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'".,<>?«»“”‘’]))/i;

has title => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has topic => (
  is      => 'rw',
  isa     => 'HashRef[Str|Undef]',
  default => sub {{
    string => '',
    author => '',
    time   => time,
  }}
);

has id => (
  is       => 'ro',
  required => 1,
);

has disabled => (
  is       => 'rw',
  isa      => 'Bool',
  default  => 0,
);

has nicks => (
  is => 'rw',
  default => sub {[]},
);

has network => (
  is => 'ro',
  required => 1
);

has message_store => (
  is => 'ro',
  required => 1,
);

has previous_nick => (
  is => 'rw',
  default => "",
);

sub sort_name {
  my $name = lc $_[0]->title;
  $name =~ s/^[^\w\d]+//;
  $name;
}

sub pretty_name {
  my $self = shift;
  if ($self->is_channel) {
    return substr $self->title, 1;
  }
  return $self->title;
}

has type => (
  is => 'ro',
  lazy => 1,
  default => sub {
    $_[0]->title =~ /^#|&/ ? "channel" : "privmsg";
  },
);

sub is_channel {$_[0]->type eq "channel"}

sub topic_string {
  my $self = shift;
  if ($self->is_channel) {
    return $self->topic->{string} || "no topic set";
  }
  return $self->title;
}

sub set_topic {
  my ($self, $body, $nick) = @_;

  $self->topic({
    string => $body || "",
    author => $nick || "",
    'time' => time,
  });
}

sub serialized {
  my ($self) = @_;
  return {
    id         => $self->id, 
    network    => $self->network,
    title      => $self->title,
    is_channel => $self->is_channel,
    type       => $self->type,
    hashtag    => $self->hashtag,
    topic      => $self->topic_string,
  };
}

sub all_nicks {
  my ($self, $modes) = @_;
  return $self->is_channel ? $self->nicks : [ $self->title ];
}

sub connect_action {
  my $self = shift;
  return {
    type => "action",
    event => "connect",
    network => $self->network,
    windows => [$self->serialized],
  };
}

sub disconnect_action {
  my $self = shift;
  return {
    type => "action",
    event => "disconnect",
    network => $self->network,
    windows => [$self->serialized],
  };
}

sub join_action {
  my $self = shift;
  return {
    type      => "action",
    event     => "join",
    nicks     => $self->all_nicks,
    window    => $self->serialized,
    html => {
      window  => $self->render("window"),
      tab     => $self->render("tab"),
    },
  };
}

sub nicks_action {
  my $self = shift;
  return {
    type   => "action",
    event  => "nicks",
    nicks  => $self->all_nicks,
    window => $self->serialized,
  };
}

sub clear_action {
  my $self = shift;
  return {
    type   => "action",
    event  => "clear",
    window => $self->serialized,
  };
}

sub format_event {
  my ($self, $body) = @_;
  my $message = {
    type      => "event",
    window    => $self->serialized,
    body      => $body,
    msgid     => $self->next_msgid,
    timestamp => time,
    nicks     => $self->all_nicks,
  };

  my $html = $self->render("event", $message);
  $message->{html} = $html;

  $self->add_message($message);
  $self->log_event($body);

  return $message;
}

sub format_topic {
  my $self = shift;

  my $message = {
    type      => "event",
    window    => $self->serialized,
    msgid     => $self->next_msgid,
    body      => irc_to_html($self->topic_string),
    nick      => $self->topic->{author} || "",
    timestamp => time,
    nicks     => $self->all_nicks,
  };

  my $html = $self->render("topic", $message);
  $message->{html} = $html;

  $self->add_message($message);

  $self->log_event("Topic changed to \"".$self->topic_string
                  .($self->topic->{author} ? "\" by ".$self->topic->{author} : ""));

  return $message;
}

sub format_message {
  my ($self, $nick, $body, %opts) = @_;

  # pass the inverse => italic option if this is NOT monospace
  my $html = irc_to_html($body, classes => 1, ($opts{mono} ? () : (invert => "italic")));

  my $message = {
    type      => "message",
    nick      => $nick,
    avatar    => $opts{avatar} || "",
    window    => $self->serialized,
    self      => $opts{self},
    msgid     => $self->next_msgid,
    timestamp => time,
    monospaced => $opts{mono},
    consecutive => $nick eq $self->previous_nick,
  };

  $message->{html} = $self->render("message", $message, encoded_string($html));
  $self->add_message($message);
  $self->log_message($nick, $body);

  return $message;
}

sub format_announcement {
  my ($self, $msg) = @_;
  my $message = {
    type    => "message",
    event   => "announce",
    window  => $self->serialized,
    message => $msg,
  };
  $message->{html} = $self->render('announcement', $message);
  $message->{message} = "$message->{message}";
  $self->reset_previous_nick;
  return $message;
}

sub close_action {
  my $self = shift;
  my $action = {
    type   => "action",
    event  => "part",
    window => $self->serialized,
  };
  return $action;
}

sub nick_table {
  my $self = shift;
  return _format_nick_table($self->all_nicks);
}

sub _format_nick_table {
  my $nicks = shift;
  return "" unless @$nicks;
  my $maxlen = 0;
  for (@$nicks) {
    my $length = length $_;
    $maxlen = $length if $length > $maxlen;
  }
  my $cols = int(74  / $maxlen + 2);
  my (@rows, @row);
  for (sort {lc $a cmp lc $b} @$nicks) {
    push @row, $_ . " " x ($maxlen - length $_);
    if (@row >= $cols) {
      push @rows, [@row];
      @row = ();
    }
  }
  push @rows, [@row] if @row;
  return join "\n", map {join " ", @$_} @rows;
}

sub reset_previous_nick {
  my $self = shift;
  $self->previous_nick("");
}

sub previous_nick {
  my $self = shift;
  return $self->previous_nick;
}

sub hashtag {
  my $self = shift;

  my $name = $self->title;
  $name =~ s/[#&~@]//g;
  my $path = $self->type eq "privmsg" ? "users" : "channels";
  
  return "/" . $self->network . "/$path/" . $name;
}

sub msgid {
  my $self = shift;
  return $self->message_store->msgid;
}

sub next_msgid {
  my $self = shift;
  $self->message_store->next_msgid;
}

sub clear {
  my $self = shift;
  $self->previous_nick("");
  $self->message_store->clear($self->id);
}

sub add_message {
  my ($self, $message) = @_;
  $message->{type} eq "message" ? $self->previous_nick($message->{nick})
                                : $self->previous_nick("");

  $self->message_store->add_message($self->id, $message);
}

sub messages {
  my ($self, $limit, $min, $cb) = @_;

  my $msgid = $self->message_store->msgid;

  $min = 0 unless $min > 0;
  $min = $msgid if $min > $msgid;

  $limit = $msgid - $min if $min + $limit > $msgid;
  $limit = 0 if $limit < 0;

  return $self->message_store->messages($self->id, $limit, $min, $cb);
}

sub close {
  my ($self, $cv) = @_;
}

__PACKAGE__->meta->make_immutable;
1;
