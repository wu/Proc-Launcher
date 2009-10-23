package Proc::Launcher::Roles::Launchable;
use Mouse::Role;

requires 'start';
requires 'stop';
#requires 'restart';
requires 'force_stop';

requires 'is_running';


no Mouse::Role;
