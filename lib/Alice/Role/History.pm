package Alice::Role::History;

use Any::Moose 'Role';
use AnyEvent::AIO;
use IO::AIO;
use File::Path qw/make_path/;

sub remember_message {
  my ($self, $window, $nick, $body) = @_;
  
  my $line = "<$nick> $body";
  $self->add_line($window, $line);
}

sub remember_event {
  my ($self, $window, $body) = @_;

  my $line = "-!- $body";
  $self->add_line($window, $line);
}

sub timestamp {
  my ($sec, $min, $hour) = localtime(time);
  my $time = sprintf("%02d:%02d", $hour, $min);
}

sub get_logfile {
  my ($self, $window) = @_;

  my @date = localtime(time);

  if (!$self->{_last_day} or $self->{_last_day} != $date[3]) {
    $self->rotate_log($window, @date);
  }

  return $self->{_last_file};
}

sub rotate_log {
  my ($self, $window, @date) = @_;

  $self->close_log;

  my ($sec, $min, $hour, $day, $mon, $year) = @date;
  $year += 1900;

  my $dir = $self->logdir."/".$window->network."/".$window->title."/$year/";
  my $file = sprintf("%s/%s-%04d-%02d-%02d.txt", $dir, $window->title, $year, $mon, $day);

  make_path($dir) unless -e $dir;

  $self->{_last_day} = $day;
  $self->{_last_file} = {
    lines => ["-- Log opened ".localtime()."\n"],
    fh => undef,
    timer => undef,
    path => $file
  };
}

sub add_line {
  my ($self, $window, $line) = @_;

  my $file = $self->get_logfile($window);
  push @{$file->{lines}}, $self->timestamp." $line\n";

  if (!$file->{timer}) {
    $file->{timer} = AE::timer 0, 5, sub {$self->_write_buffer($file)};
  }
}

sub _write_buffer {
  my ($self, $file) = @_;

  my $lines = delete $file->{lines};
  $file->{lines} = [];

  if (my $fh = $file->{fh}) {
    $self->_write($fh, $lines);
  }
  else {
    $self->cv->begin;
    aio_open $file->{path}, POSIX::O_CREAT | POSIX::O_WRONLY | POSIX::O_APPEND, 0644, sub {
      my $fh = shift;
      if ($fh) {
        $file->{fh} = $fh;
        $self->_write($fh, $lines);
        $self->cv->end;
      }
      else {
        warn "$!\n";
      }
    }
  }
}

sub _write {
  my ($self, $fh, $lines) = @_;

  my $chunk = join "", @$lines;

  $self->cv->begin;
  aio_write $fh, undef, length $chunk, $chunk, 0, sub {$self->cv->end};
}

sub close_log {
  my ($self, $file) = @_;
  if (my $file = $self->{_last_file}) {
    delete $file->{timer};
    unshift @{$file->{lines}}, "-- Log closed ".localtime()."\n"; 
    $self->_write($file->{fh}, $file->{lines});
  }
}

before shutdown => sub {
  my $self = shift;
  $self->close_log;
};

1;
