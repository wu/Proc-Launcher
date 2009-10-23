#!/perl
use strict;

package Test::MyApp;
use Mouse;

sub runme {
    sleep 600;
}

no Mouse;

package main;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 5;

my ($fh, $file) = tmpnam();
close $fh;
unlink $file;


my $launcher = Proc::Launcher->new( class        => 'Test::MyApp',
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

sleep 1;

ok( $launcher->is_running(),
    "Checking that process was started successfully"
);

ok( $launcher->stop(),
    "Calling 'stop' method"
);

sleep 1;

ok( ! $launcher->is_running(),
    "Checking that 'stop' successfully shut down the process"
);

