package Proc::Launcher::Supervisor;
use strict;
use warnings;
use Mouse;

has 'monitor_delay' => ( is => 'rw', isa => 'Int', default => 15 );

sub monitor {
    my ( $self, $manager ) = @_;

    while ( 1 ) {
        $manager->start_all();
        sleep $self->monitor_delay;
    }
}

no Mouse;

1;

__END__

=head1 NAME

Proc::Launcher::Supervisor - restart watched processes that have exited


=head1 DESCRIPTION

This is a tiny module that's designed for use with panctl and
Proc::Launcher, where it is forked off and run as a separate process.

=head1 SUBROUTINES/METHODS

=over 8

=item $obj->monitor( $manager )

This tiny class contains only this one method.  It requires a
reference to a Proc::Launcher::Manager object in order to determine
information about that manager's daemons.

It will repeatedly sleep for a configured period of time (default 15
seconds), and then call start_all() on the manager object.  This will
result in restarting any processes that have stopped.

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



