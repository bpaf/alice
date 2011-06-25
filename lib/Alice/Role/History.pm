package Alice::Role::History;

use Any::Moose 'Role';
use AnyEvent::AIO;
use POSIX;
use IO::AIO;
use File::Path qw/make_path/;

with 'Alice::Role::Assetdir';

sub log_message {
  my ($self, $nick, $body) = @_;
  
  my $line = "<$nick> $body";
  $self->add_line($line);
}

sub log_event {
  my ($self, $body) = @_;

  my $line = "-!- $body";
  $self->add_line($line);
}

sub timestamp {
  my ($sec, $min, $hour) = localtime(time);
  my $time = sprintf("%02d:%02d", $hour, $min);
}

sub get_logfile {
  my ($self) = @_;

  my @date = localtime(time);

  if (!$self->{_last_day} or $self->{_last_day} != $date[3]) {
    $self->rotate_log(@date);
  }

  return $self->{_last_file};
}

sub rotate_log {
  my ($self, @date) = @_;

  $self->close_log;

  my ($sec, $min, $hour, $day, $mon, $year) = @date;
  $year += 1900;

  my $dir = $self->logdir."/".$self->network."/".$self->title."/$year/";
  my $file = sprintf("%s/%s-%04d-%02d-%02d.txt", $dir, $self->title, $year, $mon, $day);

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
  my ($self, $line) = @_;

  my $file = $self->get_logfile;
  push @{$file->{lines}}, $self->timestamp." $line\n";

  if (!$file->{timer}) {
    $file->{timer} = AE::timer 0, 5, sub {$self->_write_buffer($file)};
  }
}

sub _write_buffer {
  my ($self, $file) = @_;

  delete $file->{timer};
  my $lines = delete $file->{lines};
  $file->{lines} = [];

  if (my $fh = $file->{fh}) {
    $self->_write($fh, $lines);
  }
  else {
    aio_open $file->{path}, POSIX::O_CREAT | POSIX::O_WRONLY | POSIX::O_APPEND, 0644, sub {
      my $fh = shift;
      if ($fh) {
        $file->{fh} = $fh;
        $self->_write($fh, $lines);
      }
      else {
        warn "$!\n";
      }
    }
  }
}

sub _write {
  my ($self, $fh, $lines, $cb) = @_;

  $cb ||= sub {};
  my $chunk = join "", @$lines;

  aio_write $fh, undef, length $chunk, $chunk, 0, $cb;
}

sub close_log {
  my ($self, $cb) = @_;
  if (my $file = $self->{_last_file}) {
    delete $file->{timer};
    unshift @{$file->{lines}}, "-- Log closed ".localtime()."\n"; 
    $self->_write($file->{fh}, $file->{lines}, $cb);
  }
  else {
    $cb->() if $cb;
  }
}

around 'close' => sub {
  my ($orig, $self, $cv) = @_;

  $cv->begin;
  $self->close_log(sub {$cv->end});

  $self->$orig($cv);
};

1;
