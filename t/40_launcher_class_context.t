#!/perl
use strict;

package main;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 4;

use lib "t/lib";

my ($fh, $file) = tmpnam();
close $fh;
unlink $file;

my $context = { sleep => 5 };

my $launcher = Proc::Launcher->new( class        => 'TestApp',
                                    start_method => 'runme',
                                    daemon_name  => 'test',
                                    pid_file     => $file,
                                    context      => $context,
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

sleep 8;

ok( ! $launcher->is_running(),
    "Checking that process was started successfully"
);

