#!/perl
use strict;

use Proc::Launcher;

use File::Temp qw/ :POSIX /;
use Test::More tests => 8;

# ignore kill signal (this is what makes us stubborn)
$SIG{HUP}  = 'IGNORE';



my ($fh, $file) = tmpnam();
close $fh;
unlink $file;

my $launcher = Proc::Launcher->new( start_method => sub { exec 'sleep 60' },
                                    daemon_name  => 'test-exec',
                                    pid_file     => $file,
                                );

ok( ! $launcher->is_running(),
    "Checking that test process is not already running"
);

ok( ! $launcher->read_pid(),
    "Checking that pid file is empty"
);

ok( $launcher->start(),
    "Starting the test process"
);

ok( $launcher->is_running(),
    "Checking that process was started successfully"
);

sleep 1;

ok( $launcher->read_pid(),
    "Checking that pid file is not empty"
);

ok( ! $launcher->start(),
    "Calling start() while process is already running"
);

ok( $launcher->force_stop(),
    "Calling 'force_stop' method"
);

sleep 1;

ok( ! $launcher->is_running(),
    "Checking that process exec'd process was shut down"
);
