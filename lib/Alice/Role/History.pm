package Alice::Role::History;

use Any::Moose 'Role';
use AnyEvent::AIO;
use IO::AIO;
use File::Path qw/make_path/;

requires 'configdir';

has buffers => (
  is => 'rw',
  default => sub {{}},
);

has fhs => (
  is => 'rw',
  default => sub {{}},
);

has timers => (
  is => 'rw',
  default => sub {{}},
);

sub remember_message {
  my ($self, $window, $nick, $body) = @_;
  
  my ($dir, $file) = $self->logfile($window);
  my $line = $self->timestamp." <$nick> $body";

  $self->_add_line($dir, $file, $line);
}

sub remember_event {
  my ($self, $window, $body) = @_;

  my ($dir, $file) = $self->logfile($window);
  my $line = $self->timestamp." -!- $body";

  $self->_add_line($dir, $file, $line);
}

sub timestamp {
  my ($sec, $min, $hour) = localtime(time);
  my $time = sprintf("%02d:%02d", $hour, $min);
}

sub logfile {
  my ($self, $window) = @_;

  my ($sec, $min, $hour, $day, $mon, $year) = localtime(time);
  $year += 1900;

  my $dir = $self->logdir."/".$window->network."/".$window->title."/$year/";
  my $file = sprintf("%s-%04d-%02d-%02d.txt", $window->title, $year, $mon, $day);

  return ($dir, $file);
}

sub _add_line {
  my ($self, $dir, $file, $line) = @_;

  $file = "$dir/$file";

  $self->buffers->{$file} ||= [];
  my $buffer = $self->buffers->{$file};
  push @{$buffer}, $line;

  make_path($dir) unless -e $dir;

  if (!$self->timers->{$file}) {
    $self->timers->{$file} = AE::timer 0, 5, sub {$self->_write_buffer($file)};
  }
}

sub _write_buffer {
  my ($self, $file) = @_;
  my $output = delete $self->buffers->{$file};

  if (my $fh = $self->fhs->{$file}) {
    $self->_write($fh, $output);
  }
  else {
    aio_open $file, POSIX::O_CREAT | POSIX::O_WRONLY | POSIX::O_APPEND, 0644, sub {
      my $fh = shift;
      if ($fh) {
        $self->fhs->{$file} = $fh;
        unshift @$output, "-- Log opened ".localtime;
        $self->_write($fh, $output);
      }
      else {
        warn "$!\n";
      }
    }
  }
}

sub _write {
  my ($self, $fh, $output, $cb) = @_;

  $cb ||= sub {};

  for my $line (@$output) {
    $line .= "\n";
    aio_write $fh, undef, length $line, $line, 0, $cb;
  }
}

before shutdown => sub {
  my $self = shift;

  for my $file (keys %{$self->fhs}) {
    my $fh = delete $self->fhs->{$file};
    $self->cv->begin;
    $self->_write($fh, ["-- Log closed ".localtime], sub {$self->cv->end});
  }
};

1;
