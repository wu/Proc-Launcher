#!/perl
use strict;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 4;

my ($fh, $file) = tmpnam();
close $fh;
unlink $file;

my $start_method = sub { sleep 60 };

my $launcher = Proc::Launcher->new( start_method => $start_method,
                                    daemon_name  => 'test',
                                    pid_file     => $file,
                                );

ok( ! $launcher->is_running(),
    "Checking that test process is not already running"
);

ok( ! $launcher->remove_pidfile(),
    "Checking that remove_pidfile does nothing since process is not running"
);

ok( $launcher->start(),
    "Trying to start a disabled process should not work"
);

sleep 2;

ok( $launcher->is_running(),
    "Checking that disabled process was not started"
);

# shut down the test launcher in case this test case is broken and the
# launcher is still running.
$launcher->force_stop();

