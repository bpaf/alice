package Alice::Role::Log;

use Any::Moose 'Role';

sub log {
  my ($self, $level, $message, %options) = @_;

  if ($level eq "info") {
    my $from = delete $options{from} || "config";
    my $line = $self->info_window->format_message($from, $message, %options);
    $self->broadcast($line);
  }

  if ($self->show_debug) {
    my ($sec, $min, $hour, $day, $mon, $year) = localtime(time);
    my $datestring = sprintf "%02d:%02d:%02d %02d/%02d/%02d",
                     $hour, $min, $sec, $mon, $day, $year % 100;
    print STDERR substr($level, 0, 1) . ", [$datestring] "
               . sprintf("% 5s", $level) . " -- : $message\n";
  }
}

1;
