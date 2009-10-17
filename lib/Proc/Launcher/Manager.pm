package Proc::Launcher::Manager;
use Mouse;

our $VERSION = '0.0.1';

use Carp;
use Proc::Launcher;

=head1 NAME

Proc::Launcher::Manager - spawn and manage multiple Proc::Launcher objects

=head1 SYNOPSIS

    use Proc::Launcher::Manager;

    my $shared_config = { x => 1, y => 2 };

    my $monitor = Proc::Launcher::Manager->new( app_name  => 'MyApp',
                                                    );

    $monitor->spawn( daemon_name  => 'component1',
                     start_method => sub { MyApp->start_component1( $config ) }
                   );
    $monitor->spawn( daemon_name  => 'component2',
                     start_method => sub { MyApp->start_component2( $config ) }
                   );
    $monitor->spawn( daemon_name  => 'webui',
                     start_method => sub { MyApp->start_webui( $config ) }
                   );

    # start all registered daemons.  processes that are already
    # running won't be restarted.
    $monitor->start_all();

    # stop all daemons
    $monitor->stop_all();
    sleep 1;
    $monitor->force_stop_all();

    # get a specific daemon or perform actions on one (sorry demeter)
    my $webui = $monitor->daemon('webui');
    $monitor->daemon('webui')->start();

    # start the process supervisor.  this will start up an event loop
    # and won't exit until it is killed.  any processes not already
    # running will be started, and all processes will be monitored and
    # automatically restarted if they exit.
    $monitor->supervisor();

=head1 DESCRIPTION

This library makes it easier to deal with multiple Proc::Launcher
processes by providing methods to start and stop all daemons with a
single command.

It also provides a supervisor() method which will spawn a child daemon
that will monitor the other daemons at regular intervals and restart
any that have stopped.  Note that only one supervisor can be running at
any given time for each pid_dir.  This limitation will be removed in
the future.

A tail() method is under development that will spawn a
POE::Wheel::FollowTail process for each daemon's stdout/stderr log
file and allow you to provide a callback to process the output.

There is no tracking of inter-service dependencies nor predictable
ordering of service startup.  Instead, daemons should be designed to
wait for needed resources.  See Launcher::Cascade if you need to
handle dependencies.




=cut

#_* Attributes

has 'debug'     => ( is => 'ro', isa => 'Bool', default => 0 );

has 'pid_dir'   => ( is => 'ro',
                     isa => 'Str',
                     lazy => 1,
                     default => sub {
                         return join "/", $ENV{HOME}, ".proc", "logs";
                     },
                 );

has 'launchers' => ( is => 'rw',
                     isa => 'HashRef[Proc::Launcher]',
                 );

#_* Methods

=head1 SUBROUTINES/METHODS

=over 8

=item spawn( %options )

Create a new Proc::Launcher object with the specified options.  If
the specified daemon already exists, no changes will be made.

=cut

sub spawn {
    my ( $self, %options ) = @_;

    $options{pid_dir} = $self->pid_dir;

    unless ( $self->{daemons}->{ $options{daemon_name} } ) {
        $self->{daemons}->{ $options{daemon_name} } = Proc::Launcher->new( %options );
    }

}

=item daemon( 'daemon_name' )

Return the Proc::Launcher object for a specified daemon.

See: http://en.wikipedia.org/wiki/Law_of_Demeter

=cut

sub daemon {
    my ( $self, $daemon_name ) = @_;

    return $self->{daemons}->{ $daemon_name };
}


=item daemons()

Return a list of Proc::Launcher objects.

=cut

sub daemons {
    my ( $self ) = @_;

    my @daemons;

    for my $daemon_name ( $self->daemons_names() ) {
        push @daemons, $self->{daemons}->{ $daemon_name };
    }

    return @daemons;
}

=item daemons_names()

Return a list of the names of all registered daemons.

=cut

sub daemons_names {
    my ( $self ) = @_;

    return ( sort keys %{ $self->{daemons} } );
}

=item daemons_running()

Return a list of the names of daemons that are currently running.

This will begin by calling rm_zombies() on the first daemon, sleeping
a second, and then calling rm_zombies() again.  So far the test cases
have always passed when using this strategy, and inconsistently passed
with any subset thereof.

While it seems that this is more complicated than shutting down a
single process, it's really just trying to be a bit more efficient.
When managing a single process, is_running might be called a few times
until the process exits.  Since we might be managing a lot of daemons,
this method is likely to be a bit more efficient and will hopefully
only need to be called once (after the daemons have been given
necessary time to shut down).

=cut

sub daemons_running {
    my ( $self ) = @_;

    my @daemon_names = $self->daemons_names();

    # clean up deceased child processes before checking if processes
    # are running.
    $self->daemon($daemon_names[0])->rm_zombies();

    # # give any processes that have ceased a second to shut down
    sleep 1;

    # again clean up deceased child processes before checking if
    # processes are running.
    $self->daemon($daemon_names[0])->rm_zombies();

    my @running;

    for my $daemon_name ( @daemon_names ) {
        if ( $self->daemon($daemon_name)->is_running() ) {
            push @running, $daemon_name
        }
    }

    return @running;
}

=item start_all( $data )

Call the start() method on all daemons.  If the daemon is already
running it will not be restarted.

=cut

sub start_all {
    my ( $self, $data ) = @_;

    for my $daemon ( $self->daemons() ) {
        if ( $daemon->is_running() ) {
            print "daemon already running: ", $daemon->daemon_name, "\n";
        }
        else {
            print "starting daemon: ", $daemon->daemon_name, "\n";
            $daemon->start();
        }
    }
}


=item stop_all()

Call the stop() method on all daemons.

=cut

sub stop_all {
    my ( $self ) = @_;

    for my $daemon ( $self->daemons() ) {
        print "stopping daemon: ", $daemon->daemon_name, "\n";
        $daemon->stop();
    }

    return 1;
}

=item force_stop_all()

Call the force_stop method on all daemons.

=cut

sub force_stop_all {
    my ( $self ) = @_;

    for my $daemon ( $self->daemons() ) {
        print "forcefully stopping daemon: ", $daemon->daemon_name, "\n";
        $daemon->force_stop();
    }

    return 1;
}

=item supervisor()

Launch a supervisor process that will poll all selected daemons at
regular intervals and restart them in the event that they fail.

Only one supervisor can be running at a time.  If you start a new
supervisor process, it will replace the old one.

=cut

sub supervisor {
    my ( $self, $options ) = @_;

    $self->{supervisor}
        = Proc::Launcher->new(
            daemon_name  => 'supervisor',
            pid_dir      => $self->pid_dir,
            start_method => sub {
                require Proc::Launcher::Supervisor;
                Proc::Launcher::Supervisor->new()->monitor( $self );
              },
        );

    print "Shutting down previously running supervisor\n";
    $self->{supervisor}->force_stop();

    sleep 1;

    print "Starting a new supervisor\n";
    $self->{supervisor}->start();
}

=item tail()

=cut

sub tail {
    my ( $self, $output_callback ) = @_;

    print "Tailing all log files\n";
    require Proc::Launcher::Tail;
    Proc::Launcher::Tail->new( output_callback => $output_callback )->tail( $self );
}


=back

=cut

1;
