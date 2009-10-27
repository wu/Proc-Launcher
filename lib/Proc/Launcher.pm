package Proc::Launcher;
use strict;
use warnings;
use Mouse;

our $VERSION;

#_* Libraries

use File::Path;
use File::Tail;
use POSIX qw(setsid :sys_wait_h);

#_* POD

=head1 NAME

Proc::Launcher - yet another forking process controller


=head1 SYNOPSIS

    use Proc::Launcher;

    # define a method to start your application if it isn't already running
    use MyApp;
    my $start_myapp = sub { MyApp->new( context => $some_shared_data )->run() };

    # create a new launcher object
    my $launcher = Proc::Launcher->new( start_method => $start_myapp,
                                        daemon_name  => 'myapp',
                                      );

    # an alternate version of the same thing without the subroutine reference
    my $launcher = Proc::Launcher->new( class        => 'MyApp',
                                        start_method => 'run'
                                        context      => $some_shared_data,
                                        start_method => $start_myapp,
                                        daemon_name  => 'myapp',
                                      );

    # check if the process was already running
    if ( $launcher->is_running() ) { warn "Already running!\n" }

    # start the process if there isn't already one running
    $launcher->start();

    # shut down the process if it is already running.  start a new process.
    $launcher->restart();

    # get the process pid
    my $pid = $launcher->pid;

    # kill -HUP
    $launcher->stop();

    # kill -9
    $launcher->force_stop();

    # get the process log file path
    my $log = $launcher->log_file;

=head1 DESCRIPTION

This library is designed to fork one or more long-running background
processes and to manage them.  This includes starting, stopping, and
automatically restarting processes--even those that don't behave well.

The pid of the forked child processes are written to pid files and
persist across multiple restarts of the launcher.  This means that
stdout/stderr/stdin of the children are not directly connected to the
launching process.  All stdout and stderr from the child processes is
written to a log file.

For more useful functions (e.g. a supervisor to restart the process that
die), see Proc::Launcher::Manager.

=head1 RELATED WORK

There are a large number of modules already on CPAN for forking and
managing child processes, and also for managing daemon processes
(apachectl style).  After doing a lot of reading and experimentation,
I unfortunately ended up deciding to write yet another one.  Here is a
bit of information on related modules and how this one differs.

While it is possible to exec() and manage external executables in the
child processes, that is merely an afterthought in this module.  If
you are looking for a module to manage external executables, you might
also want to check out Server::Control, App::Control, or App::Daemon
on CPAN, or ControlFreak on github.  See also Proc::PID::File.

On the other hand, if you're looking for a library to spawn dependent
child processes that maintain stdout/stderr/stdin connected to the
child, check out IPC::Run, IPC::ChildSafe, Proc::Simple,
Proc::Reliable, etc.  This module assumes that all child processes
will close stdin/stdout/stderr and potentially live through multiple
invocations/restarts of the launcher.

This library does not do anything like forking/pre-forking multiple
processes for a single daemon (e.g. for a high-volume server, see
Net::Server::PreFork) or limiting the maximum number of running
daemons (see Proc::Queue or Parallel::Queue).  Instead it is assumed
that you are dealing with is a fixed set of named daemons, each of
which is associated with a single process to be managed.  Of course
any managed processes could fork it's own children.  Note that only
the process id of the immediate child will be managed--any child
processes spawned by child process (grandchildren) are not tracked.

Similarly your child process should never do a fork() and exit() or
otherwise daemonize on it's own.  When the child does this, the
launcher will lose track of the grandchild pid and assume it has shut
down.  This may result in restarting your service while it is already
running.

This library does not handle command line options--that is left to
your application/script.  It does not export any methods nor require
you to inherit from any classes or to build any subclasses.  This
means that you can launch a process from any normal perl subroutine or
object method--the launched class/method/subroutine does not have to
be modified to be daemonized.

This library does not use or require an event loop (e.g. AnyEvent,
POE, etc.), but is fully usable from with an event loop since objects
of this class never call sleep() (doing so inside a single-threaded
event loop causes everything else running in the event loop to wait).
This does mean that methods such as stop() will return immediately
without providing a status.  See more about this in the note below in
rm_zombies().

For compatibility with the planned upcoming GRID::Launcher module
(which uses GRID::Machine), this module and it's dependencies are
written in pure perl.

The intended use for this library is that a supervising process will
acquire some (immutable) global configuration data which is then
passed (at fork time) to one or more long-running component daemon
processes.  In the Panoptes project, this library is used for starting
and managing the various Panoptes components on each node
(Panoptes::Monitor, Panoptes::Rules, Panoptes::Util::WebUI, etc.) and
also for managing connections to the remote agents.

If you are aware of any other noteworthy modules in this vein, please
let me know!

UPDATE: Another module that just showed up on CPAN today is
Supervisor::Session.  This looks worthy of further investigation.

=cut

#_* Roles

with 'Proc::Launcher::Roles::Launchable';

#_* Attributes

has 'debug'        => ( is => 'ro', isa => 'Bool', default => 0 );

has 'daemon_name'  => ( is => 'ro', isa => 'Str', required => 1 );

has 'context'      => ( is => 'ro' );

has 'class'        => ( is => 'ro', isa => 'Str' );
# can be either a coderef, or if a class is specified, can be a string :/
has 'start_method' => ( is => 'ro', required => 1 );

has 'pid_dir'      => ( is => 'ro',
                        isa => 'Str',
                        lazy => 1,
                        default => sub {
                            my $dir = join "/", $ENV{HOME}, "logs";
                            unless ( -d $dir ) {  mkpath( $dir ); }
                            return $dir;
                        },
                    );

has 'pid_file'     => ( is => 'ro',
                        isa => 'Str',
                        lazy => 1,
                        default => sub {
                            my ( $self ) = @_;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.pid";
                        },
                    );

has 'log_file'     => ( is => 'ro',
                        isa => 'Str',
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.log";
                        },
                    );

has 'file_tail'    => ( is => 'ro',
                        isa => 'File::Tail',
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            unless ( -r $self->log_file ) { system( 'touch', $self->log_file ) }
                            return File::Tail->new( name     => $self->log_file,
                                                    nowait   => 1,
                                                    interval => 1,
                                                );
                        },
                    );

has 'pid'          => ( is => 'rw',
                        isa => 'Int',
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            return $self->read_pid();
                        },
                    );

#_* Methods

=head1 SUBROUTINES/METHODS

=over 8

=item start( $data )

Fork a child process.  The process id of the forked child will be
written to a pid file.

The child process will close STDIN and redirect all stdout and stderr
to a log file, and then will execute the child start method and will
be passed any optional $data that was passed to the start method.

Note that there is no ongoing communication channel set up with the
child process.  Changes to $data in the supervising process will never
be available to the child process(es).  In order to force the child to
pick up the new data, you must stop the child process and then start a
new process with a copy of the new data.

If the process is found already running, then the method will
immediately return success.

=cut

sub start {
    my ( $self, $args ) = @_;

    if ( $self->is_running ) {
        print "Already running, no start needed\n" if $self->debug;
        return 1;
    }

    my $log = $self->log_file;

    if ( my $pid = fork ) {
        # parent
        print "LAUNCHED CHILD PROCESS: pid=$pid log=$log\n";
        $self->pid( $pid );
        $self->write_pid();
    }
    else {
        #chdir '/'                          or die "Can't chdir to /: $!";

        # wu - ugly bug fix - when closing STDIN, it becomes free and
        # may later get reused when calling open (resulting in error
        # 'Filehandle STDIN reopened as $fh only for output'). :/ So
        # instead of closing, we re-open to /dev/null.
        open STDIN, '<', '/dev/null' or die "$!";

        open STDOUT, '>>', $self->log_file or die "Can't write stdout to $log: $!";
        open STDERR, '>>', $self->log_file or die "Can't write stderr to $log: $!";
        #setsid                             or die "Can't start a new session: $!";
        #umask 0;

        print ">" x 77, "\n";
        print "Starting process: pid = $$: ", scalar localtime, "\n\n";

        # child
        if ( $self->class ) {
            my $method = $self->start_method;

            my $class = $self->class;
            eval "require $class"; ## no critic

            $self->class->new( context => $self->context )->$method( $args );
        }
        else {
            $self->start_method->( $args );
        }
        exit;
    }

    return 1;
}

=item stop()

If the process id is active, send it a kill -HUP.

=cut

sub stop {
    my ( $self ) = @_;

    if ( ! $self->is_running() ) {
        print "Process not found running\n" if $self->debug;
        return 1;
    }

    my $pid = $self->pid;

    print "Killing process: $pid\n" if $self->debug;
    my $status = kill 1, $pid;

    return $status;
}

=item restart( $data )

Calls the stop() method, followed by the start() method, optionally
passing some $data to the start() method.  This is pretty weak since
it doesn't check the status of stop().

=cut

sub restart {
    my ( $self, $data ) = @_;

    $self->stop();

    $self->start( $data );
}


=item is_running()

Check if a process is running by sending it a 'kill -0' and checking
the return status.

Before checking the process, rm_zombies() will be called to allow any
child processes that have exited to be reaped.  See a note at the
rm_zombies() method about the leaky abstraction here.

If the pid is not active, the stopped() method will also be called to
ensure the pid file has been removed.


=cut

sub is_running {
    my ( $self ) = @_;

    return unless $self->pid;

    # clean up deceased child processes before checking if processes
    # are running.
    $self->rm_zombies();

    print "CHECKING PID: ", $self->pid, "\n" if $self->debug;

    if ( kill 0, $self->pid ) {
        print "STILL RUNNING\n" if $self->debug;
        return $self->daemon_name;
    }

    print "PROCESS NOT RUNNING\n" if $self->debug;

    # process is not running, ensure the pidfile has been cleaned up
    $self->stopped();

    return;
}

=item rm_zombies()

Calls waitpid to clean up any child processes that have exited.

waitpid is called with the WNOHANG option so that it will always
return instantly to prevent hanging.

NOTE: Normally this is called when the is_running() method is called
(to allow child processes to exit before polling if they are still
active).  This is where the abstraction gets a bit leaky.  After
stopping a daemon, if you always call is_running() until you get a
false response (i.e. the process has successfully stopped), then
everything will work cleanly and you can be sure any zombies and pid
files have been removed.  If you don't call is_running() until
successful shutdown has been detected, then you may leave zombies or
pid files around.  The pid files are never removed until the process
has shut down cleanly, so any process left in a zombie state will
leave vestigial pid files.  In short, all this can be avoided by
ensuring that any time you shut down a daemon, you always call
is_running() until the process has shut down.


=cut

sub rm_zombies {
    waitpid(-1, WNOHANG);

}

=item force_stop()

If the process id is active, then send a 'kill -9'.

=cut

sub force_stop {
    my ( $self ) = @_;

    if ( ! $self->is_running() ) {
        print "Process not found running\n" if $self->debug;
        return 1;
    }

    print "Process still running, executing with kill -9\n" if $self->debug;
    my $status = kill 9, $self->pid;

    return $status;
}


=item stopped()

This method is called when a process has been detected as successfully
shut down.  The pid attribute will be zeroed out and the pidfile will
be removed if it still exists.

=cut

sub stopped {
    my ( $self ) = @_;

    print "Process exited\n" if $self->debug;

    # zero out the pid
    $self->pid( 0 );

    # remove the pidfile
    $self->remove_pidfile();

}

=item read_pid()

Read and return the pid from the pidfile.

The pid is validated to ensure it is a number.  If an invalid pid is
found, 0 is returned.

=cut

sub read_pid {
    my ( $self ) = @_;

    my $path = $self->pid_file;

    unless ( -r $path ) {
        return 0;
    }

    print "READING PID FROM: $path\n" if $self->debug;

    open(my $fh, "<", $path)
        or die "Couldn't open $path for reading: $!\n";

    my $line = <$fh>;

    close $fh or die "Error closing file: $!\n";

    return 0 unless $line;
    chomp $line;
    return 0 unless $line;

    unless ( $line =~ m|^\d+$| ) {
        warn "ERROR: PID doesn't look like a number: $line";
        return 0;
    }

    $self->pid( $line );

}

=item write_pid()

Write the pid to the pid file.

=cut

sub write_pid {
    my ( $self ) = @_;

    my $path = $self->pid_file;

    print "WRITING PID TO: $path\n" if $self->debug;

    open(my $pid_fh, ">", $path)
        or die "Couldn't open $path for writing: $!\n";
    print $pid_fh $self->pid;
    close $pid_fh or die "Error closing file: $!\n";

}

=item remove_pidfile

Remove the pidfile.  This should only be done after the process has
been verified as shut down.

Failure to remove the pidfile is not a fatal error.

=cut

sub remove_pidfile {
    my ( $self ) = @_;

    return unless -r $self->pid_file;

    print "REMOVING PIDFILE: ", $self->pid_file, "\n" if $self->debug;
    unlink $self->pid_file;
}

=item read_log

Return any new log data since the last offset was written.  If there
was no offset, set the offset to the current end of file.

You may want to call this before performing any operation on the
daemon in order to set the position to the end of the file.  Then
perform your operation, wait a moment, and then call read_log() to get
any output generated from your command while you waited.

=cut

sub read_log {
    my ( $self, $subref ) = @_;

    my $name = $self->daemon_name;

    while ( my $line=$self->file_tail->read ) {
        chomp $line;
        $subref->( "$name: $line" );
    }

    return 1;
}

no Mouse;

1;

__END__

=back

=head1 LIMITATIONS

Currently no locking is being performed so multiple controlling
processes running at the same time could potentially conflict.  For
example, both controlling processes might be trying to start the
daemon at the same time.  A fix for this is planned.



=head1 LICENCE AND COPYRIGHT

Copyright (c) 2009, VVu@geekfarm.org
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

- Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
