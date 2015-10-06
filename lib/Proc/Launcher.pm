package Proc::Launcher;
use strict;
use warnings;

# VERSION

use Moo;
use MooX::Types::MooseLike::Base qw(Bool Str Int InstanceOf);

#_* Libraries

use File::Path;
use File::Tail;
use POSIX qw(setsid :sys_wait_h);
use Privileges::Drop;

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
                                        daemon_name  => 'myapp',
                                      );

    # check if the process was already running
    if ( $launcher->is_running() ) { warn "Already running!\n" }

    # start the process if there isn't already one running
    $launcher->start();

    # shut down the process if it is already running.  start a new process.
    $launcher->restart();

    # get the process pid
    my $pid = $launcher->pid();

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

For more useful functions (e.g. a supervisor to restart processes that
die), see L<Proc::Launcher::Manager>.

=head1 RELATED WORK

There are a large number of modules already on CPAN for forking and
managing child processes, and also for managing daemon processes
(apachectl style).  After doing a lot of reading and experimentation,
I unfortunately ended up deciding to write yet another one.  Here is a
bit of information on related modules and how this one differs.

While it is possible to exec() and manage external executables in the
child processes, that is merely an afterthought in this module.  If
you are looking for a module to start and manage external executables,
you might also want to check out L<Server::Control>, L<App::Control>,
L<App::Daemon>, or L<Supervisor> on CPAN, or ControlFreak on github.

If you are looking to investigate and/or kill running processes IDs,
see L<Unix::PID>, L<Unix::PID::Tiny>, or L<Proc::ProcessTable>.  This
module only manages processes that have been forked by this module.

If you only want to read and write a PID file, see L<Proc::PID::File>.

On the other hand, if you're looking for a library to fork dependent
child processes that maintain stdout/stderr/stdin connected to the
child, check out L<IPC::Run>, L<IPC::ChildSafe>, L<Proc::Simple>,
L<Proc::Reliable>, L<Proc::Fork>, etc.  This module assumes that all
child processes will close stdin/stdout/stderr and will continue to
live even after the launching process has exited.  Furthermore the
launched process will be manageable by launchers that are started
after the launched process is already running.

This library does not do anything like forking/pre-forking multiple
processes for a single daemon (e.g. for a high-volume server, see
L<Net::Server::PreFork>) or limiting the maximum number of running
child processes (see L<Proc::Queue> or L<Parallel::Queue>).  Instead
it is assumed that you are dealing with is a fixed set of named
daemons, each of which is associated with a single process to be
managed.  Of course any managed processes could fork it's own
children.  Note that only the process id of the immediate child will
be managed--any child processes created by child process
(grandchildren of the launcher) are not tracked.

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
of this class avoid calling sleep() (doing so inside a single-threaded
event loop causes everything else running in the event loop to wait).
This does mean that methods such as stop() will return immediately
without providing a status.  See more about this in the note below in
rm_zombies().

For compatibility with the planned upcoming L<GRID::Launcher> module
(which uses L<GRID::Machine>), this module and it's dependencies are
written in pure perl.

The intended use for this library is that a supervising process will
acquire some (immutable) global configuration data which is then
passed (at fork time) to one or more long-running component daemon
processes.  In the Panoptes project, this library is used for starting
and managing the various Panoptes components on each node
(L<Panoptes::Monitor>, L<Panoptes::Rules>, L<Panoptes::Util::WebUI>,
etc.) and also for managing connections to the remote agents.

If you are aware of any other noteworthy modules in this vein, please
let me know!

=cut

#_* Roles

with 'Proc::Launcher::Roles::Launchable';

#_* Attributes

=head1 CONSTRUCTOR OPTIONS

The constructor supports the following options, e.g.:

  my $launcher = Proc::Launcher->new( debug => 1, ... );

Each of these attributes will also have a getter, e.g.:

  if ( $launcher->debug ) { print "DEBUGGING ENABLED!\n" }

All attributes are read-only unless otherwise specified.  Read/write
attributes may be set like so:

  $launcher->debug( 1 );

=over 8

=item debug => 0

Enable debugging messages to STDOUT.  This attribute is read/write.

=cut

has 'debug'        => ( is => 'rw', isa => Bool, default => 0 );

=item daemon_name => 'somename'

Specify the name of the daemon.  This will be used as the prefix for
the log file, pid file, etc.

=cut

has 'daemon_name'  => ( is => 'ro', isa => Str, required => 1 );

=item context => $data

Context data to be passed to the forked processes.  This could be any
complex data structure and may contain things like configuration data.

=cut

has 'context'      => ( is => 'ro', default => sub { {} } );

=item class => 'My::App'

Name of the class where the start method is located.  An object of
this class will be created, passing in your context data.  Then the
start_method will be called on the object.

=cut

has 'class'        => ( is => 'ro', isa => Str );

=item start_method => 'start_me'

If a class is specified, this is the name of the start method in that
class.

If no class is specified, this must be a subroutine reference.

=cut

has 'start_method' => ( is => 'ro', required => 1 );

=item pid_dir => "$ENV{HOME}/logs"

Specify the directory where the pid file should live.

=cut

has 'pid_dir'      => ( is => 'ro',
                        isa => Str,
                        lazy => 1,
                        default => sub {
                            my $dir = join "/", $ENV{HOME}, "logs";
                            unless ( -d $dir ) {  mkpath( $dir ); }
                            return $dir;
                        },
                    );

=item pid_file => "$pid_dir/$daemon_name.pid"

Name of the pid file.

=cut

has 'pid_file'     => ( is => 'ro',
                        isa => Str,
                        lazy => 1,
                        default => sub {
                            my ( $self ) = @_;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.pid";
                        },
                    );

=item disable_file => "$pid_dir/$daemon_name.disabled"

Location to the 'disable' file.  If this file exists, the daemon will
not be started when start() is called.

=cut

has 'disable_file' => ( is => 'ro',
                        isa => Str,
                        lazy => 1,
                        default => sub {
                            my ( $self ) = @_;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.disabled";
                        },
                    );

=item log_file => "$pid_dir/$daemon_name.log"

Path to the daemon log file.  The daemon process will have both stdout
and stderr redirected to this log file.

=cut

has 'log_file'     => ( is => 'ro',
                        isa => Str,
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.log";
                        },
                    );

has 'file_tail'    => ( is => 'ro',
                        isa => InstanceOf['File::Tail'],
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            unless ( -r $self->log_file ) { system( 'touch', $self->log_file ) }
                            return File::Tail->new( name        => $self->log_file,
                                                    nowait      => 1,
                                                    interval    => 1,
                                                    maxinterval => 1,
                                                    resetafter  => 600,
                                                );
                        },
                    );


=item pipe => 0

If set to true, specifies that the forked process should create a
named pipe.  The forked process can then read from the named pipe on
STDIN.  If your forked process does not read from and process STDIN,
then there's no use in enabling this option.

=cut

has 'pipe'         => ( is => 'ro',
                        isa => Bool,
                        default => 0,
                    );

=item pipe_file => "$pid_dir/$daemon_name.cmd"

Path to the named pipe.

=cut

has 'pipe_file'    => ( is => 'ro',
                        isa => Str,
                        lazy => 1,
                        default => sub {
                            my $self = shift;
                            my $daemon = $self->daemon_name;
                            return join "/", $self->pid_dir, "$daemon.cmd";
                        },
                    );

=item stop_signal => 1

Signal to be send to stop a process. Default is 1 (HUP). If you
want to control some other processes, e.g. redis you may have to send
signal 15 (TERM) to stop the progress gracefully.

=cut

has 'stop_signal'    => ( is => 'rw',
                        isa => Int,
                        lazy => 1,
                        default => 1
                    );

=item run_as => $user

If defined, this process will be run as the specified user.
This will probably only work if the parent script is run as
root (or a superuser). Note, as we're changing the effective
user of the process, perl will automatically turn on taint
mode.

=cut 

has 'run_as'        => ( is => 'ro', isa => Str, required => 0 );

#_* Methods

=back

=head1 METHODS

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
immediately return null.  If a process was successfully forked,
success will be returned.  Success does not imply that the daemon was
started successfully--for that, check is_running().

=cut

sub start {
    my ( $self, $args ) = @_;

    unless ( $self->is_enabled ) {
        print $self->daemon_name, " daemon disabled, not starting\n";
        return;
    }

    if ( $self->is_running() ) {
        $self->_debug( "Already running, no start needed" );
        return;
    }

    my $log = $self->log_file;

    if ( my $pid = fork ) {    # PARENT

        print "LAUNCHED CHILD PROCESS: pid=$pid log=$log\n";

      CHECK_PID:
        for ( 1 .. 5 ) {

            $self->_debug( "Checking if our child locked the pidfile" );

            # attempt to read the pidfile
            my $locked_pid = $self->pid();

            $self->_debug( "Got locked pid: $locked_pid" );

            # check if the pidfile is locked by a valid process
            if ( $locked_pid && $self->is_running( $pid ) ) {

                $self->_debug( "Pid is running: $pid" );

                # check if the pid that has the lock is our child process
                if ( $locked_pid == $pid ) {

                    $self->_debug( "Locked pid is our child pid: $pid" );
                    return $pid;
                }
                else {
                    $self->_debug( "Locked pid is NOT our child pid: $pid" );
                    print "CHILD PROCESS ALREADY RUNNING\n";
                    return;
                }
            }

            sleep 1;
        }
    }
    else {                     # CHILD

        unless ( $self->write_my_pid( $$ ) ) {
            $self->_debug( "CHILD FAILED TO LOCK PIDFILE: $pid" );
            exit 1;
        }

        #chdir '/'                          or die "Can't chdir to /: $!";

        # wu - ugly bug fix - when closing STDIN, it becomes free and
        # may later get reused when calling open (resulting in error
        # 'Filehandle STDIN reopened as $fh only for output'). :/ So
        # instead of closing, just re-open to /dev/null.
        open STDIN, '<', '/dev/null'       or die "$!";

        open STDOUT, '>>', $self->log_file or die "Can't write stdout to $log: $!";
        open STDERR, '>>', $self->log_file or die "Can't write stderr to $log: $!";

        setsid                             or die "Can't start a new session: $!";

        #umask 0;

        # this doesn't work on most platforms
        $0 = join " - ", "perl", "Proc::Launcher", $self->daemon_name;
        
        drop_privileges($self->run_as) if $self->run_as;

        print "\n\n", ">" x 77, "\n";
        print "Starting process: pid = $$: ", scalar localtime, "\n\n";

        if ( $self->pipe ) {
            my $named_pipe = $self->pipe_file;
            print "CREATING NAMED PIPE: $named_pipe\n";
            unless (-p $named_pipe) {
                unlink $named_pipe;
                POSIX::mkfifo( $named_pipe, 0700) or die "can't mkfifo $named_pipe: $!"; ## no critic - leading zero
            }
            open STDIN, '<', $named_pipe or die "$!";
        }

        # child
        if ( $self->class ) {

            my $class = $self->class;
            print "Loading Class: $class\n";

            eval "require $class"; ## no critic

            my $error = $@;
            if ( $error ) {
                $self->stopped();
                die "FATAL ERROR LOADING $class: $error\n";
            }
            else {
                print "Successfully loaded class\n";
            }

            print "Creating an instance of $class\n";
            my $obj;
            eval {                          # try
                $obj = $class->new( context => $self->context );
                1;
            } or do {                       # catch
                $self->stopped();
                die "FATAL: unable to create an instance: $@\n";
            };
            print "Created\n";

            my $method = $self->start_method;
            print "Calling method on instance: $method\n";

            eval {                          # try
                $obj->$method( $args );
                1;
            } or do {                       # catch
                $self->stopped();
                die "FATAL: $@\n";
            };

        }
        else {
            print "STARTING\n";
            eval {                          # try
                $self->start_method->( $args );
                1;
            } or do {                       # catch
                # error
                print "ERROR: $@\n";
            };

        }

        # cleanup
        print "EXITED\n";
        $self->stopped();

        exit;
    }
}

=item stop()

If the process id is active, send it a kill -HUP.

=cut

sub stop {
    my ( $self ) = @_;

    if ( ! $self->is_running() ) {
        $self->_debug( "Process not found running" );
        return 1;
    }

    my $pid = $self->pid();

    $self->_debug( "Killing process: $pid" );
    my $status = kill $self->stop_signal => $pid;

    return $status;
}

=item restart( $data, $sleep )

Calls the stop() method, followed by the start() method, optionally
passing some $data to the start() method.

This method is not recommended since it doesn't check the status of
stop().  Instead, call stop(), wait a bit, and then check that the
process has shut down before trying to start it again.

WARNING: this method calls sleep to allow a process to shut down
before trying to start it again.  If sleep is set to 0, the child
process won't have time to exit, and thus the start() method will
never run.  As a result, this method is not recommended for use in a
single-threaded cooperative multitasking environments such as POE.

=cut

sub restart {
    my ( $self, $data, $sleep ) = @_;

    $self->stop();

    $sleep = $sleep ? $sleep : 1;
    sleep $sleep;

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
    my ( $self, $pid ) = @_;

    unless ( $pid ) { $pid = $self->pid() }

    return unless $pid;

    # clean up deceased child processes before checking if processes
    # are running.
    $self->rm_zombies();

    $self->_debug( "CHECKING PID: $pid" );

    if ( kill 0 => $pid ) {
        if ( $!{EPERM} ) {
            # if process id isn't owned by us, it is assumed to have
            # been recycled, i.e. our process died and the process id
            # was assigned to another process.
            $self->_debug( "Process id active but owned by someone else" );
        }
        else {
            $self->_debug( "STILL RUNNING" );
            return $self->daemon_name;
        }
    }

    $self->_debug( "PROCESS NOT RUNNING" );

    # process is not running, ensure the pidfile has been cleaned up
    $self->stopped();

    return;
}

=item rm_zombies()

Calls waitpid to clean up any child processes that have exited.

waitpid is called with the WNOHANG option so that it will always
return instantly to prevent hanging.

Normally this is called when the is_running() method is called (to
allow child processes to exit before polling if they are still
active).  If you are using a Proc::Launcher in a long-lived process,
after stopping a daemon you should always call is_running() until you
get a false response (i.e. the process has successfully stopped).  If
you do not call is_running() until the process exits, you will create
zombies.

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
        $self->_debug( "Process not found running" );
        return 1;
    }

    $self->_debug( "Process still running, executing with kill -9" );
    my $status = kill 9 => $self->pid();

    return $status;
}


=item stopped()

This method is called when a process has been detected as successfully
shut down.  The pidfile will be removed if it still exists.

=cut

sub stopped {
    my ( $self ) = @_;

    $self->_debug( "Process exited" );

    # remove the pidfile
    $self->remove_pidfile();

    # remove the named pipe if one was enabled
    if ( $self->pipe ) { unlink $self->pipe_file }
}

=item pid()

Read and return the pid from the pidfile.

The pid is validated to ensure it is a number.  If an invalid pid is
found, 0 is returned.

=cut

sub pid {
    my ( $self ) = @_;

    my $path = $self->pid_file;

    unless ( -r $path ) {
        return 0;
    }

    $self->_debug( "READING PID FROM: $path" );

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

    return $line;
}

=item write_my_pid()

Write the pid to the pid file.

This operation involves checking a couple of times to make sure that
no other process is running or trying to start another process at the
same time.  The pid is actually written to a temporary file and then
renamed.  Since rename() is an atomic operation on most filesystems,
this serves as a basic but effective locking mechanism that doesn't
require OS-level locking.  This should prevent two processes from both
starting a daemon at the same time.

=cut

sub write_my_pid {
    my ( $self, $pid ) = @_;

    unless ( $pid ) { $pid = $$ }

    # try to read the pidfile and see if the pid therein is active
    return if $self->is_running();

    # write the pid to a temporary file
    my $path = join ".", $self->pid_file, $pid;
    $self->_debug( "WRITING PID TO: $path" );
    open(my $pid_fh, ">", $path)
        or die "Couldn't open $path for writing: $!\n";
    print $pid_fh $pid;
    close $pid_fh or die "Error closing file: $!\n";

    # if some other process has created a pidfile since we last
    # checked, then it won and we lost
    if ( -r $self->pid_file ) {
        $self->_debug( "Pidfile already created by another process" );
        return
    }

    # atomic operation
    unless ( rename $path, $self->pid_file ) {
        $self->_debug( "Unable to lock pidfile $path for $pid" );
        return;
    }

    $self->_debug( "Successfully renamed pidfile to $path: $pid" );

    return 1;
}

=item remove_pidfile

Remove the pidfile.  This should only be done after the process has
been verified as shut down.

Failure to remove the pidfile is not a fatal error.

=cut

sub remove_pidfile {
    my ( $self ) = @_;

    return unless -r $self->pid_file;

    $self->_debug( "REMOVING PIDFILE: " . $self->pid_file );
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
        $subref->( "$name: $line" )  if ref($subref) eq 'CODE';
    }

    return 1;
}

=item write_pipe( $string )

Write text to the process's named pipe.  The child can then read this
data from it's STDIN.

Simply returns false if a named pipe was not enabled.

=cut

sub write_pipe {
    my ( $self, $string ) = @_;

    return unless $self->pipe;
    $self->_debug( "Writing to pipe" );

    unless ( -r $self->pipe_file ) {
        $self->_debug( "Pipe found but not readable" );
        return;
    }

    # remove any trailing whitespace
    chomp $string;

    # blast the string out to the named pipe
    print { sysopen (my $fh , $self->pipe_file, &POSIX::O_WRONLY) or die "$!\n"; $fh } $string, "\n";

    return 1;
}

=item disable()

Create the disable flag file unless it already exists.

=cut

sub disable {
    my ( $self ) = @_;

    if ( $self->is_enabled() ) {
        system( "touch", $self->disable_file );
    }

    return 1;
}

=item enable()

If the disable flag file exists, remove it.

=cut

sub enable {
    my ( $self ) = @_;

    unless ( $self->is_enabled() ) {
        unlink $self->disable_file;
    }

    return 1;
}

=item is_enabled()

Check if the launcher is enabled.

If the disable flag file exists, then the launcher will be considered
disabled.

=cut

sub is_enabled {
    my ( $self ) = @_;

    return if -r $self->disable_file;

    return 1;
}

# debugging output
sub _debug {
    my ( $self, @lines ) = @_;

    return unless $self->debug;

    for my $line ( @lines ) {
        chomp $line;
        print "$line\n";
    }
}

1;

__END__

=back

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Proc::Launcher

You can also look for information at:

=over 4

=item * Source code at github

L<http://github.com/wu/Proc-Launcher>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Proc-Launcher>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Proc-Launcher>

=item * Search CPAN

L<http://search.cpan.org/dist/Proc-Launcher>

=item * CPAN Test Matrix

L<http://matrix.cpantesters.org/?dist=Proc-Launcher>

=item * CPANTS overview

L<http://cpants.perl.org/dist/overview/Proc-Launcher>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Proc-Launcher>

=back

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
