package Proc::Launcher::Tail;
use Mouse;

our $VERSION = '0.0.1';

use Term::ANSIColor;

use POE qw(Wheel::FollowTail);

sub tail {
    my ( $self, $manager ) = @_;

    for my $daemon ( $manager->daemons() ) {

        # get the daemon name
        my $daemon_name = $daemon->daemon_name;
        # attempt to shorten it
        $daemon_name    =~ s|^panopti||;

        my $path        = $daemon->log_file;

        POE::Session->create(
            inline_states => {
                _start => sub {
                    $_[HEAP]{tailor} = POE::Wheel::FollowTail->new(
                        Filename   => $path,
                        InputEvent => "got_log_line",
                        ResetEvent => "got_log_rollover",
                    );
                },
                got_log_line => sub {
                    print color 'reset';
                    print "$daemon_name: $_[ARG0]\n";
                },
                got_log_rollover => sub {
                    print color 'reset';
                    print "$daemon_name: Log rolled over.\n";
                },
                _stop => sub {
                    delete $_[HEAP]{tailor};
                },
            }
        );
    }

    POE::Kernel->run();
}

1;

__END__

=head1 NAME

Proc::Launcher::Tail - poe-based 'tail -f' on selected process logs


=head1 DESCRIPTION

This module is designed to be used from panctl.


=head1 SUBROUTINES/METHODS

=over 8

=item $obj->tail( $manager )

This class contains only this one method.  It requires a reference to
a Proc::Launcher::Manager object in order to determine information
about that manager's daemons.

The log files of all selected files will be monitored for output, and
output will be displayed to the screen.  This is similar to 'tail -f'.

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



