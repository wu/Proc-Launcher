#!/perl
use strict;

package Test::MyApp;
use Mouse;

sub runme {
    sleep 1;
}

no Mouse;

package main;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 4;

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

ok( $launcher->is_running(),
    "Checking that process was started successfully"
);

sleep 2;

ok( ! $launcher->is_running(),
    "Checking that process was started successfully"
);

