use Test::More;
use Alice;
use Alice::Test::MockIRC;
use Alice::Test::NullHistory;
use Test::TCP;

my $history = Alice::Test::NullHistory->new;
my $app = Alice->new(
  history => $history,
  path => 't/alice',
  file => "test_config",
  port => empty_port(),
);

my $cl = Alice::Test::MockIRC->new(nick => "tester");
$app->config->servers->{"test"} = {
  host => "not.real.server",
  port => 6667,
  autoconnect => 1,
  channels => ["#test"],
  on_connect => ["JOIN #test2"],
};

my $connection = Alice::Connection::IRC->new(
  id => "test",
  cl => $cl,
);
$app->add_connection("test", $connection);

# joining channels
ok $connection->is_connected, "connect";
ok my $window = $app->find_window("#test", $connection), "auto-join channel";
ok $app->find_window("#test2", $connection), "on_connect join command";

# nicks
is $connection->nick, "tester", "nick set";
ok $connection->includes_nick("test"), "existing nick in channel";
is_deeply $connection->get_nick_info("test")->[2], ['#test'], "existing nick info set";

$cl->send_cl(":nick!user\@host JOIN #test");
ok $connection->includes_nick("nick"), "nick added after join";
is_deeply $connection->get_nick_info("nick")->[2], ['#test'], "new nick info set";

$cl->send_cl(":nick!user\@host NICK nick2");
ok $connection->includes_nick("nick2"), "nick change";
ok !$connection->includes_nick("nick"), "old nick removed after nick change";

$cl->send_cl(":nick!user\@host PART #test");
ok !$connection->includes_nick("nick"), "nick gone after part";

# topic
is $window->topic->{string}, "no topic set", "default initial topic";

$cl->send_srv(TOPIC => "#test", "updated topic");
is $window->topic->{string}, "updated topic", "self topic change string";
is $window->topic->{author}, "tester", "self topic change author";

$cl->send_cl(":nick!user\@host TOPIC #test :another topic update");
is $window->topic->{string}, "another topic update", "external topic change string";
is $window->topic->{author}, "nick", "external topic change author";

# part channel
$cl->send_srv(PART => "#test");
ok !$app->find_window("#test", $connection), "part removes window";

# messages
$cl->send_cl(":nick!user\@host PRIVMSG tester :hi");
ok $app->find_window("nick", $connection), "private message";

$cl->send_cl(":nick!user\@host PRIVMSG #test3 :hi");
ok !$app->find_window("#test3", $connection), "msg to unjoined channel doesn't create window";

# disconnect
$cl->disconnect;
ok !$connection->is_connected, "disconnect";

undef $app;
undef $cl;

done_testing();
