#!/perl
use strict;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 5;

use lib "t/lib";

my ($fh, $file) = tmpnam();
close $fh;
unlink $file;

my $launcher = Proc::Launcher->new( class        => 'TestApp',
                                    start_method => 'runme',
                                    daemon_name  => 'test',
                                    pid_file     => $file,
                                );

ok( ! $launcher->is_running(),
    "Checking that test process is not already running"
);

ok( $launcher->start(),
    "Starting the test process"
);

sleep 2;

ok( $launcher->is_running(),
    "Checking that process was started successfully"
);

ok( $launcher->stop(),
    "Calling 'stop' method"
);

sleep 2;

ok( ! $launcher->is_running(),
    "Checking that 'stop' successfully shut down the process"
);

