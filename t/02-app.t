use Test::More;
use Alice;
use Alice::Test::NullHistory;
use Test::TCP;

my $history = Alice::Test::NullHistory->new;
my $app = Alice->new(
  history => $history,
  path => 't/alice',
  file => "test_config",
  port => empty_port(),
);

$app->add_new_connection("test", {
  nick => "tester",
  host => "not.real.server",
  port => 6667,
  autoconnect => 0,
});

# connections
ok $app->has_connection("test"), "add connection";
my $connection = $app->get_connection("test");
is_deeply [$app->connections], [$connection], "connection list";

# windows
my $info = $app->info_window;
ok $info, "info window";
my $window = $app->create_window("test-window", $connection);
ok $window, "create window";

my $window_id = $app->_build_window_id("test-window", "test");
ok $app->has_window($window_id), "window exists";
ok $app->find_window("test-window", $connection), "find window by name";
ok ref $app->get_window($window_id) eq "Alice::Window", "get window";
is_deeply [$app->sorted_windows], [$info, $window], "window list";

is_deeply $app->find_or_create_window("test-window", $connection), $window, "find or create existing window";
my $window2 = $app->find_or_create_window("test-window2", $connection);
ok $app->find_window("test-window2", $connection), "find or create non-existent window";
$app->remove_window($app->_build_window_id("test-window2", "test"));

$app->close_window($window);
ok !$app->has_window($window_id), "close window";

# ignores
$app->add_ignore("jerk");
ok $app->is_ignore("jerk"), "add ignore";
is_deeply [$app->ignores], ["jerk"], "ignore list";
$app->remove_ignore("jerk");
ok !$app->is_ignore("jerk"), "remove ignore";
is_deeply [$app->ignores], [], "ignore list post remove";

done_testing();
