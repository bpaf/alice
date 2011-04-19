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

has timers => (
  is => 'rw',
  default => sub {{}},
);

sub remember_message {
  my ($self, $window, $nick, $body) = @_;
  
  my ($sec, $min, $hour, $day, $mon, $year) = localtime(time);
  $year += 1900;

  my $dir = $self->logdir."/".$window->network."/".$window->title."/$year/";
  my $file = "$mon-$day.txt";

  my $line = "$hour:$min <$nick> $body";
  $self->_add_line($dir, $file, $line);
}

sub remember_event {
  my ($self, $window, $body) = @_;

  my ($sec, $min, $hour, $day, $mon, $year) = localtime(time);
  $year += 1900;

  my $dir = $self->logdir."/".$window->network."/".$window->title."/$year/";
  my $file = "$mon-$day.txt";

  my $line = "$hour:$min $body";
  $self->_add_line($dir, $file, $line);
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
  aio_open $file, POSIX::O_CREAT | POSIX::O_WRONLY | POSIX::O_APPEND, 0644, sub {
    my $fh = shift;
    if ($fh) {
      for my $line (@$output) {
        $line .= "\n";
        aio_write $fh, undef, length $line, $line, 0, sub {};
      }
    }
    else {
      warn $!;
    }
  }
}

1;
