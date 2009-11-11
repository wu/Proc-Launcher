#!/perl
use strict;

use Test::More;

# Don't run tests during end-user installs
plan( skip_all => 'Author tests not required for installation' )
    unless ( $ENV{RELEASE_TESTING} );

use Proc::Launcher;

use File::Temp qw/ :POSIX /;

my ($fh, $file) = tmpnam();
close $fh;
unlink $file;

my $start_method = sub { sleep 3 };

my $launcher = Proc::Launcher->new( start_method => $start_method,
                                    daemon_name  => 'test',
                                    pid_file     => $file,
                                );


ok( ! $launcher->is_running(),
    "Checking that test process is not already running"
);

my @pids;

for my $test ( 1 .. 3 ) {

    if ( my $pid = fork() ) {
        push @pids, $pid;
        next;
    }

    if ( $launcher->start() ) {
        exit;
    }

    exit 1;
}

my $ok_exit_statuses;

for my $pid ( @pids ) {
    waitpid( $pid, 0 );

    unless ( $? ) {
        $ok_exit_statuses++;
    }
}

is( $ok_exit_statuses,
    1,
    "Checking that only one forked process successfully started the daemon"
);

# shut down the daemon if we left it running
$launcher->force_stop();

done_testing();
