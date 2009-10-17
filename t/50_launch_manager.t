#!/perl
use strict;

use Proc::Launcher::Manager;

use File::Temp qw/ :POSIX /;
use Test::More tests => 10;
use File::Temp qw(tempdir);

my $tempdir = tempdir('/tmp/proc_launcher_XXXXXX', CLEANUP => 1);

my $monitor = Proc::Launcher::Manager->new( app_name  => 'testapp',
                                            pid_dir   => $tempdir,
                                        );

my @test_daemons = qw( test_1 test_2 test_3 );

for my $daemon_name ( @test_daemons ) {
    ok( $monitor->spawn( daemon_name => $daemon_name, start_method => sub { sleep 600 } ),
        "spawning test daemon: $daemon_name"
    );

    ok( $monitor->daemon($daemon_name)->start(),
        "starting test daemon: $daemon_name"
    );
}

is_deeply( [ $monitor->daemons_names() ],
           [ @test_daemons             ],
           "checking all_daemons()"
       );

sleep 1;

is_deeply( [ $monitor->daemons_running ],
           [ @test_daemons             ],
           "checking all three daemons are now running"
       );

ok( $monitor->stop_all(),
    "Shutting down all daemons"
);

sleep 1;

is_deeply( [ $monitor->daemons_running ],
           [ ],
           "checking all three daemons were successfully shut down"
       );
